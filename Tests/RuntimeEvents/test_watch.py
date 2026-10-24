"""Host controls for the shipping reader; fixtures are synthetic."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace
from contextlib import redirect_stdout, redirect_stderr
from io import StringIO

CLI = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture')
        (self.root / 'session.json').write_text(json.dumps(self.session))
        (self.root / 'run').mkdir()
        self.path = self.root / 'run/events.jsonl'
        self.path.write_bytes(b'')
        self.row = dict(self.session, event='call.changed', sequence=1, t_ms=25, wallTimeMS=1000)
        self.reader = CLI['RuntimeJournal'](self.root, 'test.fixture')

    def append(self, row):
        with self.path.open('ab') as output:
            output.write(json.dumps(row).encode() + b'\n')

    def test_partial_write_and_incremental_read(self):
        encoded = json.dumps(self.row).encode()
        self.path.write_bytes(encoded[:10])
        self.assertEqual(self.reader.read(), [])
        with self.path.open('ab') as output:
            output.write(encoded[10:] + b'\n')
        self.assertEqual(self.reader.read(), [self.row])
        self.assertEqual(self.reader.read(), [])
        self.append(dict(self.row, sequence=2))
        self.assertEqual(self.reader.read()[0]['sequence'], 2)

    def test_rejects_identity_version_and_sequence(self):
        for field, value in [('schemaVersion', 2), ('runID', 'other'), ('pid', 456),
                             ('bundleID', 'other'), ('sequence', 2), ('t_ms', '25'), ('wallTimeMS', None)]:
            with self.subTest(field=field):
                self.path.write_bytes(b'')
                reader = CLI['RuntimeJournal'](self.root, 'test.fixture')
                self.append(dict(self.row, **{field: value}))
                with self.assertRaisesRegex(RuntimeError, 'inconsistent'):
                    reader.read()

    def test_duplicate_truncation_and_restart(self):
        self.append(self.row)
        self.reader.read()
        self.append(self.row)
        with self.assertRaisesRegex(RuntimeError, 'inconsistent'):
            self.reader.read()
        self.path.write_bytes(b'')
        with self.assertRaisesRegex(RuntimeError, 'truncated'):
            self.reader.read()
        (self.root / 'session.json').write_text(json.dumps(dict(self.session, runID='new')))
        with self.assertRaisesRegex(RuntimeError, 'session changed'):
            self.reader.read()

    def test_rejects_unsafe_session(self):
        for field, value in [('runID', '../outside'), ('runID', None), ('runID', 42),
                             ('pid', True), ('schemaVersion', 2), ('bundleID', 'other')]:
            with self.subTest(field=field):
                (self.root / 'session.json').write_text(json.dumps(dict(self.session, **{field: value})))
                with self.assertRaisesRegex(RuntimeError, 'Invalid runtime session'):
                    CLI['RuntimeJournal'](self.root, 'test.fixture')

    def test_watch_follows_restart_with_missing_session_gap(self):
        previous = Mock()
        previous.read.side_effect = [FileNotFoundError(), RuntimeError('Runtime session changed')]
        current = Mock(session=dict(self.session, runID='new'))
        new_row = dict(self.row, runID='new')
        current.read.return_value = [new_row]
        clock = Mock()
        clock.monotonic.side_effect = [0, 0, 2]
        output, diagnostics = StringIO(), StringIO()
        watch = CLI['watch']
        with patch.dict(watch.__globals__, RuntimeJournal=Mock(side_effect=[previous, current]),
                        simctl=Mock(return_value='/unused'), time=clock):
            with redirect_stdout(output), redirect_stderr(diagnostics):
                watch(SimpleNamespace(bundle='test.fixture', after=99, duration=1, json=True), 'device')
        self.assertEqual(json.loads(output.getvalue()), new_row)
        self.assertIn('disconnected', diagnostics.getvalue())
        self.assertIn('following new', diagnostics.getvalue())

    def test_timeline_shows_action_budget_and_latency(self):
        row = dict(self.row, event='action.settled', kind='answer', origin='system',
                   deadlineSeconds=30, apiKind='livecommunicationkit', fulfilled=True, latencyMS=123.4)
        line = CLI['timeline_line'](row)
        for expected in ('answer', 'system', 'budget 30s', 'livecommunicationkit', '123.4ms', 'fulfilled'):
            self.assertIn(expected, line)


class ControlTransportTests(unittest.TestCase):
    def exercise(self, transport, *, mismatch=False, response=True):
        with tempfile.TemporaryDirectory() as work:
            container = Path(work)
            root = container / 'Documents/.callkit-simulator'
            mailbox = root / 'run'
            for name in ('requests', 'responses'):
                (mailbox / name).mkdir(parents=True)
            session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture', notification='test.notify')
            if transport is not None:
                session['controlTransport'] = transport
            (root / 'session.json').write_text(json.dumps(session))
            args = SimpleNamespace(bundle='test.fixture', operation='status', runtime_dir=container,
                                   command_receipt=None, timeout=1)
            calls = []
            elapsed = [0.0]
            def respond(_=None):
                elapsed[0] += 0.1
                if response:
                    request = json.loads(next((mailbox / 'requests').glob('*.json')).read_text())
                    if mismatch:
                        request['pid'] += 1
                    (mailbox / 'responses' / (request['id'] + '.json')).write_text(json.dumps(dict(request, success=True)))
            def simctl(*parts):
                calls.append(parts)
                if parts[0] == 'get_app_container':
                    return str(container)
                if parts[0] == 'spawn':
                    if transport == 'directory-watch-v1':
                        raise RuntimeError('target simctl spawn stalled')
                    respond()
                    return ''
                raise AssertionError(parts)
            control = CLI['control']
            clock = SimpleNamespace(monotonic=lambda: elapsed[0], sleep=respond)
            with patch.dict(control.__globals__, simctl=simctl, time=clock):
                if mismatch:
                    with self.assertRaisesRegex(RuntimeError, 'response identity mismatch'):
                        control(args, 'device', expected_session=session)
                elif not response:
                    with self.assertRaisesRegex(RuntimeError, 'outcome is unknown'):
                        control(args, 'device', expected_session=session)
                else:
                    self.assertTrue(control(args, 'device', expected_session=session)['success'])
            return calls

    def test_watched_mailbox_does_not_need_a_simulator_spawn(self):
        calls = self.exercise('directory-watch-v1')
        self.assertEqual([call[0] for call in calls], ['get_app_container'])

    def test_older_runtime_still_receives_its_darwin_notification(self):
        calls = self.exercise(None)
        self.assertEqual([call[0] for call in calls], ['get_app_container', 'spawn'])

    def test_watched_response_must_match_the_pinned_command(self):
        self.exercise('directory-watch-v1', mismatch=True)

    def test_missing_watched_response_is_still_an_unknown_outcome(self):
        self.exercise('directory-watch-v1', response=False)


class CachedContainerTests(unittest.TestCase):
    DEVICE = '00000000-0000-0000-0000-000000000001'
    OTHER_DEVICE = '00000000-0000-0000-0000-000000000003'

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.base = Path(self.work.name)
        self.container = self.base / 'Devices' / self.DEVICE / 'data/Containers/Data/Application/00000000-0000-0000-0000-000000000002'
        self.root = self.container / 'Documents/.callkit-simulator'
        self.mailbox = self.root / 'run'
        for name in ('requests', 'responses'):
            (self.mailbox / name).mkdir(parents=True)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture',
                            notification='test.notify', controlTransport='directory-watch-v1')
        (self.root / 'session.json').write_text(json.dumps(self.session))
        self.row = dict(self.session, event='runtime.installed', sequence=1, t_ms=1, wallTimeMS=1000)
        (self.mailbox / 'events.jsonl').write_text(json.dumps(self.row) + '\n')
        self.args = SimpleNamespace(app_container=self.container, bundle='test.fixture', operation='status',
                                    command_receipt=None, runtime_dir=self.base, timeout=1)

    def test_cached_control_needs_no_target_simulator_rpc(self):
        control = CLI['control']
        elapsed = [0.0]
        def respond(_):
            elapsed[0] += 0.1
            request = json.loads(next((self.mailbox / 'requests').glob('*.json')).read_text())
            (self.mailbox / 'responses' / (request['id'] + '.json')).write_text(json.dumps(dict(request, success=True)))
        rpc = Mock(side_effect=AssertionError('target RPC unavailable'))
        clock = SimpleNamespace(monotonic=lambda: elapsed[0], sleep=respond)
        with patch.dict(control.__globals__, simctl=rpc, time=clock):
            self.assertTrue(control(self.args, self.DEVICE, expected_session=self.session)['success'])
        rpc.assert_not_called()

    def test_cached_watch_needs_no_target_simulator_rpc(self):
        watch = CLI['watch']
        args = SimpleNamespace(**vars(self.args), duration=1, after=0, json=True)
        rpc = Mock(side_effect=AssertionError('target RPC unavailable'))
        clock = Mock()
        clock.monotonic.side_effect = [0, 2]
        output = StringIO()
        with patch.dict(watch.__globals__, simctl=rpc, time=clock), redirect_stdout(output):
            watch(args, self.DEVICE)
        self.assertEqual(json.loads(output.getvalue()), self.row)
        rpc.assert_not_called()

    def test_inspector_uses_cached_container_before_any_target_rpc(self):
        class Located(Exception):
            pass
        app = self.base / 'Inspector.app'
        app.mkdir()
        args = SimpleNamespace(**vars(self.args), app=app)
        def bridge(arguments, device, root):
            self.assertEqual(root, self.root.resolve())
            raise Located()
        inspect = CLI['inspect_app']
        rpc = Mock(side_effect=AssertionError('target RPC unavailable'))
        with patch.dict(inspect.__globals__, simctl=rpc, InspectorBridge=bridge), redirect_stderr(StringIO()):
            with self.assertRaises(Located):
                inspect(args, self.DEVICE)
        rpc.assert_not_called()

    def test_inspector_pins_initial_discovery_for_status_and_button_controls(self):
        class Ready(Exception):
            pass
        app = self.base / 'Inspector.app'
        app.mkdir()
        args = SimpleNamespace(**dict(vars(self.args), app_container=None, app=app))
        captured = []
        def bridge(arguments, device, root):
            captured.append(arguments)
            return SimpleNamespace(journal=SimpleNamespace(session=self.session))
        def status(arguments, device, expected_session):
            self.assertEqual(arguments.app_container, self.container.resolve())
            self.assertEqual(captured[0].app_container, self.container.resolve())
            self.assertEqual(expected_session, self.session)
            raise Ready()
        inspect = CLI['inspect_app']
        rpc = Mock(return_value=str(self.container))
        with patch.dict(inspect.__globals__, simctl=rpc, InspectorBridge=bridge, control=status), redirect_stderr(StringIO()):
            with self.assertRaises(Ready):
                inspect(args, self.DEVICE)
        self.assertEqual([call.args for call in rpc.call_args_list],
                         [('get_app_container', self.DEVICE, self.args.bundle, 'data')])
        self.assertIsNone(args.app_container, 'connection cache must not mutate caller arguments')

    def test_cached_container_rejects_another_device_without_writing(self):
        control = CLI['control']
        rpc = Mock(side_effect=AssertionError('target RPC unavailable'))
        with patch.dict(control.__globals__, simctl=rpc):
            with self.assertRaisesRegex(RuntimeError, 'selected simulator'):
                control(self.args, self.OTHER_DEVICE)
        self.assertEqual(list((self.mailbox / 'requests').iterdir()), [])
        rpc.assert_not_called()

    def test_missing_file_and_cross_device_symlink_caches_do_not_fall_back_to_rpc(self):
        regular_file = self.base / 'not-a-container'
        regular_file.write_text('file')
        another = self.base / 'Devices' / self.OTHER_DEVICE / 'data/Containers/Data/Application/00000000-0000-0000-0000-000000000004'
        another.mkdir(parents=True)
        linked = self.container.parent / '00000000-0000-0000-0000-000000000005'
        linked.symlink_to(another, target_is_directory=True)
        control = CLI['control']
        rpc = Mock(side_effect=AssertionError('target RPC unavailable'))
        for cached in (self.base / 'missing', regular_file, linked):
            with self.subTest(cached=cached), patch.dict(control.__globals__, simctl=rpc):
                self.args.app_container = cached
                with self.assertRaisesRegex(RuntimeError, 'selected simulator'):
                    control(self.args, self.DEVICE)
        self.assertEqual(list((self.mailbox / 'requests').iterdir()), [])
        rpc.assert_not_called()

    def test_cached_container_still_rejects_stale_session_and_wrong_bundle(self):
        control = CLI['control']
        rpc = Mock(side_effect=AssertionError('target RPC unavailable'))
        with patch.dict(control.__globals__, simctl=rpc):
            with self.assertRaisesRegex(RuntimeError, 'session changed'):
                control(self.args, self.DEVICE, expected_session=dict(self.session, pid=456))
            self.args.bundle = 'another.fixture'
            with self.assertRaisesRegex(RuntimeError, 'Invalid runtime session'):
                control(self.args, self.DEVICE)
        self.assertEqual(list((self.mailbox / 'requests').iterdir()), [])
        rpc.assert_not_called()


if __name__ == '__main__':
    unittest.main()
