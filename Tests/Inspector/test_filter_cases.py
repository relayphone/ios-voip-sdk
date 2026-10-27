"""Host-only regression controls for separate, bounded Inspector consumers."""
import hashlib
import json
from contextlib import contextmanager
from pathlib import Path
import runpy
import signal
import sys
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid


RUNNER = runpy.run_path(str(Path(__file__).with_name('run.py')))
SHIPPING = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))
FIXTURE = 'dev.callkitsim.eventfixture'
INSPECTOR = 'dev.callkitsim.inspector'
CALL = 'FFEEDABC-BAB8-4057-A23F-65695E9F49C1'

# The six completed foreground RPCs retained by 9c/40418681537, followed
# by representative activation costs for clearing and consuming the filter.
FOREGROUND_COSTS = (3.494457, 9.084738, 2.090077, 1.494744,
                    1.994251, 1.075326, 1.994251, 1.075326)


class NativeWorld:
    """Native RPC/mailbox boundary with real journal files and ProbeReader."""
    def __init__(self, test):
        self.test = test
        self.temporary = tempfile.TemporaryDirectory(prefix='inspector-filter-cases-')
        test.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.out = self.root / 'out'
        self.out.mkdir()
        self.channel = self.root / 'container/Documents/channel'
        self.channel.mkdir(parents=True)
        self.session = dict(schemaVersion=1, runID='fresh-fixture', pid=29009,
                            bundleID=FIXTURE, profile='ios-27.0', controlTransport='directory-watch-v1')
        self.session_bytes = (json.dumps(self.session, indent=2) + '\n').encode()
        (self.channel / 'session.json').write_bytes(self.session_bytes)
        (self.channel / self.session['runID']).mkdir()
        self.journal = self.channel / self.session['runID'] / 'events.jsonl'
        self.elapsed = 3.9055  # Native launch/readiness already consumed this budget.
        self.clock = SimpleNamespace(monotonic=lambda: self.elapsed,
                                     time=lambda: 1000 + self.elapsed, sleep=self.advance)
        self.rows = [self.row('runtime.installed', t_ms=1)]
        self.filter = 'none'
        self.actor = INSPECTOR
        self.rpc_count = 0
        self.foreground_costs = FOREGROUND_COSTS
        self.calls = []
        self.launches = []
        self.probes = []
        self.connections = {}
        self.closed_contexts = []
        self.context_events = []
        self.connection_fault = None
        self.control_error = None
        self.nonces = iter([uuid.UUID(int=101), uuid.UUID(int=102)])
        self.probe = self.new_probe('basic-consumer', 30378, 0, self.out)
        self.publish()

    def advance(self, delay):
        self.elapsed += delay

    def row(self, event, **fields):
        return dict(self.session, sequence=len(getattr(self, 'rows', [])) + 1,
                    event=event, wallTimeMS=1000000 + fields.get('t_ms', 1), **fields)

    def new_probe(self, nonce, pid, started, out):
        path = self.native_receipt(nonce, pid, started, out)
        return RUNNER['ProbeReader'](path, nonce, self.session, container=path.parent.parent)

    def native_receipt(self, nonce, pid, started, out):
        path = out / 'native-container/Documents/cksim-inspector-results.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        self.active_probe = dict(nonce=nonce, pid=pid, started=started, path=path)
        self.probes.append(self.active_probe)
        return path

    def references(self, rows):
        source = 'docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md'
        def reference(name, device, **fields):
            return dict(id=name, deviceValue=device, sourcePath=source,
                        deviceProvenance='LCK · iPhone 13 · iOS 27.0', **fields)
        values = [reference('pushReport', '≈190 ms'), reference('answerAudio', '≈236 ms'),
                  reference('muteEcho', '8–17 ms after fulfillment'),
                  reference('unreportedPush', '≈4.4 s')]
        if len(rows) >= 4:
            values[0].update(actualMS=190, startSequence=2, endSequence=3)
        if len(rows) >= 8:
            values[1].update(actualMS=236, startSequence=5, endSequence=8,
                             actualLabel='Simulator · CallKit answer delivered → audio.activated')
        return values

    def publish(self):
        self.journal.write_text(''.join(json.dumps(row) + '\n' for row in self.rows))
        for record in self.probes:
            # A suspended process publishes again only when explicitly resumed.
            if record is not self.active_probe:
                continue
            if hasattr(self, 'active_connection'):
                try:
                    batch = self.active_connection.bridge.events(record.get('cursor', 0))
                    record['cursor'] = batch['cursor']
                    record.setdefault('timeline', []).extend(batch['events'])
                    record['session'], record['online'], record['error'] = batch['session'], True, None
                except RuntimeError as error:
                    record['online'], record['error'] = False, str(error)
            else:
                record.update(cursor=len(self.rows), timeline=list(self.rows), session=self.session, online=True)
            observed = record.get('timeline', [])
            calls = [row for row in observed if row['event'] == 'call.changed']
            current = calls[-1:]
            configured = [row for row in observed if row['event'] == 'incomingFilter.configured']
            receipt = dict(nonce=record['nonce'], inspectorPID=record['pid'],
                           inspectorBundleID=INSPECTOR,
                           inspectorDataContainer=str(record['path'].parent.parent),
                           startedWallTimeMS=(1000 + record['started']) * 1000,
                           wallTimeMS=self.clock.time() * 1000, session=record.get('session'),
                           cursor=record.get('cursor', 0), online=record.get('online', False),
                           incomingFilter=configured[-1]['reason'] if configured else 'none',
                           audioActive=any(row['event'] == 'audio.activated' for row in observed), conversations=current,
                           pending=[], timeline=observed, timingReferences=self.references(observed),
                           timelinePresentation=[dict(sequence=6, title='Answer fulfilled',
                               detail='system · 125 ms · 60 s profile budget')])
            if record.get('error'):
                receipt['error'] = record['error']
            if current and current[0].get('ringing'):
                receipt['incoming'] = current[0]
            record['path'].write_text(json.dumps(receipt))

    def rpc(self, *parts, **options):
        if parts[:3] == ('xcrun', 'simctl', 'launch'):
            cost = self.foreground_costs[self.rpc_count % len(self.foreground_costs)]
            self.rpc_count += 1
            self.calls.append(('activate', parts[-1], self.elapsed, options['timeout']))
            if cost >= options['timeout']:
                self.advance(options['timeout'])
                raise RuntimeError('modeled native foreground timed out inside consumer budget')
            self.advance(cost)
            self.actor = parts[-1]
            self.publish()
            pid = self.session['pid'] if self.actor == FIXTURE else self.active_probe['pid']
            return self.actor + ': ' + str(pid)
        if 'watch' in parts:
            return self.journal.read_text()
        if parts[:3] == ('xcrun', 'simctl', 'io'):
            return ''
        raise AssertionError('Unexpected host/native operation: ' + repr(parts))

    def control_factory(self, channel, session, target, deadline):
        self.test.assertEqual(channel, self.channel)
        self.test.assertEqual(session, self.session)
        def send(operation, **fields):
            RUNNER['remaining_budget'](deadline)
            self.test.assertEqual(self.actor, FIXTURE, 'controls require the foreground fixture')
            self.calls.append(('control', operation, fields.get('reason')))
            if self.control_error is not None:
                raise self.control_error
            self.advance(.25)
            if operation == 'push':
                self.rows += [self.row('push.received', t_ms=100, pushID='push'),
                              dict(self.row('report.completed', t_ms=290, pushID='push', error=0), sequence=3),
                              dict(self.row('call.changed', t_ms=295, uuid=CALL, callerName='Alex Morgan',
                                            ringing=True, connected=False, ended=False), sequence=4)]
                result, identifier = {}, 'push'
            elif operation == 'answer':
                delivery = self.row('action.deadline', t_ms=300, actionID='answer', kind='answer',
                                    origin='system', callUUID=CALL, apiKind='callkit')
                self.rows += [delivery, dict(delivery, sequence=6, event='action.settled', t_ms=425,
                                            fulfilled=True, latencyMS=125, deadlineSeconds=60),
                              dict(self.rows[-1], sequence=7, t_ms=430, ringing=False, connected=True),
                              dict(self.row('audio.activated', t_ms=536), sequence=8)]
                result, identifier = dict(actionIDs=['answer']), 'answer'
            elif operation == 'incoming-filter':
                self.filter = fields['reason']
                code, verification = (3, 'verified') if self.filter == 'do-not-disturb' else (0, 'not-applicable')
                identifier = 'filter-' + self.filter
                self.rows.append(self.row('incomingFilter.configured', t_ms=600 + len(self.rows),
                                           requestID=identifier, reason=self.filter, code=code, verification=verification))
                result = dict(incomingFilter=dict(reason=self.filter, code=code, verification=verification))
            else:
                raise AssertionError(operation)
            self.publish()
            return json.dumps(dict(success=True, id=identifier, result=result))
        return send

    def make_connection(self, name):
        connection = SimpleNamespace(
            bridge=SHIPPING['InspectorBridge'](SimpleNamespace(bundle=FIXTURE), 'device', self.channel),
            session=dict(self.session), target_container=self.channel.parent.parent, alive=True,
            launch_environment={'SIMCTL_CHILD_CKSIM_TEST_BRIDGE': name})
        connection.is_alive = lambda: connection.alive
        self.connections[name] = connection
        return connection

    @contextmanager
    def bridge_factory(self, args, target):
        self.test.assertEqual(target, 'device')
        self.test.assertEqual(args.bundle, FIXTURE)
        self.test.assertEqual(args.app_container, self.channel.parent.parent)
        self.test.assertEqual(args.runtime_dir, Path(__file__).resolve().parents[2])
        self.test.assertEqual(args.timeout, 15)
        self.test.assertEqual(self.actor, FIXTURE, 'prepare fixture before opening a new bridge')
        name = 'case-' + str(len(self.connections))
        connection = self.connection if self.connection_fault == 'same' else self.make_connection(name)
        if self.connection_fault == 'session':
            connection.session = dict(self.session, pid=99999)
        elif self.connection_fault == 'container':
            connection.target_container = self.root / 'foreign-container'
        self.context_events.append(('open', name))
        try:
            yield connection
        finally:
            connection.alive = False
            self.closed_contexts.append(connection)
            self.context_events.append(('close', name))

    def locate_probe(self, display, nonce, bundle):
        self.test.assertEqual((display, bundle), ('device', INSPECTOR))
        return self.active_probe['path'] if nonce == self.active_probe['nonce'] else None

    def supervise(self, command, *, env, log, observe, bridge_alive,
                  host_timeout, consumer_timeout, redactions, bundle):
        # This is the native-child boundary. Production launch_inspector must
        # have validated and written the baseline before reaching this point.
        out = log.parent
        self.test.assertEqual(command, ['xcrun', 'simctl', 'launch',
                                       '--terminate-running-process', 'device', INSPECTOR])
        self.test.assertEqual((host_timeout, consumer_timeout, bundle), (180, 25, INSPECTOR))
        self.test.assertTrue(bridge_alive())
        self.test.assertEqual(self.actor, FIXTURE, 'foreground fixture before starting a new consumer')
        baseline = json.loads((out / 'case-baseline.json').read_text())
        self.test.assertEqual(baseline['name'], out.name)
        self.test.assertEqual(baseline['journalSHA256'], hashlib.sha256(self.journal.read_bytes()).hexdigest())
        self.test.assertEqual(baseline['sessionSHA256'], hashlib.sha256(self.session_bytes).hexdigest())
        self.test.assertEqual({key: baseline[key] for key in ('runID', 'pid', 'bundleID')},
                             {key: self.session[key] for key in ('runID', 'pid', 'bundleID')})
        started = self.elapsed
        self.active_connection = self.connections[env['SIMCTL_CHILD_CKSIM_TEST_BRIDGE']]
        nonce = env['SIMCTL_CHILD_CKSIM_INSPECTOR_PROBE_NONCE']
        pid = 30400 + len(self.launches)
        self.native_receipt(nonce, pid, started, out)
        self.launches.append(dict(nonce=nonce, pid=30400 + len(self.launches), out=out,
                                  started=started, deadline=started + 25, before=self.filter))
        self.actor = INSPECTOR
        self.advance(3.9055)
        self.publish()
        self.launches[-1]['bootstrap_cursor'] = self.active_probe.get('cursor', 0)
        self.launches[-1]['bootstrap_rows'] = len(self.active_probe.get('timeline', []))
        log.write_text(INSPECTOR + ': ' + str(pid) + '\n')
        value = observe()
        if value is None:
            raise RuntimeError(self.active_probe.get('error') or 'Native projection unavailable')
        self.test.assertTrue(value['online'])
        self.test.assertEqual(value['inspectorPID'], pid)
        return value, started + 25

    def patches(self):
        self.connection = self.make_connection('base')
        self.active_connection = self.connection
        self.active_probe.update(cursor=0, timeline=[])
        self.publish()
        globals_ = RUNNER['journal_journey'].__globals__
        return patch.dict(globals_, time=self.clock, run=self.rpc,
                          consumer_control=self.control_factory,
                          _shipping_tools=lambda: dict(inspector_bridge=self.bridge_factory),
                          locate_probe=self.locate_probe, supervise_launch=self.supervise,
                          uuid=SimpleNamespace(UUID=uuid.UUID, uuid4=lambda: next(self.nonces)))


class FilterCaseTests(unittest.TestCase):
    def cold_launch(self, ack_delay, *, stale_after_reap=False):
        """Run the actual supervisor/ProbeReader with a fake clock and host child."""
        world = NativeWorld(self)
        world.actor = FIXTURE
        out = world.out / 'cold-entry'; out.mkdir()
        started = world.elapsed
        process = SimpleNamespace(pid=77001, returncode=None)
        process.poll = lambda: process.returncode
        reaped = []
        def reap(child):
            self.assertIs(child, process)
            reaped.append(True)
            child.returncode = -signal.SIGKILL
            world.advance(.001)
        def locate(display, nonce, bundle):
            if ack_delay is None or world.elapsed - started < ack_delay:
                return None
            if not reaped or not stale_after_reap:
                if not getattr(process, 'published', False):
                    # The observed OS entry was20.609s after host issuance.
                    world.native_receipt(nonce, 30400, started + 20.609, out)
                    process.published = True
                world.publish()
            return world.locate_probe(display, nonce, bundle)
        launch = RUNNER['launch_inspector']
        supervisor = launch.__globals__['supervise_launch']
        helper = sys.modules['inspector_startup']
        with world.patches(), patch.dict(launch.__globals__, supervise_launch=supervisor, locate_probe=locate), \
             patch.object(helper, 'time', world.clock), \
             patch.object(helper.subprocess, 'Popen', return_value=process) as spawn, \
             patch.object(helper.threading, 'Timer', return_value=Mock(ident=None)), \
             patch.object(helper, 'reap_group', side_effect=reap):
            try:
                probe, deadline = launch(world.connection, 'device', 'cold-native', world.session,
                                         world.channel, out, True)
                self.assertAlmostEqual(deadline - started, 25)
                self.assertEqual(probe.pid, 30400)
                return world.elapsed - started
            finally:
                self.assertEqual(spawn.call_count, 1)
                self.assertEqual(reaped, [True])

    def test_authenticated_cold_launch_ack_after20_stays_inside_original25(self):
        self.assertLess(self.cold_launch(22), 25)

    def test_cold_launch_without_authenticated_ack_before25_is_terminal(self):
        for delay in (None, 25, 26):
            with self.subTest(ack_delay=delay):
                with self.assertRaisesRegex(RuntimeError, 'timed out'):
                    self.cold_launch(delay)

    def test_cold_launch_requires_fresh_authenticated_publication_after_reap(self):
        with self.assertRaisesRegex(RuntimeError, 'post-reap native publication budget expired'):
            self.cold_launch(22, stale_after_reap=True)

    def test_cold_launch_timeout_records_the_startup_reason_without_replay(self):
        with patch.object(sys.modules['sim'], 'report_failure') as classified:
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                self.cold_launch(None)
        classified.assert_called_once()
        label, reason = classified.call_args.args
        self.assertEqual(label, 'infra:startup')
        for detail in ('Inspector', 'timeout', 'host=180s', 'consumer=25s', 'never replayed'):
            self.assertIn(detail, reason)

    def test_stale_post_reap_publication_is_not_an_infrastructure_timeout(self):
        with patch.object(sys.modules['sim'], 'report_failure') as classified:
            with self.assertRaisesRegex(RuntimeError, 'post-reap native publication budget expired'):
                self.cold_launch(22, stale_after_reap=True)
        classified.assert_not_called()

    def test_planned_consumers_finish_with_observed_foreground_costs(self):
        world = NativeWorld(self)
        with world.patches():
            result = RUNNER['journal_cases']([], 'device', 'basic-consumer', world.session,
                world.out, 25, world.channel, world.connection, verify_filters=True, probe=world.probe)
        self.assertIs(result['success'], True)
        self.assertEqual(len(world.launches), 2)
        self.assertEqual([row['before'] for row in world.launches], ['none', 'do-not-disturb'])
        self.assertEqual([row['out'].name for row in world.launches], ['filter-do-not-disturb', 'filter-none'])
        self.assertEqual(len({row['nonce'] for row in world.launches}), 2)
        self.assertEqual(len({row['pid'] for row in world.launches}), 2)
        self.assertGreater(world.elapsed, 25)
        for row in world.launches:
            self.assertAlmostEqual(row['deadline'] - row['started'], 25)
        self.assertEqual(world.filter, 'none')
        self.assertEqual([entry[2] for entry in world.calls if entry[:2] == ('control', 'incoming-filter')],
                         ['do-not-disturb', 'none'])
        first, second = [json.loads((row['out'] / 'case-baseline.json').read_text()) for row in world.launches]
        self.assertNotEqual(first['journalSHA256'], second['journalSHA256'])
        self.assertLess(first['journalBytes'], second['journalBytes'])
        self.assertEqual(first['sessionSHA256'], second['sessionSHA256'])
        self.assertEqual([row['bootstrap_cursor'] for row in world.launches], [8, 9])
        self.assertEqual([row['bootstrap_rows'] for row in world.launches], [8, 9])
        self.assertEqual([kind for kind, _ in world.context_events], ['open', 'close', 'open', 'close'])
        self.assertEqual(len(world.closed_contexts), 2)
        self.assertTrue(all(not connection.is_alive() for connection in world.closed_contexts))
        self.assertTrue(world.connection.is_alive(), 'the caller still owns the original base context')

    def test_reused_advanced_shipping_bridge_rejects_new_consumer_cursor_zero(self):
        world = NativeWorld(self)
        out = world.out / 'reused-bridge'
        out.mkdir()
        with world.patches():
            result = RUNNER['journal_journey']([], 'device', 'basic-consumer', world.session,
                world.out, 25, world.channel, probe=world.probe)
            self.assertIs(result['success'], True)
            self.assertEqual(world.connection.bridge.journal.sequence, 8)
            RUNNER['activate_existing']('device', FIXTURE, world.session['pid'],
                                       deadline=world.elapsed + 20)
            with self.assertRaisesRegex(RuntimeError, 'Timeline cursor changed'):
                RUNNER['launch_inspector'](world.connection, 'device', 'new-consumer',
                    world.session, world.channel, out, True)
        self.assertEqual(world.active_probe.get('cursor', 0), 0)
        self.assertFalse(world.active_probe['online'])

    def test_combined_foreground_trace_cannot_reset_the_existing_consumer(self):
        world = NativeWorld(self)
        activate = RUNNER['activate_existing']
        with world.patches():
            world.probe.read()  # Pin the original native process and startup.
            for bundle in (FIXTURE, INSPECTOR) * 3:
                pid = world.session['pid'] if bundle == FIXTURE else world.probe.pid
                activate('device', bundle, pid, deadline=25)
            with self.assertRaisesRegex(RuntimeError, 'foreground timed out'):
                activate('device', FIXTURE, world.session['pid'], deadline=25)
            self.assertAlmostEqual(world.elapsed, 25)
            world.advance(.001)
            with self.assertRaisesRegex(RuntimeError, 'background budget expired'):
                world.probe.read()
        self.assertEqual(world.rpc_count, 7, 'an exhausted consumer must not be replayed')

    def test_case_baseline_hashes_original_bytes_before_any_new_consumer(self):
        world = NativeWorld(self)
        out = world.out / 'baseline'
        out.mkdir()
        # Include an incomplete producer tail: the baseline hashes bytes,
        # while the shipping journal reader accepts only complete rows.
        original = world.journal.read_bytes() + b'{"incomplete":'
        world.journal.write_bytes(original)
        RUNNER['record_case_baseline'](out, world.channel, world.session, 'do-not-disturb')
        baseline = json.loads((out / 'case-baseline.json').read_text())
        self.assertEqual({key: baseline[key] for key in ('runID', 'pid', 'bundleID')},
                         {key: world.session[key] for key in ('runID', 'pid', 'bundleID')})
        self.assertEqual(baseline['journalSHA256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(baseline['journalBytes'], len(original))
        self.assertEqual(baseline['sessionSHA256'], hashlib.sha256(world.session_bytes).hexdigest())
        self.assertEqual(world.launches, [])

    def test_native_launch_owner_records_baseline_before_supervisor(self):
        world = NativeWorld(self)
        world.actor = FIXTURE
        out = world.out / 'native-entry'
        out.mkdir()
        with world.patches():
            probe, deadline = RUNNER['launch_inspector'](world.connection, 'device', 'fresh-native',
                world.session, world.channel, out, True)
        self.assertEqual(len(world.launches), 1)
        self.assertEqual(probe.pid, 30400)
        self.assertEqual(probe.nonce, 'fresh-native')
        self.assertEqual(probe.container, probe.path.parent.parent)
        self.assertAlmostEqual(deadline - world.launches[0]['started'], 25)
        self.assertTrue((out / 'case-baseline.json').exists())

    def test_native_launch_owner_rejects_changed_session_before_supervisor(self):
        world = NativeWorld(self)
        out = world.out / 'native-entry'
        out.mkdir()
        (world.channel / 'session.json').write_text(json.dumps(dict(world.session, pid=99999)))
        with world.patches():
            with self.assertRaisesRegex(RuntimeError, 'session changed'):
                RUNNER['launch_inspector'](world.connection, 'device', 'fresh-native',
                    world.session, world.channel, out, True)
        self.assertEqual(world.launches, [])
        self.assertFalse((out / 'case-baseline.json').exists())

    def test_unsuccessful_basic_case_never_starts_a_filter_consumer(self):
        cases = RUNNER['journal_cases']
        for success in (False, 0, 1, 'true', None):
            with self.subTest(success=success):
                world = NativeWorld(self)
                with world.patches(), patch.dict(cases.__globals__,
                        journal_journey=lambda *args, **kwargs: dict(success=success)):
                    with self.assertRaisesRegex(RuntimeError, 'incoming/answer case did not succeed'):
                        cases([], 'device', 'basic-consumer', world.session, world.out,
                              25, world.channel, world.connection, verify_filters=True, probe=world.probe)
                self.assertEqual(world.launches, [])
                self.assertEqual(world.calls, [])
                self.assertEqual(world.context_events, [])

    def test_basic_exception_is_preserved_without_starting_filter_consumers(self):
        world = NativeWorld(self)
        failure = RuntimeError('entered incoming/answer consumer failed')
        def failed(*args, **kwargs):
            raise failure
        cases = RUNNER['journal_cases']
        with world.patches(), patch.dict(cases.__globals__, journal_journey=failed):
            with self.assertRaises(RuntimeError) as raised:
                cases([], 'device', 'basic-consumer', world.session, world.out,
                      25, world.channel, world.connection, verify_filters=True, probe=world.probe)
        self.assertIs(raised.exception, failure)
        self.assertEqual(world.launches, [])
        self.assertEqual(world.context_events, [])

    def test_unsuccessful_filter_case_never_starts_the_clear_consumer(self):
        cases = RUNNER['run_filter_cases']
        for success in (False, 0, 1, 'true', None):
            with self.subTest(success=success):
                world = NativeWorld(self)
                with world.patches(), patch.dict(cases.__globals__,
                        filter_journey=lambda *args, **kwargs: dict(success=success)):
                    with self.assertRaisesRegex(RuntimeError, 'filter case did not succeed'):
                        cases([], 'device', world.connection, world.session, world.channel, world.out)
                self.assertEqual(len(world.launches), 1)
                self.assertEqual(world.launches[0]['out'].name, 'filter-do-not-disturb')
                self.assertFalse((world.out / 'filter-none').exists())
                self.assertEqual(len(world.closed_contexts), 1)
                self.assertFalse(world.closed_contexts[0].is_alive())

    def test_entered_filter_exception_is_preserved_without_a_new_consumer(self):
        world = NativeWorld(self)
        world.control_error = RuntimeError('entered filter control failed')
        with world.patches():
            with self.assertRaises(RuntimeError) as raised:
                RUNNER['run_filter_cases']([], 'device', world.connection,
                                           world.session, world.channel, world.out)
        self.assertIs(raised.exception, world.control_error)
        self.assertEqual(len(world.launches), 1)
        self.assertFalse((world.out / 'filter-none').exists())
        self.assertEqual(len(world.closed_contexts), 1)
        self.assertFalse(world.closed_contexts[0].is_alive())

    def test_native_timeout_aborts_filter_plan_without_retry(self):
        world = NativeWorld(self)
        # Setup is healthy. The first entered consumer's foreground RPC stalls.
        world.foreground_costs = (1, 30)
        with world.patches():
            with self.assertRaisesRegex(RuntimeError, 'foreground timed out'):
                RUNNER['run_filter_cases']([], 'device', world.connection,
                                           world.session, world.channel, world.out)
        self.assertEqual(len(world.launches), 1)
        self.assertEqual(world.rpc_count, 2)
        self.assertFalse((world.out / 'filter-none').exists())
        self.assertEqual(len(world.closed_contexts), 1)
        self.assertFalse(world.closed_contexts[0].is_alive())

    def test_filter_wait_cannot_reset_the_native_process_start_deadline(self):
        world = NativeWorld(self)
        world.elapsed = 24
        world.publish()
        with world.patches():
            with self.assertRaisesRegex(RuntimeError, 'foreground timed out'):
                RUNNER['filter_journey']([], 'device', 'basic-consumer', world.session,
                    world.out, 100, world.channel, world.probe, before='none',
                    reason='do-not-disturb', code=3, verification='verified')
        self.assertAlmostEqual(world.elapsed, 25)
        self.assertAlmostEqual(world.calls[-1][-1], 1)
        self.assertEqual(world.rpc_count, 1)

    def test_changed_fixture_between_successful_cases_is_not_relaunched(self):
        world = NativeWorld(self)
        cases = RUNNER['run_filter_cases']
        journey = RUNNER['filter_journey']
        def replace_fixture(*args, **kwargs):
            result = journey(*args, **kwargs)
            self.assertIs(result['success'], True)
            (world.channel / 'session.json').write_text(json.dumps(dict(world.session, pid=99999)))
            return result
        with world.patches(), patch.dict(cases.__globals__, filter_journey=replace_fixture):
            with self.assertRaisesRegex(RuntimeError, 'session changed'):
                cases([], 'device', world.connection, world.session, world.channel, world.out)
        self.assertEqual(len(world.launches), 1)
        self.assertTrue((world.out / 'filter-do-not-disturb/inspector-filter-do-not-disturb.json').exists())
        self.assertFalse((world.out / 'filter-none/case-baseline.json').exists())
        self.assertEqual(len(world.closed_contexts), 1)
        self.assertFalse(world.closed_contexts[0].is_alive())

    def test_reused_or_changed_bridge_is_closed_before_any_native_consumer(self):
        for fault in ('same', 'session', 'container'):
            with self.subTest(fault=fault):
                world = NativeWorld(self)
                world.connection_fault = fault
                with world.patches():
                    with self.assertRaises(RuntimeError):
                        RUNNER['run_filter_cases']([], 'device', world.connection,
                            world.session, world.channel, world.out)
                self.assertEqual(world.launches, [])
                self.assertEqual([kind for kind, _ in world.context_events], ['open', 'close'])
                self.assertEqual(len(world.closed_contexts), 1)
                self.assertFalse(world.closed_contexts[0].is_alive())
                self.assertFalse((world.out / 'filter-none').exists())


if __name__ == '__main__':
    unittest.main()
