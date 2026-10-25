#!/usr/bin/env python3
"""Fake-host controls for Swift LiveKit setup; no product qualification."""
from collections import Counter
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

import sim as infrastructure

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_swift_livekit as runner


UNSET = object()
IDENTITY = dict(sourceCommit='host-only', sourceInputsSHA256='0' * 64,
                sourceDirty=False, fixtureInputs={})


class NativeService:
    """Track owned devices and permissions independently from helper state."""
    def __init__(self, rules=(), trace_paths=False):
        self.rules, self.trace_paths = rules, trace_paths
        self.counts, self.devices, self.created, self.calls = Counter(), {}, [], []

    @staticmethod
    def environment(device):
        return '/private/host-' + device.casefold() + '.dylib'

    def __call__(self, arguments, timeout, *, env=None):
        arguments = list(map(str, arguments))
        if arguments[:2] != ['xcrun', 'simctl']:
            raise AssertionError('unexpected native command: ' + repr(arguments))
        step = arguments[2]
        self.counts[step] += 1
        self.calls.append(dict(arguments=arguments, timeout=timeout, env=env,
            handlers={sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}))
        rule = next((rule for rule in self.rules if rule['step'] == step and
                     self.counts[step] in rule.get('at', [1])), {})
        code, output, error = rule.get('code', 0), b'', b''
        timed_out = rule.get('timeout', False)
        if step == 'list':
            if arguments[3] == 'runtimes':
                output = json.dumps(dict(runtimes=[dict(platform='iOS', isAvailable=True, version='27.0',
                    identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', buildversion='host-only')])).encode()
            elif arguments[3] == 'devices':
                output = json.dumps(dict(devices={'host-runtime': [dict(udid=device, name=value['name'])
                    for device, value in self.devices.items()]})).encode()
            else:
                raise AssertionError('unsupported inventory')
        elif step == 'create':
            device = str(uuid.UUID('ABCDEF00-1234-4ABC-8123-' + f'{len(self.created)+1:012d}'))
            self.created.append(device)
            self.devices[device] = dict(name=arguments[3], installed=False, grants=set())
            output = (device + '\n').encode()
        elif step == 'spawn':
            if arguments[4:] != ['launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES']:
                raise AssertionError('unexpected simulator spawn')
            if env is None or env.get('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES') != '':
                raise AssertionError('query did not preserve its empty child-library override')
            output = rule.get('stdout', (self.environment(arguments[3]) + '\n').encode())
            error = rule.get('stderr', b'')
        elif step == 'get_app_container':
            raise AssertionError('prelaunch container RPC must not return')
        elif step in ('boot', 'bootstatus', 'install', 'privacy', 'shutdown', 'delete'):
            device = arguments[3].casefold()
            if device not in self.devices:
                raise AssertionError('operation targeted an unknown device: ' + device)
            if step == 'install' and (code == 0 or timed_out):
                self.devices[device]['installed'] = True
            if step == 'privacy' and (code == 0 or timed_out):
                self.devices[device]['grants'].add(tuple(arguments[4:]))
            if self.trace_paths:
                error = ('native-loader ' + self.environment(device) + '\n').encode()
            if step == 'delete' and code == 0 and not rule.get('retain'):
                del self.devices[device]
        else:
            raise AssertionError('unexpected native operation: ' + step)
        if env is not None and step != 'spawn':
            raise AssertionError('unexpected per-command environment override')
        if 'stdout' in rule:
            output = rule['stdout']
        if 'stderr' in rule:
            error = rule['stderr']
        return infrastructure.Result(arguments, 124 if timed_out else code, output, error, timed_out)


class SwiftLiveKitSetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='swift-livekit-setup-host-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.build = self.root / 'build'
        (self.build / 'SDKSwiftLiveKit.app').mkdir(parents=True)
        (self.build / 'SDKSwiftLiveKit.app/SDKSwiftLiveKit').write_bytes(b'host-only executable fixture')
        (self.build / 'build-info.json').write_text('{}')
        self.container = self.root / 'container'; self.container.mkdir()
        self.out = self.root / 'capture'
        self.case_calls = []

    def capture(self, native, override=UNSET, case_failure=False, *, classify=True,
                validation_failure=None, child_failure_label=None, extra_environment=None,
                case_executor=None, native_popen=None):
        environment = dict(HOST_ONLY='unchanged', SIM_STATE=str(self.root / 'outer-state'),
                           GITHUB_STEP_SUMMARY=str(self.root / 'job-summary.md'))
        environment.update(extra_environment or {})
        if override is not UNSET:
            environment['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] = override

        def case(build, out, simulator, inherited, mode, expected_container):
            state_path = Path(runner.os.environ['SIM_STATE'])
            state = json.loads(state_path.read_text())
            self.case_calls.append(dict(simulator=simulator, inherited=inherited, mode=mode,
                marker=runner.os.environ.get('SIM_FAILURE_MARKER'),
                expected_container=expected_container, state=state,
                permissions=set(native.devices[simulator.casefold()]['grants'])))
            if child_failure_label:
                infrastructure.summary(child_failure_label, 'not eligible')
                Path(runner.os.environ['SIM_FAILURE_MARKER']).touch()
            if case_failure:
                raise case_failure if isinstance(case_failure, BaseException) else RuntimeError('host-only product checkpoint failure')
            trace = out / (mode + '.log')
            trace.write_text(inherited + '\n')
            (out / (mode + '.receipt.json')).write_text(json.dumps(dict(
                traceSHA256=hashlib.sha256(trace.read_bytes()).hexdigest())))
            return dict(runID=str(uuid.uuid4()), pid=100+len(self.case_calls),
                        supervisorPID=200+len(self.case_calls), dataContainer=str(self.container))

        caught = None
        with patch.object(runner, 'simulator_infra', infrastructure, create=True), \
             patch.object(infrastructure, 'bounded', side_effect=native), \
             patch.object(runner.subprocess, 'run', side_effect=AssertionError('unbounded/legacy native transport')), \
             patch.object(runner.subprocess, 'Popen', side_effect=native_popen or AssertionError('unmocked native process creation')), \
             patch.object(runner, 'validate_build'), patch.object(runner, 'source', return_value=IDENTITY), \
             patch.object(runner, 'validate', return_value=dict(success=True), side_effect=validation_failure), \
             patch.object(runner, 'capture_case', side_effect=case_executor or case), \
             patch.dict(runner.os.environ, environment, clear=True), redirect_stdout(io.StringIO()):
            try:
                runner.capture(self.build, self.out, classify=classify)
            except BaseException as error:
                caught = error
            self.assertEqual(dict(runner.os.environ), environment, 'runner leaked child session context')
        return caught

    def manifest(self):
        return json.loads((self.out / 'manifest.json').read_text())

    def failure_labels(self):
        summary = self.root / 'job-summary.md'
        return re.findall(r'`((?:infra|product):[^`]+)`', summary.read_text()) if summary.exists() else []

    def assert_manifest_bound(self):
        manifest = self.manifest()
        expected = {str(path.relative_to(self.out)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.out.rglob('*') if path.is_file() and path.name not in ('manifest.json', 'summary.json')}
        self.assertEqual(manifest['files'], expected)

    def assert_final_identity(self, native):
        final = native.created[-1].upper()
        self.assertEqual(self.manifest()['simulatorID'], final)
        self.assertEqual((self.out / 'create.stdout').read_text().strip().upper(), final)
        for label in ('create', 'boot', 'bootstatus', 'install', 'microphone', 'delete', 'devices-after'):
            self.assertEqual(json.loads((self.out / (label + '.status.json')).read_text())['exitCode'], 0, label)
        self.assertTrue(all(case['simulator'] == final for case in self.case_calls))
        self.assertEqual(native.devices, {})
        self.assert_manifest_bound()

    def assert_bounds(self, native):
        bounds = dict(create=30, boot=60, bootstatus=300, install=180, privacy=60,
                      shutdown=60, delete=60, list=60, spawn=180)
        for call in native.calls:
            self.assertEqual(call['timeout'], bounds[call['arguments'][2]], call)
        self.assertEqual([call['arguments'][2] for call in native.calls[-3:]], ['shutdown', 'delete', 'list'])
        for call in native.calls[-3:]:
            self.assertTrue(all(handler == signal.SIG_IGN for handler in call['handlers'].values()))

    def test_install_replacement_has_final_canonical_identity_and_bound_attempt_archive(self):
        native = NativeService([dict(step='install', code=73)], trace_paths=True)
        self.assertIsNone(self.capture(native))
        self.assertEqual(len(native.created), 2)
        self.assert_final_identity(native)
        archived = list((self.out / 'infrastructure-attempts').rglob('create.stdout'))
        self.assertTrue(archived)
        self.assertIn(native.created[0], '\n'.join(path.read_text() for path in archived))
        failed = [json.loads(path.read_text()) for path in
                  (self.out / 'infrastructure-attempts').rglob('install.status.json')]
        self.assertTrue(any(status['exitCode'] == 73 for status in failed))
        self.assert_bounds(native)

    def test_create_recovery_preserves_failed_create_and_canonical_final_identity(self):
        native = NativeService([dict(step='create', code=73)])
        self.assertIsNone(self.capture(native, override=''))
        self.assertEqual(len(native.created), 2)
        self.assert_final_identity(native)
        archived = list((self.out / 'infrastructure-attempts').rglob('create.status.json'))
        self.assertTrue(any(json.loads(path.read_text())['exitCode'] == 73 for path in archived))
        self.assert_bounds(native)

    def test_privacy_replacement_replays_install_and_uses_same_final_device(self):
        native = NativeService([dict(step='privacy', code=73)])
        self.assertIsNone(self.capture(native))
        self.assertEqual(len(native.created), 2)
        self.assertEqual(native.counts['install'], 2)
        self.assertEqual(native.counts['privacy'], 2)
        self.assertTrue(all(case['permissions'] == {('grant', 'microphone', runner.BUNDLE)} for case in self.case_calls))
        self.assert_final_identity(native)
        self.assert_bounds(native)

    def test_privacy_timeout_replaces_device_replays_preparation_and_preserves_failed_bytes(self):
        stdout, stderr = b'partial grant\x00\xff\n', b'privacy transport deadline\x00\xfe\n'
        native = NativeService([dict(step='privacy', timeout=True, stdout=stdout, stderr=stderr)])
        self.assertIsNone(self.capture(native, override=''))
        first, final = native.created
        self.assertNotEqual(first, final)
        self.assertEqual([call['arguments'][2] for call in native.calls],
            ['list', 'create', 'boot', 'bootstatus', 'install', 'privacy', 'shutdown', 'delete',
             'create', 'boot', 'bootstatus', 'install', 'privacy', 'shutdown', 'delete', 'list'])
        for step in ('boot', 'bootstatus', 'install', 'privacy'):
            self.assertEqual([call['arguments'][3].casefold() for call in native.calls
                              if call['arguments'][2] == step], [first, final], step)
        self.assertTrue(all(case['permissions'] == {('grant', 'microphone', runner.BUNDLE)}
                            for case in self.case_calls))
        self.assertTrue(all(case['state']['checkpoint'] and case['state']['retry_used']
                            for case in self.case_calls))
        archives = list((self.out / 'infrastructure-attempts').glob('*-microphone'))
        self.assertEqual(len(archives), 1)
        self.assertEqual((archives[0] / 'microphone.stdout').read_bytes(), stdout)
        self.assertEqual((archives[0] / 'microphone.stderr').read_bytes(), stderr)
        failed = json.loads((archives[0] / 'microphone.status.json').read_text())
        self.assertIsNone(failed['exitCode'])
        self.assertIn('60', failed['error'])
        self.assertEqual((self.out / 'microphone.stdout').read_bytes(), b'')
        self.assertEqual((self.out / 'microphone.stderr').read_bytes(), b'')
        self.assertEqual(self.failure_labels(), ['infra:privacy', 'infra:privacy'])
        self.assertIn('recovered', (self.root / 'job-summary.md').read_text())
        self.assert_final_identity(native)
        self.assert_bounds(native)

    def test_second_privacy_timeout_is_final_infrastructure_failure_without_capture(self):
        native = NativeService([dict(step='privacy', at=[1, 2], timeout=True)])
        self.assertIsNotNone(self.capture(native, override=''))
        self.assertEqual(len(native.created), 2)
        for step in ('boot', 'bootstatus', 'install', 'privacy', 'shutdown', 'delete'):
            self.assertEqual(native.counts[step], 2, step)
        self.assertFalse(self.case_calls)
        self.assertEqual(native.devices, {})
        self.assertEqual(self.failure_labels(), ['infra:privacy', 'infra:privacy'])
        self.assertIn('exhausted', (self.root / 'job-summary.md').read_text())
        self.assertTrue(Path(str(self.out) + '.failure-classified').exists())
        self.assertFalse((self.out / 'manifest.json').exists())
        self.assertFalse((self.out / 'summary.json').exists())
        state = json.loads((self.out / 'simulator-state/owner.json').read_text())
        self.assertTrue(state['retry_used'])
        self.assertFalse(state['checkpoint'])
        self.assert_bounds(native)

    def test_lifecycle_timeout_budget_makes_privacy_timeout_terminal(self):
        for step in ('create', 'boot', 'bootstatus', 'install'):
            with self.subTest(prior_recovery=step):
                self.out = self.root / ('budget-' + step)
                self.case_calls.clear()
                (self.root / 'job-summary.md').unlink(missing_ok=True)
                native = NativeService([dict(step=step, timeout=True), dict(step='privacy', timeout=True)])
                self.assertIsNotNone(self.capture(native, override=''))
                self.assertEqual(len(native.created), 2)
                self.assertEqual(native.counts[step], 2)
                self.assertEqual(native.counts['privacy'], 1)
                self.assertFalse(self.case_calls)
                self.assertEqual(native.devices, {})
                self.assertEqual(self.failure_labels(), ['infra:' + step, 'infra:' + step, 'infra:privacy'])
                self.assertIn('`infra:privacy`: exhausted', (self.root / 'job-summary.md').read_text())
                self.assertFalse((self.out / 'manifest.json').exists())
                self.assertFalse((self.out / 'summary.json').exists())
                self.assert_bounds(native)

    def test_install_used_budget_makes_next_privacy_failure_final_without_case_retry(self):
        native = NativeService([dict(step='install', code=73), dict(step='privacy', code=73)])
        self.assertIsNotNone(self.capture(native))
        self.assertEqual(len(native.created), 2)
        self.assertEqual(native.counts['privacy'], 1)
        self.assertFalse(self.case_calls)
        self.assertEqual(native.devices, {})
        summary = (self.root / 'job-summary.md').read_text()
        self.assertIn('infra:privacy', summary); self.assertIn('exhausted', summary)

    def test_product_case_failure_is_not_replayed_as_setup_recovery(self):
        native = NativeService()
        error = self.capture(native, override='', case_failure=True)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(len(self.case_calls), 1)
        self.assertEqual(len(native.created), 1)
        self.assertEqual(native.counts['install'], 1)
        self.assertEqual(native.counts['privacy'], 1)
        self.assertEqual(native.devices, {})
        self.assertFalse((self.out / 'manifest.json').exists())
        self.assert_bounds(native)

    def test_replacement_refreshes_and_recursively_redacts_both_environment_sources(self):
        native = NativeService([dict(step='privacy', code=73)], trace_paths=True)
        self.assertIsNone(self.capture(native))
        queries = [call for call in native.calls if call['arguments'][2] == 'spawn']
        self.assertEqual([call['arguments'][3].casefold() for call in queries], native.created)
        expected = native.environment(native.created[-1])
        self.assertTrue(all(case['inherited'] == expected for case in self.case_calls))
        inherited = json.loads((self.out / 'inherited-dyld.json').read_text())
        self.assertEqual(inherited, dict(present=True, sha256=hashlib.sha256(expected.encode()).hexdigest()))
        for path in self.out.rglob('*'):
            if path.is_file() and path.suffix in ('.log', '.stdout', '.stderr'):
                self.assertNotIn(b'/private/host-', path.read_bytes(), str(path))
        self.assertTrue(all(path.read_bytes() == b'' for path in self.out.rglob('launch-environment.stdout')))
        self.assert_manifest_bound()

    def test_replacement_sdk_injection_refuses_before_launch(self):
        native = NativeService([dict(step='install', code=73),
            dict(step='spawn', at=[2], stdout=b'/private/CKSimLoader.dylib\n')])
        self.assertIsNotNone(self.capture(native))
        self.assertFalse(self.case_calls)
        self.assertEqual(native.devices, {})
        self.assertEqual(native.counts['spawn'], 2)

    def test_initial_query_refusal_still_precedes_install_and_grant(self):
        for name, rule in (('status', dict(code=2, stdout=b'')),
                           ('stderr', dict(stderr=b'unknown RPC result')),
                           ('unset-value', dict(code=1, stdout=b'/private/unexpected.dylib'))):
            with self.subTest(name=name):
                # Give each refusal its own output and native owner.
                self.out = self.root / ('capture-' + name)
                native = NativeService([dict(step='spawn', **rule)])
                self.assertIsNotNone(self.capture(native))
                self.assertEqual(native.counts['install'], 0)
                self.assertEqual(native.counts['privacy'], 0)
                self.assertEqual(native.devices, {})

    def test_failed_refresh_partial_environment_is_redacted_and_never_launched(self):
        value = b'/private/partial-injector.dylib'
        native = NativeService([dict(step='install', code=73),
            dict(step='spawn', at=[2], timeout=True, stdout=value, stderr=b'failed ' + value)])
        self.assertIsNotNone(self.capture(native))
        self.assertFalse(self.case_calls)
        self.assertEqual(native.devices, {})
        self.assertEqual(json.loads((self.out / 'launch-environment.status.json').read_text())['exitCode'], None)
        for path in self.out.rglob('*'):
            if path.is_file() and path.suffix in ('.log', '.stdout', '.stderr'):
                self.assertNotIn(value, path.read_bytes(), str(path))

    def test_explicit_empty_override_skips_queries_and_checkpoint_precedes_first_case(self):
        native = NativeService([dict(step='privacy', code=73)])
        self.assertIsNone(self.capture(native, override=''))
        self.assertEqual(native.counts['spawn'], 0)
        self.assertEqual([case['inherited'] for case in self.case_calls], ['', ''])
        self.assertEqual([case['state']['checkpoint'] for case in self.case_calls], [True, True])
        self.assertTrue(all(case['state']['retry_used'] for case in self.case_calls))
        self.assertEqual(self.case_calls[1]['expected_container'], str(self.container))
        self.assert_final_identity(native)

    def test_shutdown_timeout_retains_diagnostics_while_delete_and_absence_still_run(self):
        native = NativeService([dict(step='shutdown', timeout=True, stdout=b'partial-stop', stderr=b'cleanup-timeout')])
        self.assertIsNone(self.capture(native, override=''))
        self.assertEqual((self.out / 'shutdown.stdout').read_bytes(), b'partial-stop')
        self.assertEqual((self.out / 'shutdown.stderr').read_bytes(), b'cleanup-timeout')
        self.assertIsNone(json.loads((self.out / 'shutdown.status.json').read_text())['exitCode'])
        cleanup = json.loads((self.out / 'cleanup.json').read_text())
        self.assertIsNone(cleanup['shutdownExitCode']); self.assertTrue(cleanup['deleted'])
        self.assert_bounds(native)

    def test_delete_failure_or_lowercase_inventory_survivor_cannot_qualify(self):
        for name, rule in (('delete-failed', dict(code=73)), ('device-remained', dict(retain=True))):
            with self.subTest(name=name):
                self.out = self.root / ('capture-' + name)
                native = NativeService([dict(step='delete', **rule)])
                self.assertIsNotNone(self.capture(native, override=''))
                self.assertFalse((self.out / 'manifest.json').exists())
                self.assertTrue(any(call['arguments'][2:4] == ['list', 'devices'] for call in native.calls))


if __name__ == '__main__':
    unittest.main()
