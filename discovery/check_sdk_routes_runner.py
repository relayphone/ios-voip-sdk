#!/usr/bin/env python3
"""Host-only route-runner wiring controls; never simulator acceptance."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_sdk_routes as runner
from sim import Result
from summarize import EvidenceError

FIRST = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
REPLACEMENT = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
EXTERNAL = '/external/Library With Spaces.dylib:/other/libArgent.dylib'
JOURNAL = b'{"fixture":"host-only route runner journal"}\n'


def runtime(version='27.1', **updates):
    value = dict(identifier='runtime-' + version, version=version,
                 buildversion='host-only-build', platform='iOS', isAvailable=True)
    value.update(updates)
    return value


class Fixture:
    def __init__(self, root, *, replace=False, runtimes=None, devices=None, status=0,
                 cancel=False, cleanup_status=0, native_os='27.1', locate_error=False, receipt_meta=None):
        self.root, self.replace, self.status = root, replace, status
        self.runtimes = [runtime()] if runtimes is None else runtimes
        self.devices = [dict(identifier=runner.DEVICE)] if devices is None else devices
        self.cancel, self.cleanup_status, self.native_os = cancel, cleanup_status, native_os
        self.locate_error = locate_error
        self.receipt_meta = receipt_meta or {}
        self.launch_result = None
        self.events, self.launches, self.locates, self.sessions = [], [], [], []
        self.build, self.out = root / 'build', root / 'out'
        self.build.mkdir()

    def session_factory(self, path, *, runner: object, recovery_timeout):
        fixture = self
        fixture.sessions.append((path, recovery_timeout))

        class FakeSession:
            current = None

            def call(self, command, timeout):
                fixture.events.append(('call', command, timeout))
                if command[:2] != ['xcrun', 'simctl']:
                    raise AssertionError('unexpected simulator command')
                operation = command[2]
                if operation == 'list':
                    key = command[3]
                    rows = fixture.runtimes if key == 'runtimes' else fixture.devices
                    return Result(command, 0, json.dumps({key: rows}).encode())
                if operation == 'create':
                    self.current = FIRST
                elif operation == 'boot':
                    assert command[3] == FIRST
                    if fixture.replace:
                        self.current = REPLACEMENT
                elif operation == 'launch':
                    fixture.launch_result = runner(command, timeout)
                    return fixture.launch_result
                else:
                    assert command[3] == self.current, 'stale simulator after preparation replacement'
                return Result(command, 0)

            def checkpoint(self):
                fixture.events.append(('checkpoint', self.current))

            def cleanup(self, timeout):
                fixture.events.append(('cleanup', self.current, timeout))
                return Result([], fixture.cleanup_status)

        return FakeSession()

    def supervisor(self, command, terminate, trace, receipt, timeout, identity, **options):
        self.events.append(('supervise',))
        self.launches.append(dict(command=command, terminate=terminate, trace=trace,
            receipt=receipt, timeout=timeout, identity=identity, options=options, env=dict(os.environ)))
        if self.cancel:
            raise KeyboardInterrupt('host-only cancellation')
        trace.write_text('host-only supervisor output\n')
        receipt.write_text(json.dumps(dict(fixture='host-only route-runner receipt', **self.receipt_meta)))
        return self.status

    def locate(self, receipt, trace, simulator, run_id, bundle):
        self.locates.append((receipt, trace, simulator, run_id, bundle))
        if self.locate_error:
            raise EvidenceError('host-only rejected container')
        container = self.root / 'canonical-container-fixture'
        journal = container / 'Documents/.callkit-simulator' / run_id / 'events.jsonl'
        journal.parent.mkdir(parents=True)
        journal.write_bytes(JOURNAL)
        return container

    def capture(self):
        with patch.object(runner, 'validate_build') as build_check, \
                patch.object(runner, 'validate', return_value=dict(success=True, simulatorOS=self.native_os)) as validate, \
                patch.object(runner, 'bounded', side_effect=AssertionError('unexpected native execution')):
            result = runner.capture(self.build, self.out, self.session_factory, self.supervisor, self.locate)
            build_check.assert_called_once_with(self.build)
            validate.assert_called_once_with(self.build, self.out, cases=('audio-routes',))
            return result


class RouteRunnerControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sdk-route-runner-host-')
        self.root = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, dict(
            SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=EXTERNAL,
            SIMCTL_CHILD_SDK_M3_CASE='foreign-case', SIMCTL_CHILD_SDK_M2_RUN_ID='foreign-run',
            SIMCTL_CHILD_CKSIM_PROFILE='foreign-profile', SIMCTL_CHILD_OTHER='keep-me'))
        self.environment.start()
        self.before = dict(os.environ)

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def assert_cleanup(self, fixture):
        self.assertEqual([e[0] for e in fixture.events].count('cleanup'), 1)
        self.assertEqual(fixture.events[-1][0], 'cleanup')
        self.assertEqual(fixture.events[-1][-1], 60)
        self.assertEqual(dict(os.environ), self.before)

    def test_shared_session_tracks_replacement_and_sole_bound_console_launch(self):
        fixture = Fixture(self.root, replace=True)
        result = fixture.capture()
        self.assertEqual(fixture.sessions, [(fixture.out / 'simulator-state.json', 60)])
        calls = [e for e in fixture.events if e[0] == 'call']
        self.assertEqual([(e[1][2], e[2]) for e in calls], [
            ('list', 180), ('list', 60), ('create', 30), ('boot', 60),
            ('bootstatus', 300), ('install', 180), ('launch', 90)])
        self.assertEqual(calls[2][1][4:], [runner.DEVICE, 'runtime-27.1'])
        self.assertEqual([e[0] for e in fixture.events][-4:],
                         ['checkpoint', 'call', 'supervise', 'cleanup'])
        self.assertEqual(len(fixture.launches), 1)
        launch = fixture.launches[0]
        self.assertEqual(launch['command'], ['xcrun', 'simctl', 'launch', '--console',
            '--terminate-running-process', REPLACEMENT, runner.BUNDLE])
        self.assertEqual(launch['terminate'][1:], [str(runner.ROOT / 'scripts/sim/sim.py'),
            'call', str(fixture.out / 'simulator-state.json'), '5',
            'xcrun', 'simctl', 'terminate', REPLACEMENT, runner.BUNDLE])
        self.assertEqual(launch['timeout'], 90)
        self.assertEqual(launch['options'], dict(console_launcher_stop=True, startup_timeout=180))
        identity = launch['identity']
        self.assertEqual(identity['simulatorID'], REPLACEMENT)
        self.assertEqual(identity['bundleID'], runner.BUNDLE)
        self.assertEqual(identity['scenario'], runner.NAME)
        child = launch['env']
        self.assertEqual(child['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], EXTERNAL)
        self.assertEqual(child['SIMCTL_CHILD_OTHER'], 'keep-me')
        self.assertEqual(child['SIMCTL_CHILD_CKSIM_RUN_ID'], identity['runID'])
        self.assertEqual(child['SIMCTL_CHILD_SDK_M1_CONTRACT_CASE'], 'audio-routes')
        for key in ('SIMCTL_CHILD_SDK_M3_CASE', 'SIMCTL_CHILD_SDK_M2_RUN_ID', 'SIMCTL_CHILD_CKSIM_PROFILE'):
            self.assertNotIn(key, child)
        self.assertEqual(fixture.locates, [(launch['receipt'], launch['trace'], REPLACEMENT,
            identity['runID'], runner.BUNDLE)])
        self.assertEqual((fixture.out / (runner.NAME + '.runtime.jsonl')).read_bytes(), JOURNAL)
        receipt = json.loads(launch['receipt'].read_text())
        self.assertEqual(receipt['journalSHA256'], hashlib.sha256(JOURNAL).hexdigest())
        self.assertEqual(result['deviceType'], runner.DEVICE)
        self.assertEqual(result['runtime']['identifier'], 'runtime-27.1')
        self.assertEqual(json.loads((fixture.out / 'summary.json').read_text()), result)
        self.assert_cleanup(fixture)

    def test_old_or_unavailable_runtime_refuses_without_creating_a_substitute(self):
        fixture = Fixture(self.root, runtimes=[runtime('27.0'), runtime('27.1', isAvailable=False)])
        with self.assertRaisesRegex(EvidenceError, '27.1'):
            fixture.capture()
        self.assertEqual([e[1][2] for e in fixture.events if e[0] == 'call'], ['list'])
        self.assertFalse(fixture.launches)
        self.assert_cleanup(fixture)

    def test_missing_duo_refuses_instead_of_using_another_device(self):
        fixture = Fixture(self.root, devices=[dict(identifier='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')])
        with self.assertRaisesRegex(EvidenceError, 'Duo'):
            fixture.capture()
        self.assertFalse(any(e[0] == 'call' and e[1][2] == 'create' for e in fixture.events))
        self.assert_cleanup(fixture)

    def test_launch_failure_cleans_up_without_retry_or_journal_lookup(self):
        fixture = Fixture(self.root, status=1)
        with self.assertRaisesRegex(EvidenceError, 'launch'):
            fixture.capture()
        self.assertEqual(len(fixture.launches), 1)
        self.assertFalse(fixture.locates)
        self.assert_cleanup(fixture)

    def test_timeout_classification_survives_session_without_retry(self):
        for reason, label in (('startup', 'infra:startup'), ('capture', 'timeout:capture')):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory(dir=self.root) as temporary:
                fixture = Fixture(Path(temporary), status=1, receipt_meta=dict(
                    timeoutReason=reason, failureClass=label, failureReported=True))
                with self.assertRaisesRegex(EvidenceError, 'launch'):
                    fixture.capture()
                self.assertTrue(fixture.launch_result.failure_classified)
                self.assertEqual(len(fixture.launches), 1)
                self.assertFalse(fixture.locates)
                self.assert_cleanup(fixture)

    def test_malformed_timeout_reason_cannot_mask_the_launch_failure(self):
        fixture = Fixture(self.root, status=1, receipt_meta=dict(
            timeoutReason=['startup'], failureClass='infra:startup', failureReported=True))
        with self.assertRaisesRegex(EvidenceError, 'launch'):
            fixture.capture()
        self.assertFalse(fixture.launch_result.failure_classified)
        self.assert_cleanup(fixture)

    def test_cancellation_restores_environment_and_cleans_owned_device(self):
        fixture = Fixture(self.root, cancel=True)
        with self.assertRaisesRegex(KeyboardInterrupt, 'host-only cancellation'):
            fixture.capture()
        self.assertEqual(len(fixture.launches), 1)
        self.assert_cleanup(fixture)

    def test_rejected_container_and_native_os_fail_before_success_summary(self):
        for options, message in ((dict(locate_error=True), 'rejected container'),
                                 (dict(native_os='27.0'), '27.1')):
            with self.subTest(options=options), tempfile.TemporaryDirectory(dir=self.root) as temporary:
                fixture = Fixture(Path(temporary), **options)
                with self.assertRaisesRegex(EvidenceError, message):
                    fixture.capture()
                self.assertFalse((fixture.out / 'summary.json').exists())
                self.assert_cleanup(fixture)

    def test_cleanup_failure_cannot_turn_success_into_accepted_capture(self):
        fixture = Fixture(self.root, cleanup_status=1)
        with self.assertRaisesRegex(EvidenceError, 'cleanup failed'):
            fixture.capture()
        self.assertFalse((fixture.out / 'summary.json').exists())
        self.assert_cleanup(fixture)

    def test_cleanup_failure_preserves_original_launch_failure(self):
        fixture = Fixture(self.root, status=1, cleanup_status=1)
        with self.assertRaisesRegex(EvidenceError, 'helper failed: launch'):
            fixture.capture()
        self.assert_cleanup(fixture)

    def test_unsafe_or_unspecified_inherited_environment_refuses_before_session_creation(self):
        for value in (None, '/tmp/CKSimRuntime.dylib', '/tmp/CKSimLoader.dylib'):
            with self.subTest(value=value), tempfile.TemporaryDirectory(dir=self.root) as temporary:
                fixture = Fixture(Path(temporary))
                if value is None:
                    os.environ.pop('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES')
                else:
                    os.environ['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] = value
                with self.assertRaises(EvidenceError):
                    fixture.capture()
                self.assertFalse(fixture.sessions)
                self.assertFalse(fixture.out.exists())
        os.environ.clear()
        os.environ.update(self.before)

    def test_runtime_selection_uses_latest_available_ios_at_or_above_duo_minimum(self):
        selected = runner.select_runtime(dict(runtimes=[runtime('27.0'), runtime('27.1'),
            runtime('28.0', isAvailable=False), runtime('27.2'), runtime('99.0', platform='tvOS')]))
        self.assertEqual(selected['version'], '27.2')


if __name__ == '__main__':
    unittest.main()
