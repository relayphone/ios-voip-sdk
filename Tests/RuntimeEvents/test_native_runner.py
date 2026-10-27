import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid

import run


class RunnerTests(unittest.TestCase):
    def test_reused_fixture_still_launches_a_fresh_pinned_session_without_reinstall(self):
        app = Path('/owned/RuntimeEventFixture.app')
        with patch.object(run.uuid, 'uuid4', return_value='fresh'):
            with patch.object(run, 'run', return_value=run.BUNDLE + ': 42') as transport, \
                 patch.object(run, 'fixture_applications', return_value=Path('/owned/applications')), \
                 patch.object(run, 'discover_fixture_channel', return_value=Path('/owned/container/Documents/.callkit-simulator')):
                channel, run_id = run.launch_fixture('owned', app, install=False)
        self.assertEqual(channel, Path('/owned/container/Documents/.callkit-simulator'))
        self.assertEqual(run_id, 'fixture-fresh')
        self.assertEqual([call.args[2] for call in transport.call_args_list], ['launch'])
        self.assertIn('--terminate-running-process', transport.call_args_list[0].args)
        self.assertEqual(transport.call_args_list[0].kwargs['env']['SIMCTL_CHILD_CKSIM_RUN_ID'], run_id)

    def test_initial_stimulus_is_sent_after_slow_host_readiness(self):
        """A launch-time ring may already have expired when transport returns."""
        class StimulusSent(Exception):
            pass
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            channel = root / 'Documents/.callkit-simulator'
            (channel / 'session').mkdir(parents=True)
            session = dict(runID='session', pid=123, bundleID=run.BUNDLE, controlTransport='directory-watch-v1')
            (channel / 'session.json').write_text(json.dumps(session))
            # Exactly the state left when the startup ring expires before the
            # host's first observation. The next call must be host-triggered.
            (channel / 'session/events.jsonl').write_text(json.dumps(dict(
                event='call.changed', uuid='old-ring', ended=True)) + '\n')
            ready = []
            def transport(*args, **kwargs):
                if args[:4] == ('xcrun', 'simctl', 'list', 'runtimes'):
                    return json.dumps(dict(runtimes=[dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True)]))
                if args[:4] == ('xcrun', 'simctl', 'list', 'devices'):
                    return json.dumps(dict(devices={'ios-27': [dict(udid='owned', state='Booted')]}))
                if args[:3] == ('xcrun', 'simctl', 'launch'):
                    env = kwargs.get('env', {})
                    if env.get('SIMCTL_CHILD_CKSIM_RUN_ID'):
                        session['runID'] = env['SIMCTL_CHILD_CKSIM_RUN_ID']
                        (channel / session['runID']).mkdir()
                        (channel / session['runID'] / 'events.jsonl').write_text('')
                        (channel / 'session.json').write_text(json.dumps(session))
                if args[:3] == ('xcrun', 'simctl', 'launch'):
                    ready.append(True)
                    return run.BUNDLE + ': 123'
                if 'push' in args:
                    self.assertTrue(ready, 'push must follow host readiness')
                    raise StimulusSent()
                return ''
            def immediate_wait(predicate):
                value = predicate()
                if not value:
                    raise RuntimeError('Native event acceptance timed out')
                return value
            argv = ['run.py', '--package', str(root), '--app', str(root), '--out', str(root / 'out'),
                    '--simulator', 'owned', '--runtime', 'ios-27']
            with patch.object(run.sys, 'argv', argv), patch.object(run, 'run', side_effect=transport), \
                 patch.object(run, 'fixture_applications', return_value=root), \
                 patch.object(run, 'discover_fixture_channel', return_value=channel):
                with patch.object(run, 'wait', side_effect=immediate_wait), patch.object(run, 'capture_diagnostics'):
                    with self.assertRaises(StimulusSent):
                        run.main()

    def test_runtime_selection_matches_sdk_numeric_latest_available_ios(self):
        def runtime(version, available=True, platform='iOS'):
            return dict(identifier=version, version=version, name=platform+' '+version,
                        isAvailable=available, platform=platform)
        rows = [runtime('26.2'), runtime('26.5'), runtime('26.10'),
                runtime('27.0', available=False), runtime('28.0', platform='tvOS')]
        self.assertEqual(run.latest_runtime(rows), '26.10')
        with self.assertRaisesRegex(RuntimeError, 'No available iOS'):
            run.latest_runtime(rows[-2:])

    def test_fixture_readiness_rejects_a_previous_launch_session(self):
        with tempfile.TemporaryDirectory() as work:
            channel = Path(work) / 'Documents/.callkit-simulator'
            channel.mkdir(parents=True)
            session_file = channel / 'session.json'
            session_file.write_text(json.dumps(dict(runID='old-launch')))
            def transport(*args, **kwargs):
                if args[:3] == ('xcrun', 'simctl', 'launch'):
                    self.assertEqual(kwargs['env']['SIMCTL_CHILD_CKSIM_RUN_ID'], 'fixture-fresh')
                return run.BUNDLE + ': 42'
            def observe(predicate):
                self.assertIsNone(predicate(), 'stale launch must not become ready')
                session_file.write_text('{')
                self.assertIsNone(predicate(), 'partial publication must not become ready')
                session_file.write_text(json.dumps(dict(runID='fixture-fresh', pid=42)))
                return predicate()
            with patch.object(run.uuid, 'uuid4', return_value='fresh'), patch.object(run, 'run', side_effect=transport), \
                 patch.object(run, 'fixture_applications', return_value=Path(work)), \
                 patch.object(run, 'discover_fixture_channel', return_value=channel):
                with patch.object(run, 'wait', side_effect=observe):
                    actual_channel, run_id = run.launch_fixture('owned', Path(work))
                    session = run.fixture_session(actual_channel, run_id)
            self.assertEqual(actual_channel, channel)
            self.assertEqual(session['pid'], 42)

    def test_readiness_timeout_keeps_the_already_discovered_channel(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            channel = root / 'known-channel'
            devices = json.dumps(dict(runtimes=[], devices={'ios-27': [dict(udid='owned', state='Booted')]}))
            argv = ['run.py', '--package', work, '--app', work, '--out', str(root / 'out'), '--simulator', 'owned']
            with patch.object(run.sys, 'argv', argv), patch.object(run, 'run', return_value=devices):
                with patch.object(run, 'latest_runtime', return_value='ios-27'), patch.object(run, 'record_environment'):
                    with patch.object(run, 'launch_fixture', return_value=(channel, 'fresh')):
                        with patch.object(run, 'fixture_session', side_effect=RuntimeError('startup timeout')):
                            with patch.object(run, 'capture_diagnostics') as capture:
                                with self.assertRaisesRegex(RuntimeError, 'startup timeout'):
                                    run.main()
            self.assertEqual(capture.call_args.kwargs['channel'], channel)
            self.assertTrue(capture.call_args.kwargs['failed'])

    def test_cold_boot_timeout_is_explicit_and_keeps_diagnostics(self):
        failure = subprocess.TimeoutExpired(['simctl'], 300, output=b'Waiting for SpringBoard')
        with patch.object(run.simulator_infra, 'bounded', side_effect=failure) as process:
            with self.assertRaisesRegex(RuntimeError, 'Waiting for SpringBoard'):
                run.run('xcrun', 'simctl', 'bootstatus', 'owned', '-b', timeout=300)
        self.assertEqual(process.call_args.kwargs['timeout'], 300)

    def test_required_runtime_never_falls_back_to_another_os(self):
        rows = [dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True),
                dict(identifier='ios-28', version='28.0', platform='iOS', isAvailable=True)]
        self.assertEqual(run.latest_runtime(rows, 'ios-27'), 'ios-27')
        with self.assertRaisesRegex(RuntimeError, 'ios-26'):
            run.latest_runtime(rows, 'ios-26')
        rows[0]['isAvailable'] = False
        with self.assertRaisesRegex(RuntimeError, 'ios-27'):
            run.latest_runtime(rows, 'ios-27')

    def test_failure_keeps_partial_journal_even_when_log_collection_times_out(self):
        with tempfile.TemporaryDirectory() as work:
            container = Path(work) / 'container'
            channel = container / 'Documents/.callkit-simulator'
            (channel / 'run').mkdir(parents=True)
            (channel / 'session.json').write_text(json.dumps(dict(runID='run')))
            raw = b'{"sequence":1}\n{"partial":'
            (channel / 'run/events.jsonl').write_bytes(raw)
            out = Path(work) / 'diagnostics'
            with patch.object(run, 'run', side_effect=['', RuntimeError('log timeout')]) as process:
                run.capture_diagnostics(out, 'owned', channel=channel, failed=True)
            self.assertEqual((out / 'runtime-journal/run/events.jsonl').read_bytes(), raw)
            self.assertEqual(json.loads((out / 'runtime-journal/session.json').read_text())['runID'], 'run')
            self.assertIn('log timeout', (out / 'diagnostic-errors.txt').read_text())
            self.assertTrue(all(call.kwargs['timeout'] == 20 for call in process.call_args_list))

    def test_missing_container_does_not_hide_failure_or_skip_other_diagnostics(self):
        with tempfile.TemporaryDirectory() as work:
            out = Path(work)
            with patch.object(run, 'run', side_effect=['', 'fixture log']) as process:
                run.capture_diagnostics(out, 'owned', failed=True)
            self.assertEqual(process.call_count, 2)
            self.assertIn('No validated fixture channel', (out / 'diagnostic-errors.txt').read_text())
            self.assertEqual((out / 'simulator.log').read_text(), 'fixture log\n')

    def test_known_channel_is_copied_without_contacting_a_stuck_simulator(self):
        with tempfile.TemporaryDirectory() as work:
            channel = Path(work) / 'channel'
            channel.mkdir()
            (channel / 'session.json').write_text('{}')
            out = Path(work) / 'out'
            with patch.object(run, 'run', side_effect=RuntimeError('simctl stuck')) as process:
                run.capture_diagnostics(out, 'owned', channel=channel, failed=True)
            self.assertEqual((out / 'runtime-journal/session.json').read_text(), '{}')
            self.assertEqual(process.call_count, 2, 'only screenshot and logs use simctl')

    def test_full_disk_cannot_replace_the_journey_failure_or_prevent_cleanup(self):
        for failing_method in ('mkdir', 'write_text'):
            with self.subTest(failing_method=failing_method), tempfile.TemporaryDirectory() as work:
                with patch.object(Path, failing_method, side_effect=OSError('No space left on device')):
                    with patch.object(run, 'run', side_effect=RuntimeError('no container')):
                        with contextlib.redirect_stderr(io.StringIO()) as output:
                            with self.assertRaisesRegex(ValueError, 'journey failed'):
                                try:
                                    raise ValueError('journey failed')
                                finally:
                                    run.capture_diagnostics(Path(work), 'owned', failed=True)
                            self.assertIn('No space left on device', output.getvalue())

    def test_delete_is_attempted_after_shutdown_fails(self):
        with patch.object(run, 'run', side_effect=[RuntimeError('shutdown timed out'), '']) as process:
            with self.assertRaisesRegex(RuntimeError, 'shutdown timed out'):
                run.remove_simulators(['owned'])
        self.assertEqual([call.args[2] for call in process.call_args_list], ['shutdown', 'delete'])
        self.assertTrue(all(call.kwargs['timeout'] == 30 for call in process.call_args_list))

    def test_cleanup_keeps_the_original_failure(self):
        with patch.object(run, 'run', side_effect=RuntimeError('cleanup failed')) as process:
            with contextlib.redirect_stderr(io.StringIO()) as output:
                with self.assertRaisesRegex(ValueError, 'original failure'):
                    try:
                        raise ValueError('original failure')
                    finally:
                        run.remove_simulators(['owned'])
        self.assertEqual(process.call_count, 2)
        self.assertIn('cleanup failed', output.getvalue())


CLI = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))
DEVICE = '00000000-0000-0000-0000-000000000001'
BUNDLE = 'test.fixture'
SERVICES = b'PID\tStatus\tLabel\n-\t0\tUIKitApplication:test.fixture[stopped]\n'
NONCE = '00000002-1111-4111-8111-111111111111'


class PushLaunchStagingTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        directory = Path(self.work.name)
        self.container = directory / 'container'
        self.root = self.container / 'Documents/.callkit-simulator'
        payload = directory / 'payload.json'
        payload.write_text('{"type":"incomingCall","eventId":"synthetic"}')
        self.args = SimpleNamespace(bundle=BUNDLE, run_id='staged-run', payload_file=payload,
                                    must_report='true', launch_receipt=directory / 'receipt.json')
        self.stage = CLI['stage_push_launch']
        rpc = Mock(side_effect=AssertionError('Staging cannot query or launch a simulator'))
        for patcher in (patch.dict(self.stage.__globals__, simctl=rpc),
                        patch.object(CLI['subprocess'], 'run', rpc), patch.object(os, 'execvpe', rpc)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_stages_exact_envelope_receipt_and_console_command_without_simulator_io(self):
        inherited = dict(CKSIM_RUN_ID='parent-run', SIMCTL_CHILD_CKSIM_RUN_ID='old-run',
                         SIMCTL_CHILD_DYLD_INSERT_LIBRARIES='/synthetic/inherited.dylib',
                         SIMCTL_CHILD_SYNTHETIC_MARKER='preserve-me')
        with patch.dict(os.environ, inherited, clear=True), \
             patch.object(CLI['uuid'], 'uuid4', return_value=uuid.UUID(NONCE)), \
             patch.object(CLI['time'], 'time', return_value=1700000000):
            argv, env = self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
        self.assertEqual(argv, ['xcrun', 'simctl', 'launch', '--console', DEVICE, BUNDLE])
        self.assertEqual(env, dict(inherited, SIMCTL_CHILD_CKSIM_RUN_ID='staged-run'))
        raw = (b'{"bundleID": "test.fixture", "createdAtMS": 1700000000000, '
               b'"expiresAtMS": 1700000030000, "id": "00000002-1111-4111-8111-111111111111", '
               b'"mustReport": true, "payload": {"eventId": "synthetic", "type": "incomingCall"}, '
               b'"runID": "staged-run", "schemaVersion": 1}\n')
        self.assertEqual((self.root / 'push-launch.json').read_bytes(), raw)
        self.assertEqual(json.loads(self.args.launch_receipt.read_text()), dict(
            schemaVersion=1, simulatorID=DEVICE, bundleID=BUNDLE, runID='staged-run', pushID=NONCE,
            envelope=json.loads(raw), envelopeSHA256=hashlib.sha256(raw).hexdigest(), mode=0o600,
            appServiceAbsent=True, serviceQuery=SERVICES.decode(),
            serviceQuerySHA256=hashlib.sha256(SERVICES).hexdigest(), runtimeInjectionRequested=False))
        for path, mode in ((self.root, 0o700), (self.root / 'push-launch.json', 0o600),
                           (self.args.launch_receipt, 0o600)):
            with self.subTest(path=path):
                info = path.lstat()
                self.assertFalse(path.is_symlink())
                self.assertEqual(stat.S_IMODE(info.st_mode), mode)
                self.assertEqual(info.st_uid, os.getuid())
        self.assertEqual(list(self.root.glob('.push-launch-*')), [])

    def test_rejects_invalid_service_tables_and_running_target_before_staging(self):
        for services, message in ((b'', 'Invalid launchctl service table'),
                (b'PID\tStatus\tLabel\n', 'Invalid launchctl service table'),
                (b'PID\tStatus\tLabel\ninvalid\t0\tlabel\n', 'Invalid launchctl service table'),
                (SERVICES + b'123\t0\tUIKitApplication:test.fixture[running]\n', 'requires a stopped app')):
            with self.subTest(services=services), self.assertRaisesRegex(RuntimeError, message):
                self.stage(self.args, DEVICE, container=self.container, service_table=services)
            self.assertFalse(self.root.exists())
            self.assertFalse(self.args.launch_receipt.exists())

    def test_refuses_unsafe_directory_mode_symlink_and_owner(self):
        self.root.mkdir(parents=True, mode=0o755)
        self.root.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, 'Unsafe push launch directory'):
            self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
        self.root.chmod(0o700)
        with patch.object(os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaisesRegex(RuntimeError, 'Unsafe push launch directory'):
                self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
        self.root.rmdir()
        self.root.symlink_to(self.args.payload_file.parent, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'Unsafe push launch directory'):
            self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
        self.assertTrue(self.root.is_symlink())
        self.assertFalse(self.args.launch_receipt.exists())

    def test_preserves_pending_claim_and_receipt_files_and_dangling_symlinks(self):
        self.root.mkdir(parents=True, mode=0o700)
        for path in (self.root / 'push-launch.json', self.root / 'push-launch.consuming', self.args.launch_receipt):
            for symlink in (False, True):
                with self.subTest(path=path, symlink=symlink):
                    if symlink:
                        path.symlink_to(path.parent / 'absent')
                    else:
                        path.write_bytes(b'preserved\n')
                    with self.assertRaises((RuntimeError, FileExistsError)):
                        self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
                    if symlink:
                        self.assertEqual(path.readlink(), path.parent / 'absent')
                    else:
                        self.assertEqual(path.read_bytes(), b'preserved\n')
                    self.assertEqual(list(self.root.glob('.push-launch-*')), [])
                    self.assertEqual(list(self.root.iterdir()), [] if path == self.args.launch_receipt else [path])
                    self.assertEqual(self.args.launch_receipt.exists(), path == self.args.launch_receipt and not symlink)
                    path.unlink()

    def test_payload_object_and_5120_byte_limit_are_preserved(self):
        for payload in ('[]', '{', json.dumps({'x': 'x' * 5112})):
            with self.subTest(payload=payload[:20]):
                self.args.payload_file.write_text(payload)
                with self.assertRaises((RuntimeError, json.JSONDecodeError)):
                    self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
                self.assertFalse((self.root / 'push-launch.json').exists())
                self.assertFalse(self.args.launch_receipt.exists())
        self.args.payload_file.write_text(json.dumps({'x': 'x' * 5111}))
        self.args.must_report = 'false'
        self.stage(self.args, DEVICE, container=self.container, service_table=SERVICES)
        envelope = json.loads((self.root / 'push-launch.json').read_bytes())
        self.assertEqual(envelope['payload'], {'x': 'x' * 5111})
        self.assertIs(envelope['mustReport'], False)

    def test_cli_queries_then_executes_the_exact_returned_command_and_environment(self):
        argv, env = ['owned-console-launcher', 'synthetic'], {'SYNTHETIC': 'preserve-exactly'}
        stage = Mock(return_value=(argv, env))
        query = SimpleNamespace(returncode=0, stderr=b'', stdout=SERVICES)
        with patch.dict(self.stage.__globals__, simctl=Mock(return_value=str(self.container)), stage_push_launch=stage), \
             patch.object(CLI['subprocess'], 'run', return_value=query) as process, \
             patch.object(os, 'execvpe') as execute:
            CLI['launch_push'](self.args, DEVICE)
        stage.assert_called_once_with(self.args, DEVICE, container=self.container, service_table=SERVICES)
        self.assertEqual(process.call_args.args[0], ['xcrun', 'simctl', 'spawn', DEVICE, 'launchctl', 'list'])
        self.assertEqual(process.call_args.kwargs['env']['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], '')
        execute.assert_called_once_with(argv[0], argv, env)


if __name__ == '__main__':
    # Keep the inventory regression in this existing automatic CI entry point.
    from test_fixture_inventory import FixtureInventoryTests, PreinstallInventoryTests
    unittest.main()
