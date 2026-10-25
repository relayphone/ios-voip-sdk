"""Synthetic native receipts exercise the runner-owned startup seam; no simctl."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
RUNNER = runpy.run_path(str(ROOT / 'Tests/Inspector/run.py'))
SIMULATOR = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
NONCE = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
CONTAINER = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC'


class InspectorRunnerTests(unittest.TestCase):
    def setUp(self):
        RUNNER['_shipping_tools'].cache_clear()
        self.addCleanup(RUNNER['_shipping_tools'].cache_clear)
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name).resolve()
        self.container = self.root / SIMULATOR / 'data/Containers/Data/Application' / CONTAINER
        self.path = self.container / 'Documents/cksim-inspector-results.json'
        self.path.parent.mkdir(parents=True)
        self.channel = self.root / 'target/Documents/.callkit-simulator'
        (self.channel / 'run').mkdir(parents=True)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture', profile='ios-27.0')
        (self.channel / 'session.json').write_text(json.dumps(self.session))
        self.row = dict(self.session, sequence=1, event='runtime.installed', t_ms=1)
        (self.channel / 'run/events.jsonl').write_text(json.dumps(self.row) + '\n')
        self.value = dict(nonce=NONCE, inspectorPID=42, inspectorBundleID=RUNNER['INSPECTOR'],
                          inspectorDataContainer=str(self.container), startedWallTimeMS=1000000, wallTimeMS=1000000,
                          session=self.session, cursor=1, timeline=[self.row], online=True, error=None,
                          conversations=[], incoming=None)
        self.path.write_text(json.dumps(self.value))
        self.addCleanup(patch.stopall)
        patch('subprocess.Popen', side_effect=AssertionError('native services forbidden')).start()
        patch('subprocess.run', side_effect=AssertionError('native services forbidden')).start()

    def test_context_environment_single_launch_and_unchanged_host_bounds(self):
        start = RUNNER['launch_inspector']
        environment = dict(SIMCTL_CHILD_CKSIM_INSPECTOR_URL='http://private-endpoint', SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN='secret-token')
        connection = Mock(launch_environment=environment)
        connection.is_alive.return_value = True
        for shared, timeout in ((True, 20), (False, 180)):
            observed = []
            def supervise(command, **kwargs):
                self.assertEqual(command, ['xcrun', 'simctl', 'launch', '--terminate-running-process', SIMULATOR, RUNNER['INSPECTOR']])
                self.assertEqual(kwargs['host_timeout'], timeout)
                self.assertEqual(kwargs['consumer_timeout'], 25 if shared else None)
                self.assertEqual(kwargs['env']['SIMCTL_CHILD_CKSIM_INSPECTOR_PROBE_NONCE'], NONCE)
                self.assertEqual(kwargs['env']['SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN'], 'secret-token')
                self.assertNotIn('secret-token', repr(command))
                observed.append(kwargs['observe']())
                return observed[-1], 25 if shared else None
            with patch.dict(start.__globals__, locate_probe=Mock(return_value=self.path), supervise_launch=supervise):
                with patch.object(start.__globals__['time'], 'time', return_value=1000), patch.object(start.__globals__['time'], 'monotonic', return_value=0):
                    probe, deadline = start(connection, SIMULATOR, NONCE, self.session, self.channel, self.root, shared)
            self.assertEqual(probe.pid, 42)
            self.assertEqual(deadline, 25 if shared else None)
            self.assertEqual(len(observed), 1)

    def test_strict_native_identity_and_original_projection_are_required(self):
        start = RUNNER['launch_inspector']
        connection = Mock(launch_environment={})
        def supervise(command, **kwargs):
            return kwargs['observe'](), 25
        for changes in (dict(inspectorBundleID='foreign.bundle'), dict(inspectorDataContainer='/foreign'),
                        dict(timeline=[dict(self.row, event='invented')])):
            with self.subTest(changes=changes):
                self.path.write_text(json.dumps(dict(self.value, **changes)))
                with patch.dict(start.__globals__, locate_probe=Mock(return_value=self.path), supervise_launch=supervise):
                    with patch.object(start.__globals__['time'], 'time', return_value=1000):
                        with self.assertRaises((RuntimeError, AssertionError)):
                            start(connection, SIMULATOR, NONCE, self.session, self.channel, self.root, True)

    def test_native_entry_owns_install_and_context_lifetime_without_cli_lifecycle(self):
        events = []
        session = dict(self.session, controlTransport='directory-watch-v1')
        connection = Mock(session=session, target_container=self.channel.parent.parent)
        @contextmanager
        def factory(args, target):
            self.assertEqual(args.timeout, 15)
            self.assertEqual(args.app_container, self.channel.parent.parent)
            self.assertEqual(target, SIMULATOR)
            events.append('open')
            try:
                yield connection
            finally:
                events.append('close')
        def transport(*args, **kwargs):
            if args[:4] == ('xcrun', 'simctl', 'list', 'runtimes'):
                return json.dumps(dict(runtimes=[dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True)]))
            self.assertEqual(args[:4], ('xcrun', 'simctl', 'install', SIMULATOR))
            self.assertEqual(kwargs['timeout'], 60)
            events.append('install')
            return ''
        def launch(*args):
            self.assertEqual(loader.call_count, 1, 'shipping code must load before the shared launch budget')
            self.assertTrue(args[-1])
            events.append('launch')
            return Mock(), 25
        def journey(*args, **kwargs):
            events.append('journey')
            self.assertNotIn('close', events)
            return dict(success=True)
        argv = ['run.py', '--package', str(self.root), '--fixture', str(self.root), '--inspector', str(self.root),
                '--out', str(self.root / 'out'), '--driver', 'journal', '--target-simulator', SIMULATOR, '--fixture-installed']
        main = RUNNER['main']
        loader = Mock(return_value={'inspector_bridge': factory})
        with patch.object(main.__globals__['sys'], 'argv', argv), patch.object(runpy, 'run_path', loader):
            with patch.dict(main.__globals__, run=transport, record_environment=Mock(), capture_diagnostics=Mock(),
                            remove_simulators=Mock(), launch_fixture=Mock(return_value=(self.channel, 'run')),
                            fixture_session=Mock(return_value=session), launch_inspector=launch, journal_journey=journey):
                main()
        self.assertEqual(events, ['open', 'install', 'launch', 'journey', 'close'])

    def test_install_or_body_failure_closes_bridge_and_attempts_all_cleanup(self):
        main = RUNNER['main']
        for failed_stage in ('install', 'journey'):
            with self.subTest(stage=failed_stage):
                RUNNER['_shipping_tools'].cache_clear()
                events = []
                primary = RuntimeError('primary ' + failed_stage)
                session = dict(self.session, controlTransport='directory-watch-v1')
                connection = Mock(session=session, target_container=self.channel.parent.parent)
                @contextmanager
                def factory(args, target):
                    events.append('open')
                    try:
                        yield connection
                    finally:
                        events.append('close')
                        raise OSError('secondary bridge cleanup')
                def transport(*args, **kwargs):
                    if args[:4] == ('xcrun', 'simctl', 'list', 'runtimes'):
                        return json.dumps(dict(runtimes=[dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True)]))
                    self.assertEqual(args[:4], ('xcrun', 'simctl', 'install', SIMULATOR))
                    self.assertEqual(kwargs['timeout'], 60)
                    events.append('install')
                    if failed_stage == 'install':
                        raise primary
                    return ''
                def journey(*args, **kwargs):
                    events.append('journey')
                    raise primary
                def diagnostics(*args, **kwargs):
                    events.append('diagnostics')
                    raise OSError('secondary evidence cleanup')
                argv = ['run.py', '--package', str(self.root), '--fixture', str(self.root), '--inspector', str(self.root),
                        '--out', str(self.root / ('failed-' + failed_stage)), '--driver', 'journal',
                        '--target-simulator', SIMULATOR, '--fixture-installed']
                with patch.object(main.__globals__['sys'], 'argv', argv), patch.object(runpy, 'run_path', return_value={'inspector_bridge': factory}):
                    with patch.dict(main.__globals__, run=transport, record_environment=Mock(), capture_diagnostics=diagnostics,
                                    remove_simulators=lambda owned: events.append('remove'),
                                    launch_fixture=Mock(return_value=(self.channel, 'run')), fixture_session=Mock(return_value=session),
                                    launch_inspector=Mock(return_value=(Mock(), 25)), journal_journey=journey):
                        with self.assertRaises(RuntimeError) as caught:
                            main()
                self.assertIs(caught.exception, primary)
                self.assertEqual(events[-4:], ['diagnostics', 'diagnostics', 'close', 'remove'])
                self.assertEqual(events.count('open'), 1)
                self.assertEqual(events.count('install'), 1)

    def test_target_identity_change_refuses_install_and_closes_context(self):
        main = RUNNER['main']
        events = []
        session = dict(self.session, controlTransport='directory-watch-v1')
        connection = Mock(session=dict(session, pid=999), target_container=self.channel.parent.parent)
        @contextmanager
        def factory(args, target):
            events.append('open')
            try:
                yield connection
            finally:
                events.append('close')
        def transport(*args, **kwargs):
            if args[:4] == ('xcrun', 'simctl', 'list', 'runtimes'):
                return json.dumps(dict(runtimes=[dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True)]))
            raise AssertionError('foreign bridge identity must not install or launch')
        argv = ['run.py', '--package', str(self.root), '--fixture', str(self.root), '--inspector', str(self.root),
                '--out', str(self.root / 'foreign'), '--driver', 'journal', '--target-simulator', SIMULATOR, '--fixture-installed']
        with patch.object(main.__globals__['sys'], 'argv', argv), patch.object(runpy, 'run_path', return_value={'inspector_bridge': factory}):
            with patch.dict(main.__globals__, run=transport, record_environment=Mock(), capture_diagnostics=Mock(),
                            remove_simulators=lambda owned: events.append('remove'),
                            launch_fixture=Mock(return_value=(self.channel, 'run')), fixture_session=Mock(return_value=session)):
                with self.assertRaisesRegex(RuntimeError, 'bridge target changed'):
                    main()
        self.assertEqual(events, ['open', 'close', 'remove'])

    def test_xctest_keeps_the_original_separate_display_requirement(self):
        session = dict(self.session, controlTransport='directory-watch-v1')
        connection = Mock(session=session, target_container=self.channel.parent.parent)
        closed = []
        @contextmanager
        def factory(args, target):
            try:
                yield connection
            finally:
                closed.append(True)
        def transport(*args, **kwargs):
            if args[:4] == ('xcrun', 'simctl', 'list', 'runtimes'):
                return json.dumps(dict(runtimes=[dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True)]))
            raise AssertionError('Invalid shared xctest display must not be installed or launched')
        main = RUNNER['main']
        aliases = (SIMULATOR, SIMULATOR.lower(), SIMULATOR.replace('-', ''))
        for index, display in enumerate(aliases):
            argv = ['run.py', '--package', str(self.root), '--fixture', str(self.root), '--inspector', str(self.root),
                    '--out', str(self.root / ('out-' + str(index))), '--driver', 'xctest', '--target-simulator', SIMULATOR,
                    '--display-simulator', display, '--fixture-installed']
            with self.subTest(display=display), patch.object(main.__globals__['sys'], 'argv', argv), patch.object(runpy, 'run_path', return_value={'inspector_bridge': factory}):
                with patch.dict(main.__globals__, run=transport, record_environment=Mock(), capture_diagnostics=Mock(),
                                remove_simulators=Mock(), launch_fixture=Mock(return_value=(self.channel, 'run')),
                                fixture_session=Mock(return_value=session)):
                    with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess(['xcodebuild'], 0)):
                        with self.assertRaisesRegex(RuntimeError, 'separate inspector simulator'):
                            main()
        self.assertEqual(closed, [True] * len(aliases))



if __name__ == '__main__':
    unittest.main()
