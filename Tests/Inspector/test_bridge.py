import json
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

CLI = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))
RUNNER = runpy.run_path(str(Path(__file__).with_name('run.py')))


class StartupTests(unittest.TestCase):
    def test_outer_watchdog_allows_slow_sequential_transport_startup(self):
        elapsed = [0]
        def advance(_):
            elapsed[0] += 30
        clock = SimpleNamespace(monotonic=lambda: elapsed[0], sleep=advance)
        log = Mock()
        log.read_text.side_effect = lambda: 'Inspector on display' if elapsed[0] >= 90 else 'Installing inspector'
        ready = RUNNER['wait_for_inspector']
        with patch.dict(ready.__globals__, time=clock):
            ready(Mock(poll=Mock(return_value=None)), log)

    def test_startup_failure_keeps_inner_diagnostic(self):
        output = ['Inspector: installing app']
        def exited():
            output[0] += '\nsimctl install timed out'
            return 1
        log = Mock(read_text=Mock(side_effect=lambda: output[0]))
        with self.assertRaisesRegex(RuntimeError, 'simctl install timed out'):
            RUNNER['wait_for_inspector'](Mock(poll=exited), log)

    def test_shared_launch_has_a_global_background_budget(self):
        elapsed = [0]
        clock = SimpleNamespace(monotonic=lambda: elapsed[0], sleep=lambda _: elapsed.__setitem__(0, elapsed[0] + 5))
        ready = RUNNER['wait_for_inspector']
        log = Mock(read_text=Mock(return_value='Inspector: launching app on display simulator.'))
        with patch.dict(ready.__globals__, time=clock):
            with self.assertRaisesRegex(RuntimeError, 'background budget'):
                ready(Mock(poll=Mock(return_value=None)), log, consumer_budget=25)
        self.assertEqual(elapsed[0], 25)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.path = Path(self.work.name) / 'probe.json'
        self.elapsed = [0.0]
        self.clock = SimpleNamespace(monotonic=lambda: self.elapsed[0], time=lambda: 1000 + self.elapsed[0],
                                     sleep=lambda delay: self.elapsed.__setitem__(0, self.elapsed[0] + delay))
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture', profile='ios-27.0')
        self.row = dict(self.session, event='runtime.installed', sequence=1, t_ms=1)
        self.value = dict(nonce='fresh', inspectorPID=42, wallTimeMS=1000000, startedWallTimeMS=1000000,
                          session=self.session, cursor=1, online=True, audioActive=False,
                          conversations=[], pending=[], timeline=[self.row])

    def write(self, **changes):
        self.path.write_text(json.dumps(dict(self.value, **changes)))

    def test_fresh_receipt_is_accepted_and_pins_identity(self):
        self.write()
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            self.assertEqual(reader.wait(lambda row: row['online'])['inspectorPID'], 42)
            self.write(inspectorPID=43)
            with self.assertRaisesRegex(RuntimeError, 'Inspector process changed'):
                reader.read()

    def test_old_nonce_cannot_satisfy_readiness(self):
        self.write(nonce='old')
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            with self.assertRaisesRegex(RuntimeError, 'nonce'):
                reader.wait(lambda row: row['online'], timeout=0.3)

    def test_wrong_target_and_cursor_regression_fail(self):
        self.write(session=dict(self.session, pid=999))
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            with self.assertRaisesRegex(RuntimeError, 'target session changed'):
                reader.read()
            self.write()
            reader.read()
            self.write(cursor=0, timeline=[])
            with self.assertRaisesRegex(RuntimeError, 'cursor regressed'):
                reader.read()

    def test_frozen_receipt_and_expired_background_budget_fail(self):
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            self.write(wallTimeMS=994000)
            with self.assertRaisesRegex(RuntimeError, 'stale'):
                reader.read()
            reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
            self.write(startedWallTimeMS=974000)
            with self.assertRaisesRegex(RuntimeError, 'background budget'):
                reader.read()

    def test_error_after_readiness_is_not_silently_retried(self):
        self.write()
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            reader.wait(lambda row: row['online'])
            self.write(online=False, error='bridge disconnected')
            with self.assertRaisesRegex(RuntimeError, 'bridge disconnected'):
                reader.read()

    def test_failed_receipt_is_preserved_before_validation(self):
        self.write(session=dict(self.session, pid=999))
        diagnostic = self.path.with_name('retained.json')
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session, diagnostic_path=diagnostic)
        with patch.dict(reader.read.__globals__, time=self.clock):
            with self.assertRaisesRegex(RuntimeError, 'target session changed'):
                reader.read()
        self.assertEqual(diagnostic.read_bytes(), self.path.read_bytes())

    def test_inspector_projection_cannot_invent_a_fulfilled_action(self):
        row = dict(self.row, event='action.settled', actionID='answer', kind='answer', origin='system', fulfilled=True)
        receipt = dict(self.value, timeline=[row])
        verify = RUNNER['verify_probe_journal']
        verify([receipt], [row], self.session)
        with self.assertRaisesRegex(AssertionError, 'differs from runtime journal'):
            verify([receipt], [dict(row, fulfilled=False)], self.session)

    def test_global_deadline_caps_a_longer_projection_wait(self):
        self.write(nonce='old')
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            with self.assertRaisesRegex(RuntimeError, 'background budget'):
                reader.wait(lambda row: row['online'], timeout=10, deadline=0.2)
        self.assertLess(self.elapsed[0], 0.3)

    def test_shared_probe_wait_uses_the_original_remaining_deadline(self):
        class Stopped(Exception):
            pass
        journey = RUNNER['journal_journey']
        probe = Mock(wait=Mock(side_effect=Stopped))
        with patch.dict(journey.__globals__, time=self.clock):
            with self.assertRaises(Stopped):
                journey([], 'target', 'fresh', self.session, self.path.parent, deadline=0.25, probe=probe)
        self.assertEqual(probe.wait.call_args.kwargs['deadline'], 0.25)

    def test_explicit_resume_tolerates_pause_but_never_resets_identity(self):
        self.write()
        reader = RUNNER['ProbeReader'](self.path, 'fresh', self.session)
        with patch.dict(reader.read.__globals__, time=self.clock):
            reader.read()
            self.elapsed[0] = 6
            self.assertIsNone(reader.read(resume_after=1006000))
            self.write(wallTimeMS=1006000, online=False, error='request timed out')
            self.assertIsNone(reader.read(resume_after=1006000))
            self.write(wallTimeMS=1006000)
            self.assertTrue(reader.wait(lambda row: row['online'], resume_after=1006000)['online'])
            self.write(wallTimeMS=1006000, online=False, error='stable failure')
            with self.assertRaisesRegex(RuntimeError, 'stable failure'):
                reader.read()
            self.write(inspectorPID=99)
            with self.assertRaisesRegex(RuntimeError, 'Inspector process changed'):
                reader.read(resume_after=1006000)

    def test_foreground_switch_preserves_pid_without_terminating(self):
        activate = RUNNER['activate_existing']
        rpc = Mock(return_value='test.fixture: 123')
        with patch.dict(activate.__globals__, time=self.clock, run=rpc):
            activate('device', 'test.fixture', 123, deadline=5)
            self.assertEqual(rpc.call_args.args, ('xcrun', 'simctl', 'launch', 'device', 'test.fixture'))
            rpc.return_value = 'test.fixture: 999'
            with self.assertRaisesRegex(RuntimeError, 'PID changed'):
                activate('device', 'test.fixture', 123, deadline=5)

    def test_slow_foreground_activation_uses_available_consumer_budget(self):
        activate = RUNNER['activate_existing']
        self.elapsed[0] = 11.7  # Hosted failure had 13.3 s left in the 25 s lifetime.
        def delayed_launch(*args, timeout):
            if timeout < 6:
                raise RuntimeError('launch timed out before foreground activation')
            self.elapsed[0] += 6
            return 'test.fixture: 123'
        rpc = Mock(side_effect=delayed_launch)
        with patch.dict(activate.__globals__, time=self.clock, run=rpc):
            activate('device', 'test.fixture', 123, deadline=25)
        self.assertEqual(rpc.call_count, 1)
        self.assertLessEqual(rpc.call_args.kwargs['timeout'], 10)
        self.assertAlmostEqual(self.elapsed[0], 17.7)

    def test_foreground_timeout_does_not_extend_or_retry_the_global_budget(self):
        activate = RUNNER['activate_existing']
        rpc = Mock(side_effect=RuntimeError('launch timed out'))
        with patch.dict(activate.__globals__, time=self.clock, run=rpc):
            with self.assertRaisesRegex(RuntimeError, 'launch timed out'):
                activate('device', 'test.fixture', 123, deadline=2)
        self.assertEqual(rpc.call_count, 1)
        self.assertEqual(rpc.call_args.kwargs['timeout'], 2)

    def test_native_journal_ignores_partial_tail_and_checks_session(self):
        channel = self.path.parent / 'channel'
        (channel / 'run').mkdir(parents=True)
        (channel / 'session.json').write_text(json.dumps(self.session))
        journal = channel / 'run/events.jsonl'
        journal.write_bytes(json.dumps(self.row).encode() + b'\n{"partial":')
        read = RUNNER['read_runtime_journal']
        self.assertEqual(read(channel, self.session), [self.row])
        (channel / 'session.json').write_text(json.dumps(dict(self.session, pid=999)))
        with self.assertRaisesRegex(RuntimeError, 'session changed'):
            read(channel, self.session)

    def test_journey_foregrounds_fixture_for_each_control_then_inspector_for_projection(self):
        self.session['controlTransport'] = 'directory-watch-v1'
        self.row['controlTransport'] = 'directory-watch-v1'
        identifier = 'A7E390AF-6B78-4190-B946-26D9C6438584'
        push = dict(self.row, sequence=2, t_ms=100, event='push.received', pushID='p1', mustReport=True)
        report = dict(self.row, sequence=3, t_ms=290, event='report.completed', pushID='p1', error=0)
        ring = dict(self.row, sequence=4, t_ms=295, event='call.changed', uuid=identifier,
                    callerName='Alex Morgan', ringing=True, ended=False, connected=False)
        delivery = dict(self.row, sequence=5, t_ms=300, event='action.deadline', actionID='answer', kind='answer',
                        callUUID=identifier, apiKind='callkit')
        answer = dict(delivery, sequence=6, t_ms=425, event='action.settled',
                      origin='system', fulfilled=True, latencyMS=125, deadlineSeconds=60)
        joined = dict(ring, sequence=7, t_ms=430, ringing=False, connected=True)
        audio = dict(self.row, sequence=8, t_ms=536, event='audio.activated')
        rows = [self.row, push, report, ring, delivery, answer, joined, audio]
        source = 'docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md'
        def reference(name, device, **fields):
            return dict(id=name, deviceValue=device, sourcePath=source,
                        deviceProvenance='LCK · iPhone 13 · iOS 27.0', **fields)
        references = [reference('pushReport', '≈190 ms', actualMS=190, startSequence=2, endSequence=3),
                      reference('answerAudio', '≈236 ms'), reference('muteEcho', '8–17 ms after fulfillment'),
                      reference('unreportedPush', '≈4.4 s')]
        incoming = dict(self.value, cursor=4, incoming=ring, conversations=[ring], timeline=rows[:4], timingReferences=references)
        answered_references = [dict(row) for row in references]
        answered_references[1].update(actualMS=236, startSequence=5, endSequence=8,
                                      actualLabel='Simulator · CallKit answer delivered → audio.activated')
        connected = dict(self.value, cursor=8, conversations=[joined], timeline=rows, audioActive=True,
                         timingReferences=answered_references,
                         timelinePresentation=[dict(sequence=6, title='Answer fulfilled', detail='system · 125 ms · 60 s profile budget')])
        states = iter([self.value, incoming, connected])
        actor = ['inspector']
        observed = []
        class Reader:
            pid = 42
            started = 1000000
            def __init__(self, *args, **kwargs):
                pass
            def wait(inner, predicate, **kwargs):
                self.assertEqual(actor[0], 'inspector')
                value = next(states)
                self.assertTrue(predicate(value))
                return value
        def rpc(*parts, **kwargs):
            if parts[:3] == ('xcrun', 'simctl', 'get_app_container'):
                return str(self.path.parent)
            if parts[:3] == ('xcrun', 'simctl', 'launch'):
                actor[0] = 'fixture' if parts[-1] == self.session['bundleID'] else 'inspector'
                observed.append(actor[0])
                return parts[-1] + (': 123' if actor[0] == 'fixture' else ': 42')
            if 'push' in parts or 'answer' in parts:
                self.assertEqual(actor[0], 'fixture', 'controls need a foreground target')
                operation = 'push' if 'push' in parts else 'answer'
                observed.append(operation)
                return json.dumps(dict(success=True, result=dict(actionIDs=['answer'])))
            if 'watch' in parts:
                return '\n'.join(json.dumps(row) for row in rows)
            return ''
        native = [0]
        def wait_native(predicate, channel, session, deadline, **kwargs):
            self.assertEqual(actor[0], 'fixture')
            values = rows[:4] if native[0] == 0 else rows
            native[0] += 1
            self.assertTrue(predicate(values))
            return values
        channel = self.path.parent / 'channel'
        channel.mkdir()
        (channel / 'session.json').write_text(json.dumps(self.session))
        journey = RUNNER['journal_journey']
        def control(args, device, expected_session):
            self.assertEqual(actor[0], 'fixture', 'controls need a foreground target')
            self.assertEqual(expected_session, self.session)
            observed.append(args.operation)
            return dict(success=True, result=dict(actionIDs=['answer']))
        with patch.dict(journey.__globals__, time=self.clock, run=rpc, ProbeReader=Reader, wait_runtime=wait_native,
                        _shipping_tools=Mock(return_value={'control': control})):
            self.assertTrue(journey(['cksim'], 'device', 'fresh', self.session, self.path.parent, 25, channel, probe=Reader())['success'])
        self.assertEqual(observed, ['fixture', 'push', 'inspector', 'fixture', 'answer', 'inspector'])


class ConsumerControlTests(unittest.TestCase):
    def setUp(self):
        RUNNER['_shipping_tools'].cache_clear()
        self.addCleanup(RUNNER['_shipping_tools'].cache_clear)
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.device = '0D0079D0-4B7B-4C60-87D1-B53A06C0E965'
        self.container = (Path(self.work.name) / self.device / 'data/Containers/Data/Application' /
                          'CA92C9E3-557D-4B61-A306-111F6D0B568D')
        self.channel = self.container / 'Documents/.callkit-simulator'
        self.mailbox = self.channel / 'run'
        for name in ('requests', 'responses'):
            (self.mailbox / name).mkdir(parents=True)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture',
                            controlTransport='directory-watch-v1')
        (self.channel / 'session.json').write_text(json.dumps(self.session))
        self.elapsed = [20.181]
        self.requests = []
        self.clock = SimpleNamespace(monotonic=lambda: self.elapsed[0], sleep=self.respond)

    def respond(self, _):
        self.elapsed[0] += 0.05
        for path in (self.mailbox / 'requests').glob('*.json'):
            response = self.mailbox / 'responses' / path.name
            if not response.exists():
                request = json.loads(path.read_text())
                self.requests.append(request)
                response.write_text(json.dumps(dict(request, success=True, result={})))

    def test_loaded_shipping_control_preserves_mailbox_receipts_and_remaining_cap(self):
        factory = RUNNER['consumer_control']
        shipping = CLI['control']
        receipt = Path(self.work.name) / 'answer.json'
        rpc = Mock(side_effect=AssertionError('control must not invoke simctl'))
        transport = Mock(wraps=shipping)
        loader = Mock(return_value=dict(CLI, control=transport))
        with patch.object(runpy, 'run_path', loader), patch.dict(factory.__globals__, time=self.clock):
            send = factory(self.channel, self.session, self.device, deadline=25)
            with patch.dict(shipping.__globals__, time=self.clock, simctl=rpc):
                response = json.loads(send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584',
                                           command_receipt=receipt))
                self.assertTrue(response['success'])
                self.assertTrue(json.loads(send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584'))['success'])
        self.assertEqual(loader.call_count, 1)
        self.assertAlmostEqual(transport.call_args_list[0].args[0].timeout, 4.819)
        self.assertAlmostEqual(transport.call_args_list[1].args[0].timeout, 4.769)
        rpc.assert_not_called()
        saved = json.loads(receipt.read_text())
        self.assertEqual(saved['session'], self.session)
        self.assertEqual(saved['request']['id'], response['id'])
        self.assertEqual(saved['response'], response)
        self.assertEqual([row['operation'] for row in self.requests], ['answer', 'answer'])
        self.assertEqual(len({row['id'] for row in self.requests}), 2)
        self.assertAlmostEqual(self.elapsed[0], 20.281)
        with patch.dict(factory.__globals__, time=self.clock):
            self.elapsed[0] = 25
            with self.assertRaisesRegex(RuntimeError, 'background budget'):
                send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584')
        self.assertEqual(len(list((self.mailbox / 'requests').glob('*.json'))), 2)

    def test_slow_control_preflight_cannot_publish_after_the_absolute_deadline(self):
        factory = RUNNER['consumer_control']
        shipping = CLI['control']
        original = shipping.__globals__['target_container']
        def slow_preflight(*args):
            time.sleep(0.1)
            return original(*args)
        previous = signal.getsignal(signal.SIGALRM)
        with patch.object(runpy, 'run_path', return_value=CLI):
            send = factory(self.channel, self.session, self.device, deadline=time.monotonic() + 0.02)
            with patch.dict(shipping.__globals__, target_container=slow_preflight):
                with self.assertRaisesRegex(RuntimeError, 'Inspector control timed out'):
                    send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584')
        self.assertEqual(list((self.mailbox / 'requests').glob('*.json')), [])
        self.assertEqual(signal.getsignal(signal.SIGALRM), previous)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0, 0))

    def test_changed_session_refuses_publication_without_replay(self):
        factory = RUNNER['consumer_control']
        with patch.object(runpy, 'run_path', return_value=CLI), patch.dict(factory.__globals__, time=self.clock):
            send = factory(self.channel, self.session, self.device, deadline=25)
            (self.channel / 'session.json').write_text(json.dumps(dict(self.session, pid=999)))
            with self.assertRaisesRegex(RuntimeError, 'Runtime session changed'):
                send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584')
        self.assertEqual(list((self.mailbox / 'requests').glob('*.json')), [])

    def test_wrong_cached_device_and_response_identity_are_terminal(self):
        factory = RUNNER['consumer_control']
        shipping = CLI['control']
        with patch.object(runpy, 'run_path', return_value=CLI), patch.dict(factory.__globals__, time=self.clock):
            send = factory(self.channel, self.session, 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', deadline=25)
            with self.assertRaisesRegex(RuntimeError, 'Cached app container'):
                send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584')
            self.assertEqual(list((self.mailbox / 'requests').glob('*.json')), [])
            send = factory(self.channel, self.session, self.device, deadline=25)
            def wrong_ack(delay):
                self.respond(delay)
                path = next((self.mailbox / 'responses').glob('*.json'))
                path.write_text(json.dumps(dict(json.loads(path.read_text()), pid=999)))
            clock = SimpleNamespace(monotonic=self.clock.monotonic, sleep=wrong_ack)
            with patch.dict(shipping.__globals__, time=clock):
                with self.assertRaisesRegex(RuntimeError, 'response identity mismatch'):
                    send('answer', call='A7E390AF-6B78-4190-B946-26D9C6438584')
        self.assertEqual(len(list((self.mailbox / 'requests').glob('*.json'))), 1)


class BridgeTests(unittest.TestCase):
    def test_display_cold_boot_has_an_explicit_bounded_timeout(self):
        boot = CLI['simctl']
        with patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('simctl', 300)) as process:
            with self.assertRaisesRegex(RuntimeError, 'after 300s'):
                boot('bootstatus', 'owned', '-b', timeout=300)
        self.assertEqual(process.call_args.kwargs['timeout'], 300)

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture')
        (self.root / 'session.json').write_text(json.dumps(self.session))
        (self.root / 'run').mkdir()
        self.path = self.root / 'run/events.jsonl'
        self.path.write_bytes(b'')
        self.args = SimpleNamespace(bundle='test.fixture')
        self.bridge = CLI['InspectorBridge'](self.args, 'device', self.root)

    def append(self, sequence):
        row = dict(self.session, event='report.incoming', sequence=sequence, t_ms=25, wallTimeMS=1000)
        with self.path.open('a') as output:
            output.write(json.dumps(row) + '\n')
        return row

    def test_empty_poll_replay_and_incremental_delivery(self):
        self.assertEqual(self.bridge.events(0)['events'], [])
        first = self.append(1)
        self.assertEqual(self.bridge.events(0)['events'], [first])
        second = self.append(2)
        self.assertEqual(self.bridge.events(0)['events'], [first], 'HTTP retry must replay the same batch')
        self.assertEqual(self.bridge.events(1)['events'], [second])
        self.assertEqual(self.bridge.events(2)['events'], [])
        with self.assertRaisesRegex(RuntimeError, 'cursor changed'):
            self.bridge.events(0)

    def test_restart_rejects_even_replayed_batch(self):
        self.append(1)
        self.bridge.events(0)
        (self.root / 'session.json').write_text(json.dumps(dict(self.session, pid=456)))
        with self.assertRaisesRegex(RuntimeError, 'session changed'):
            self.bridge.events(0)

    def test_controls_use_existing_transport_and_expected_session(self):
        control = Mock(return_value={'success': True})
        send = self.bridge.command
        with patch.dict(send.__globals__, control=control):
            for operation in ('answer','decline','end','hold-and-accept','end-and-accept'):
                self.assertTrue(send(dict(operation=operation, callUUID='A7E390AF-6B78-4190-B946-26D9C6438584'))['success'])
                args, device = control.call_args.args
                self.assertEqual(args.operation, operation)
                self.assertEqual(device, 'device')
                self.assertEqual(control.call_args.kwargs['expected_session'], self.session)
            for value in ([], dict(operation='push'), dict(operation='answer', callUUID='bad'),
                          dict(operation='answer', callUUID='A7E390AF-6B78-4190-B946-26D9C6438584', runID='other')):
                with self.assertRaises((RuntimeError, ValueError)):
                    send(value)


if __name__ == '__main__':
    unittest.main()
