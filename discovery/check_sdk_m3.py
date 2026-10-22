#!/usr/bin/env python3
"""Synthetic M3 evidence controls; never dispatches a URL or uses a simulator."""
import copy
import hashlib
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

from summarize import EvidenceError
import sdk_m3_conformance as gate
from sdk_m3_conformance import qualify
import check_sdk_m0 as m0_controls
import run_sdk_m3 as runner


def sample():
    rows = []
    for event, fields in [
        ('app.entry', {}), ('launch', {'mode': 'sdk-m3', 'traceVersion': 2}),
        ('m3.listenerReady', {'conversationCount': 0}),
        ('m3.nativeIngress', {'kind': 'url', 'urlSHA256': hashlib.sha256(b'tel:+15555550142').hexdigest()}),
        ('m3.dialRequest', {'handleSHA256': hashlib.sha256(b'+15555550142').hexdigest(), 'video': False, 'conversationCount': 0}),
        ('sdk.result', {'success': True}), ('done', {}),
    ]:
        index = len(rows)
        rows.append(dict(event=event, sequence=index + 1, t_ms=index * 10,
                         wallTimeMS=1_790_000_000_000 + index * 10,
                         runID='run', simulatorID='sim', pid=123, bundleID='dev.iosvoipsdk.example',
                         main=True, **fields))
    dispatch = dict(schemaVersion=1, runID='run', simulatorID='sim', appPID=123,
                    argv=['xcrun', 'simctl', 'openurl', 'sim', 'tel:+15555550142'], exitCode=0,
                    startedWallTimeMS=1_790_000_000_025, finishedWallTimeMS=1_790_000_000_035)
    return rows, dispatch


class Controls(unittest.TestCase):
    def run_capture(self, *, dyld_status=0, dyld=b'', dyld_timeout=False, dyld_stderr=b'',
                    dispatch_status=0, omit_receipt=False, terminate_during_boot=False):
        with tempfile.TemporaryDirectory(prefix='sdk-m3-runner-controls-') as directory:
            root = Path(directory); app = root / 'Original.app'; app.mkdir(); data = root / 'data'; data.mkdir()
            out = root / 'capture'
            info = dict(CFBundleExecutable='Example', CFBundleIdentifier=gate.BUNDLE,
                        UIBackgroundModes=['voip'], NSUserActivityTypes=['INStartCallIntent'])
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            (app / 'Example').write_bytes(b'original example'); (app / 'main.jsbundle').write_bytes(b'JS')
            receipt = root / 'build.json'
            m0_controls.write_json(receipt, dict(schemaVersion=1, **m0_controls.IDENTITY, sourceStart=m0_controls.IDENTITY,
                files={'binaries/example': gate.m0.digest(app / 'Example'), 'binaries/main.jsbundle': gate.m0.digest(app / 'main.jsbundle')}))
            simulator = '00000000-0000-4000-8000-000000000001'
            calls = []
            launches = []

            def external(argv, **kwargs):
                calls.append(argv)
                output = b''; status = 0
                if terminate_during_boot and argv[:3] == ['xcrun', 'simctl', 'boot']:
                    signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                if argv[0] == 'codesign' and '--sign' in argv:
                    (out / 'signed-example.app/Example').write_bytes(b'signed owned copy')
                elif argv[0] == 'codesign' and '--display' in argv:
                    output = plistlib.dumps({'com.apple.developer.calling-app': True})
                elif argv[:4] == ['xcrun', 'simctl', 'list', 'runtimes']:
                    output = json.dumps({'runtimes': [dict(platform='iOS', isAvailable=True, identifier='ios-27', version='27.0', buildversion='fixture')]}).encode()
                elif argv[:3] == ['xcrun', 'simctl', 'create']: output = simulator.encode()
                elif argv[:3] == ['xcrun', 'simctl', 'spawn']:
                    self.assertEqual(argv[4:7], ['launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES'])
                    self.assertEqual(kwargs['env']['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], '')
                    if dyld_timeout: raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
                    output, status = dyld, dyld_status
                elif argv[:3] == ['xcrun', 'simctl', 'get_app_container']:
                    output = str(out / 'signed-example.app' if argv[-1] == 'app' else data).encode()
                elif argv[:3] == ['xcrun', 'simctl', 'openurl']: status = dispatch_status
                elif argv == ['xcodebuild', '-version']: output = b'Xcode fixture'
                return subprocess.CompletedProcess(argv, status, output,
                    dyld_stderr if argv[:3] == ['xcrun', 'simctl', 'spawn'] else b'')

            class Supervisor:
                def __init__(self, argv, **kwargs):
                    self.status = None
                    launches.append(kwargs['env'])
                    run = kwargs['env']['SIMCTL_CHILD_SDK_M3_RUN_ID']
                    rows, _ = sample()
                    for row in rows: row.update(runID=run, simulatorID=simulator)
                    m0_controls.write_trace(out, gate.NAME, rows)
                    m0_controls.change_json(out, gate.NAME + '.receipt.json', lambda r: r.update(runID=run, simulatorID=simulator))
                    if omit_receipt: (out / (gate.NAME + '.receipt.json')).unlink()
                    session = data / 'Documents/.callkit-simulator'; session.mkdir(parents=True)
                    m0_controls.write_json(session / 'session.json', dict(runID=run, pid=123, bundleID=gate.BUNDLE))
                def poll(self): return self.status
                def wait(self, timeout): self.status = 0; return 0
                def terminate(self): self.status = -15
                def kill(self): self.status = -9

            captured = io.StringIO()
            handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
            with patch.object(runner.m0, 'source_identity', return_value=m0_controls.IDENTITY), \
                 patch.object(runner.subprocess, 'run', side_effect=external), \
                 patch.object(runner.subprocess, 'Popen', Supervisor), \
                 patch.object(runner.time, 'time_ns', return_value=1_790_000_000_025_000_000), \
                 patch.object(sys, 'argv', ['run_sdk_m3.py', '--app', str(app), '--build-receipt', str(receipt), '--out', str(out)]), \
                 patch.dict(os.environ, {'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': '/private/fixture-injector.dylib'}), \
                 contextlib.redirect_stdout(captured):
                status = runner.main()
            self.assertEqual(handlers, {sig: signal.getsignal(sig) for sig in handlers})
            self.assertNotIn('/private/fixture-injector.dylib', captured.getvalue())
            self.assertEqual((app / 'Example').read_bytes(), b'original example')
            self.assertTrue(json.loads((out / 'cleanup.json').read_text())['deleted'])
            self.assertTrue(any(call[:3] == ['xcrun', 'simctl', 'delete'] and call[-1] == simulator for call in calls))
            self.assertFalse(any('setenv' in call or 'unsetenv' in call for call in calls))
            if launches: self.assertEqual(launches[0]['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], '/private/fixture-injector.dylib')
            return status, json.loads((out / 'summary.json').read_text())

    def capture(self, edit=None):
        with tempfile.TemporaryDirectory(prefix='sdk-m3-controls-') as directory:
            root = Path(directory)
            (root / 'binaries').mkdir()
            for name in gate.FILES:
                (root / name).write_bytes(('synthetic ' + name).encode())
            (root / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=gate.BUNDLE,
                UIBackgroundModes=['voip'], NSUserActivityTypes=['INStartCallIntent'])))
            (root / 'signed-entitlements.plist').write_bytes(plistlib.dumps({'com.apple.developer.calling-app': True}))
            write = m0_controls.write_json
            identity = m0_controls.IDENTITY
            write(root / 'input-build-receipt.json', dict(schemaVersion=1, **identity, sourceStart=identity,
                files={'binaries/example': gate.m0.digest(root / 'binaries/unsigned-example'),
                       'binaries/main.jsbundle': gate.m0.digest(root / 'binaries/main.jsbundle')}))
            write(root / 'environment.json', dict(simulatorID='sim', simulatorRuntimeID='ios-27', simulatorOS='27.0',
                simulatorBuild='fixture', xcodeVersion='27.1'))
            write(root / 'cleanup.json', dict(simulatorID='sim', deleted=True, globalEnvironmentUnchanged=True))
            rows, dispatch = sample()
            write(root / 'dispatch.json', dispatch)
            phases = ['sign-owned-copy', 'verify-owned-signature', 'read-signed-entitlements', 'install', 'os-tel-dispatch']
            write(root / 'commands.json', dict(steps=[dict(phase=phase, exitCode=0) for phase in phases]))
            m0_controls.write_trace(root, gate.NAME, rows)
            m0_controls.change_json(root, gate.NAME + '.receipt.json', lambda receipt: receipt.update(runID='run', simulatorID='sim'))
            manifest = dict(schemaVersion=1, scenario='sdk-m3', runID='run', simulatorID='sim', ownsSimulator=True,
                runtimeInjectionRequested=False, directIngressInjectionRequested=False, **identity,
                files={name: gate.m0.digest(root / name) for name in gate.FILES},
                installed={key: gate.m0.digest(root / name) for key, name in [('executableSHA256', 'binaries/example'),
                    ('javascriptSHA256', 'binaries/main.jsbundle'), ('infoPlistSHA256', 'Info.plist')]})
            for name, key in [('input-build-receipt.json', 'inputBuildReceiptSHA256'), ('environment.json', 'environmentSHA256'),
                              ('cleanup.json', 'cleanupSHA256'), ('commands.json', 'commandsSHA256'), ('dispatch.json', 'dispatchSHA256')]:
                manifest[key] = gate.m0.digest(root / name)
            write(root / 'manifest.json', manifest)
            if edit: edit(root)
            with patch.object(gate.m0, 'source_identity', return_value=identity), \
                 patch.object(gate.m0.subprocess, 'run', side_effect=AssertionError('native command forbidden')), \
                 patch.object(gate.m0.subprocess, 'check_output', side_effect=AssertionError('subprocess forbidden')):
                if edit:
                    with self.assertRaises((EvidenceError, OSError, KeyError, TypeError, ValueError)):
                        gate.validate(root)
                else:
                    self.assertTrue(gate.validate(root)['success'])

    def reject(self, edit):
        rows, dispatch = copy.deepcopy(sample())
        edit(rows, dispatch)
        with self.assertRaises((EvidenceError, KeyError, TypeError, ValueError)):
            qualify(rows, dispatch, 'run', 'sim', 123)

    def test_real_url_and_public_event_required(self):
        rows, dispatch = sample()
        self.assertTrue(qualify(rows, dispatch, 'run', 'sim', 123)['success'])
        self.reject(lambda rows, _: rows.pop(3))
        self.reject(lambda rows, _: rows.pop(4))
        self.reject(lambda _, dispatch: dispatch.update(exitCode=1))

    def test_public_intent_ingress_is_distinct_from_injection(self):
        rows, dispatch = sample()
        rows[3] = {**rows[3], 'kind': 'activity', 'isStartCallIntent': True}
        self.assertTrue(qualify(rows, dispatch, 'run', 'sim', 123)['success'])
        self.reject(lambda rows, _: rows[3].update(kind='helper'))
        self.reject(lambda rows, _: rows[3].update(kind='activity', isStartCallIntent=False))

    def test_dispatch_identity_and_route(self):
        for field in ('runID', 'simulatorID', 'appPID'):
            self.reject(lambda _, dispatch, field=field: dispatch.update({field: 'other'}))
        self.reject(lambda _, dispatch: dispatch.update(argv=['xcrun', 'simctl', 'openurl', 'sim', 'example:fake']))

    def test_callback_identity_and_time(self):
        self.reject(lambda rows, _: rows[4].update(pid=999))
        self.reject(lambda rows, _: rows[3].update(main=False))
        self.reject(lambda rows, _: rows[3].update(wallTimeMS=1_789_999_000_000))
        self.reject(lambda rows, _: rows[4].update(sequence=1))

    def test_exact_destination_no_call_and_no_private_values(self):
        self.reject(lambda rows, _: rows[4].update(handleSHA256='other'))
        self.reject(lambda rows, _: rows[4].update(video=True))
        self.reject(lambda rows, _: rows[4].update(conversationCount=1))
        self.reject(lambda rows, _: rows[4].update(handle='+15555550142'))

    def test_readiness_and_completion(self):
        self.reject(lambda rows, _: rows[2].update(conversationCount=1))
        self.reject(lambda rows, _: rows[5].update(success=False))
        self.reject(lambda rows, _: rows.append(dict(rows[4])))
        self.reject(lambda _, dispatch: dispatch.update(startedWallTimeMS=1_790_000_000_000))

    def test_bound_capture_and_tampered_build(self):
        self.capture()
        self.capture(lambda root: (root / 'binaries/example').write_bytes(b'different executable'))
        self.capture(lambda root: (root / 'binaries/main.jsbundle').write_bytes(b'different JS'))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'input-build-receipt.json', 'inputBuildReceiptSHA256',
            lambda receipt: receipt.update(sourceStart={'sourceCommit': 'other'})))

    def test_rehashed_ineligible_app_is_rejected(self):
        def plist(root, name, edit):
            path = root / name
            value = plistlib.loads(path.read_bytes()); edit(value); path.write_bytes(plistlib.dumps(value))
            def rebind(manifest):
                manifest['files'][name] = gate.m0.digest(path)
                if name == 'Info.plist': manifest['installed']['infoPlistSHA256'] = gate.m0.digest(path)
            m0_controls.change_json(root, 'manifest.json', rebind)
        self.capture(lambda root: plist(root, 'signed-entitlements.plist', lambda value: value.update({'com.apple.developer.calling-app': False})))
        self.capture(lambda root: plist(root, 'Info.plist', lambda value: value.update(CFBundleURLTypes=[{'CFBundleURLSchemes': ['tel']}])) )

    def test_cleanup_supervisor_and_control_evidence_required(self):
        self.capture(lambda root: m0_controls.change_bound_json(root, 'cleanup.json', 'cleanupSHA256', lambda row: row.update(deleted=False)))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'cleanup.json', 'cleanupSHA256', lambda row: row.update(globalEnvironmentUnchanged=False)))
        self.capture(lambda root: m0_controls.change_json(root, gate.NAME + '.receipt.json', lambda row: row.update(launcherAppPID=999)))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'commands.json', 'commandsSHA256', lambda row: row['steps'][0].update(exitCode=1)))
        self.capture(lambda root: (root / 'dispatch.json').unlink())

    def test_mocked_runner_signs_only_copy_and_preserves_environment(self):
        status, result = self.run_capture()
        self.assertEqual(status, 0)
        self.assertTrue(result['success'])

    def test_mocked_runner_failures_still_delete_owned_simulator(self):
        for options in [dict(dyld_status=1), dict(dyld_timeout=True), dict(dyld_stderr=b'diagnostic'),
                        dict(dispatch_status=1), dict(omit_receipt=True), dict(terminate_during_boot=True)]:
            with self.subTest(options=options):
                status, result = self.run_capture(**options)
                self.assertEqual(status, 1)
                self.assertFalse(result['success'])


if __name__ == '__main__':
    unittest.main()
