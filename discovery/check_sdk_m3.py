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
import struct
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


def macho(claims=None):
    xml = plistlib.dumps({'com.apple.developer.calling-app': True} if claims is None else claims)
    header = struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 152, 0, 0)
    segment = bytearray(152)
    struct.pack_into('<II', segment, 0, 0x19, 152)
    struct.pack_into('<I', segment, 64, 1)
    segment[72:88] = b'__entitlements'.ljust(16, b'\0')
    segment[88:104] = b'__TEXT'.ljust(16, b'\0')
    struct.pack_into('<Q', segment, 112, len(xml))
    struct.pack_into('<I', segment, 120, len(header) + len(segment))
    return header + segment + xml


def products(root):
    root.mkdir()
    (root / 'UITest').write_bytes(b'synthetic compiled UI test boundary')
    (root / 'Settings.xctestrun').write_bytes(plistlib.dumps({'SettingsProbe': {
        'IsUITestBundle': True, 'EnvironmentVariables': {'DYLD_INSERT_LIBRARIES': '/usr/lib/libRPAC.dylib'},
        'TestBundlePath': '__TESTROOT__/UITest'}}))
    return gate.product_files(root)


def attachments(root, simulator, selected=True):
    root.mkdir()
    rows = []
    for role in gate.SETTINGS_ROLES:
        name = role + ('.png' if role.endswith('-screen') else '.txt')
        if role.endswith('-screen'): data = b'\x89PNG\r\n\x1a\n' + b'synthetic pixels' * 8
        else:
            selected_trait = ', Selected' if selected and role.startswith('after-') else ''
            data = ("Application, pid: 456, label: 'Settings'\n Button, label: 'VoIP SDK Example'" + selected_trait).encode()
        (root / name).write_bytes(data)
        rows.append(dict(exportedFileName=name, suggestedHumanReadableName=role + '_0_test', deviceId=simulator))
    m0_controls.write_json(root / 'manifest.json', [dict(testIdentifier=gate.SETTINGS_TEST, attachments=rows)])


def selection_row(run_id, simulator, pid=123, selected=True):
    return dict(schemaVersion=1, runID=run_id, simulatorID=simulator, appPID=pid, method='public-xctest-ui',
                selected=selected, beforeSelected=False, tapped=True, wallTimeMS=1_790_000_000_024)

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
    def test_settings_list_uses_measured_unique_fallback(self):
        source = (Path(__file__).parent / 'm3-settings/DefaultCallingTests.swift').read_text()
        start = source.index('  @MainActor private func observedSettingsList(')
        end = source.index('\n  @MainActor func testSelectCallingApp()', start)
        # Compile the actual query policy with only the public XCUI boundary
        # replaced. This is a host control, not a Settings/native measurement.
        program = '''
import Foundation
@MainActor final class XCUIElement {
    let exists: Bool
    init(_ exists: Bool = true) { self.exists = exists }
    func waitForExistence(timeout: Double) -> Bool { precondition(timeout == 10); return exists }
}
@MainActor final class XCUIElementQuery {
    let named: XCUIElement
    let elements: [XCUIElement]
    init(_ named: XCUIElement, _ elements: [XCUIElement]) { self.named = named; self.elements = elements }
    subscript(_ name: String) -> XCUIElement {
        precondition(name == "com.apple.settings.sidebar.collectionView"); return named
    }
    var count: Int { elements.count }
    func element(boundBy index: Int) -> XCUIElement { elements[index] }
}
@MainActor final class XCUIApplication {
    let collectionViews: XCUIElementQuery
    init(_ named: XCUIElement, _ elements: [XCUIElement]) { collectionViews = XCUIElementQuery(named, elements) }
}
@MainActor final class QueryPolicy {
''' + source[start:end] + '''
    func check() {
        let named = XCUIElement(), first = XCUIElement(), second = XCUIElement(), absent = XCUIElement(false)
        precondition(observedSettingsList(XCUIApplication(named, [first, second])) === named)
        precondition(observedSettingsList(XCUIApplication(absent, [first])) === first)
        precondition(observedSettingsList(XCUIApplication(absent, [])) == nil)
        precondition(observedSettingsList(XCUIApplication(absent, [first, second])) == nil)
    }
}
@main struct Control { @MainActor static func main() { QueryPolicy().check() } }
'''
        with tempfile.TemporaryDirectory(prefix='sdk-m3-settings-query-') as directory:
            root = Path(directory); code = root / 'Control.swift'; code.write_text(program)
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-parse-as-library', '-module-cache-path', str(root / 'cache'), str(code), '-o', str(root / 'control')],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / 'control')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def run_capture(self, *, dyld_status=0, dyld=b'', dyld_timeout=False, dyld_stderr=b'',
                    dispatch_status=0, omit_receipt=False, terminate_during_boot=False, preboot=False,
                    settings_selected=True, settings_pid=123, settings_device=None, create_timeout=False, create_invalid=False,
                    direct_rows=None):
        with tempfile.TemporaryDirectory(prefix='sdk-m3-runner-controls-') as directory:
            root = Path(directory); app = root / 'Original.app'; app.mkdir(); data = root / 'data'; data.mkdir(); (data / 'tmp').mkdir()
            out = root / 'capture'; ui = root / 'ui'; ui_files = products(ui)
            info = dict(CFBundleExecutable='Example', CFBundleIdentifier=gate.BUNDLE,
                        UIBackgroundModes=['voip'], NSUserActivityTypes=['INStartCallIntent'])
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            original = macho(); (app / 'Example').write_bytes(original); (app / 'main.jsbundle').write_bytes(b'JS')
            (root / 'build.log').write_bytes(b'synthetic native build process boundary')
            receipt = root / 'build.json'
            m0_controls.write_json(receipt, dict(schemaVersion=1, product='sdk-m3', configuration='Release', mediaAdapter='none',
                **m0_controls.IDENTITY, sourceStart=m0_controls.IDENTITY, sourceEnd=m0_controls.IDENTITY,
                files={'binaries/example': gate.m0.digest(app / 'Example'), 'binaries/main.jsbundle': gate.m0.digest(app / 'main.jsbundle'), 'Info.plist': gate.m0.digest(app / 'Info.plist')},
                settingsProducts=ui_files, buildLogs={'build.log': gate.m0.digest(root / 'build.log')}))
            simulator = '00000000-0000-4000-8000-000000000001'
            calls, launches = [], []
            device_state = dict(name=None, deleted=False)

            def external(argv, **kwargs):
                calls.append(argv); output = b''; status = 0
                if argv[:3] in (['xcrun', 'simctl', 'create'], ['xcrun', 'simctl', 'boot']):
                    self.assertFalse(any(key.startswith(('SIMCTL_CHILD_SDK_M3_', 'SIMCTL_CHILD_SDK_M1_', 'SIMCTL_CHILD_SDK_SYSTEM_')) for key in kwargs['env']))
                if terminate_during_boot and argv[:3] == ['xcrun', 'simctl', 'boot']:
                    signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                if argv[0] == 'codesign':
                    self.assertNotIn('--sign', argv)
                    if '--display' in argv: output = plistlib.dumps({})
                elif argv[:4] == ['xcrun', 'simctl', 'list', 'runtimes']:
                    output = json.dumps({'runtimes': [dict(platform='iOS', isAvailable=True, identifier='ios-27', version='27.0', buildversion='fixture')]}).encode()
                elif argv[:3] == ['xcrun', 'simctl', 'create']:
                    device_state['name'] = argv[3]
                    if create_timeout: raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
                    output = b'all' if create_invalid else simulator.encode()
                elif argv[:4] == ['xcrun', 'simctl', 'list', 'devices']:
                    rows = [dict(name='sdk-m3-unrelated-QA', udid='00000000-0000-4000-8000-000000000002')]
                    if not device_state['deleted']: rows.append(dict(name=device_state['name'], udid=simulator))
                    output = json.dumps({'devices': {'ios-27': rows}}).encode()
                elif argv[:3] == ['xcrun', 'simctl', 'delete']: device_state['deleted'] = True
                elif argv[:3] == ['xcrun', 'simctl', 'spawn']:
                    self.assertEqual(argv[4:7], ['launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES'])
                    self.assertEqual(kwargs['env']['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], '')
                    if dyld_timeout: raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
                    output, status = dyld, dyld_status
                elif argv[:3] == ['xcrun', 'simctl', 'get_app_container']:
                    output = str(out / 'example.app' if argv[-1] == 'app' else data).encode()
                elif argv[:3] == ['xcrun', 'simctl', 'openurl']: status = dispatch_status
                elif argv == ['xcodebuild', '-version']: output = b'Xcode fixture'
                elif argv[:2] == ['xcodebuild', 'test-without-building']:
                    config = plistlib.loads(Path(argv[argv.index('-xctestrun') + 1]).read_bytes())['SettingsProbe']['EnvironmentVariables']
                    event = selection_row(config['SDK_M3_SETTINGS_RUN_ID'], config['SDK_M3_SETTINGS_SIMULATOR_ID'], settings_pid, settings_selected)
                    output = ('M3SETTINGS ' + json.dumps(event) + '\n').encode()
                elif argv[:4] == ['xcrun', 'xcresulttool', 'export', 'attachments']:
                    attachments(Path(argv[argv.index('--output-path') + 1]), settings_device or simulator, settings_selected)
                return subprocess.CompletedProcess(argv, status, output,
                    dyld_stderr if argv[:3] == ['xcrun', 'simctl', 'spawn'] else b'')

            class Supervisor:
                def __init__(self, argv, **kwargs):
                    launch_command = argv[argv.index('--launch-command') + 1:]
                    if launch_command != ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', simulator, gate.BUNDLE]:
                        raise AssertionError('M3 example must use the plain public console transport')
                    self.status = None; launches.append(kwargs['env'])
                    run = kwargs['env']['SIMCTL_CHILD_SDK_M3_RUN_ID']
                    rows = copy.deepcopy(direct_rows) if direct_rows is not None else sample()[0]
                    for row in rows: row.update(runID=run, simulatorID=simulator)
                    self.rows, self.run = rows, run
                    name = 'sdk-m3-direct' if direct_rows is not None else gate.NAME
                    m0_controls.write_trace(out, name, rows)
                    m0_controls.change_json(out, name + '.receipt.json', lambda r: r.update(runID=run, simulatorID=simulator))
                    if omit_receipt: (out / (name + '.receipt.json')).unlink()
                    session = data / 'Documents/.callkit-simulator'; session.mkdir(parents=True)
                    m0_controls.write_json(session / 'session.json', dict(runID=run, pid=123, bundleID=gate.BUNDLE))
                def poll(self): return self.status
                def wait(self, timeout):
                    if direct_rows is not None and (out / 'direct-control.json').exists() and not omit_receipt:
                        control = out / 'direct-control.json'
                        value = json.loads(control.read_text())
                        if value != dict(schemaVersion=1, runID=self.run, simulatorID=simulator, appPID=123, delivery='direct-url-and-intent'):
                            raise AssertionError('direct control identity differs')
                        if (data / 'tmp' / ('sdk-m3-direct-' + self.run + '.json')).read_bytes() != control.read_bytes():
                            raise AssertionError('direct control was not delivered to this app sandbox')
                        next(r for r in self.rows if r['event'] == 'm3.directControl')['controlSHA256'] = gate.m0.digest(control)
                        m0_controls.write_trace(out, 'sdk-m3-direct', self.rows)
                        m0_controls.change_json(out, 'sdk-m3-direct.receipt.json', lambda r: r.update(runID=self.run, simulatorID=simulator))
                    self.status = 0; return 0
                def terminate(self): self.status = -15
                def kill(self): self.status = -9

            def observe_preboot(_):
                checkpoint = json.loads((out / 'preboot-checkpoint.json').read_text())
                self.assertFalse(any(call[:3] == ['xcrun', 'simctl', 'boot'] for call in calls))
                m0_controls.write_json(out / 'boot-observation.json', checkpoint)

            captured = io.StringIO()
            handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
            with patch.object(runner.m0, 'source_identity', return_value=m0_controls.IDENTITY), \
                 patch.object(runner.subprocess, 'run', side_effect=external), \
                 patch.object(runner.subprocess, 'Popen', Supervisor), \
                 patch.object(runner.time, 'time_ns', return_value=1_790_000_000_055_000_000 if direct_rows is not None else 1_790_000_000_025_000_000), \
                 patch.object(sys, 'argv', ['run_sdk_m3.py', '--app', str(app), '--build-receipt', str(receipt), '--settings-products', str(ui), '--out', str(out)] +
                              (['--preboot-wait-seconds', '1'] if preboot else [])), \
                 patch.object(runner.time, 'sleep', side_effect=observe_preboot if preboot else lambda _: None), \
                 patch.dict(os.environ, {'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': '/private/fixture-injector.dylib',
                                        'SIMCTL_CHILD_SDK_M3_RUN_ID': 'stale-boot-run', 'SIMCTL_CHILD_SDK_M1_CASE': 'stale-case',
                                        'SIMCTL_CHILD_SDK_SYSTEM_CASE': 'stale-system', 'SIMCTL_CHILD_SDK_SYSTEM_RUN_ID': 'stale-system-run'}), \
                 contextlib.redirect_stdout(captured):
                status = runner.main(direct=direct_rows is not None)
            self.assertEqual(handlers, {sig: signal.getsignal(sig) for sig in handlers})
            self.assertNotIn('/private/fixture-injector.dylib', captured.getvalue())
            self.assertEqual((app / 'Example').read_bytes(), original)
            self.assertTrue(json.loads((out / 'cleanup.json').read_text())['deleted'])
            self.assertTrue(any(call[:3] == ['xcrun', 'simctl', 'delete'] and call[-1] == simulator for call in calls))
            self.assertFalse(any('setenv' in call or 'unsetenv' in call for call in calls))
            self.assertTrue(all(call[-1] == simulator for call in calls if call[:3] in (['xcrun', 'simctl', 'shutdown'], ['xcrun', 'simctl', 'delete'])))
            if create_timeout or create_invalid:
                cleanup = json.loads((out / 'cleanup.json').read_text())
                self.assertEqual(cleanup['recoveredSimulators'], [simulator])
                self.assertTrue(cleanup['recoveredCleanup'][0]['absentFromInventory'])
                self.assertFalse(launches)
            if launches:
                self.assertEqual(launches[0]['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], '/private/fixture-injector.dylib')
                self.assertNotEqual(launches[0]['SIMCTL_CHILD_SDK_M3_RUN_ID'], 'stale-boot-run')
                if direct_rows is not None:
                    self.assertEqual(launches[0]['SIMCTL_CHILD_SDK_M3_DELIVERY'], 'direct-url-and-intent')
                    self.assertFalse(any(call[:3] == ['xcrun', 'simctl', 'openurl'] or call[:2] == ['xcodebuild', 'test-without-building'] for call in calls))
            if not settings_selected or settings_pid != 123 or settings_device:
                self.assertFalse(any(call[:3] == ['xcrun', 'simctl', 'openurl'] for call in calls))
            return status, json.loads((out / 'summary.json').read_text())

    def capture(self, edit=None):
        with tempfile.TemporaryDirectory(prefix='sdk-m3-controls-') as directory:
            root = Path(directory); (root / 'binaries').mkdir()
            (root / 'binaries/example').write_bytes(macho()); (root / 'binaries/main.jsbundle').write_bytes(b'synthetic JS')
            (root / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=gate.BUNDLE,
                UIBackgroundModes=['voip'], NSUserActivityTypes=['INStartCallIntent'])))
            (root / 'simulated-entitlements.plist').write_bytes(gate.simulated_entitlements(root / 'binaries/example'))
            (root / 'host-entitlements.plist').write_bytes(plistlib.dumps({}))
            write = m0_controls.write_json; identity = m0_controls.IDENTITY
            (root / 'settings').mkdir(); ui = root / 'settings/products'; ui_files = products(ui)
            configured = gate.settings_configuration(plistlib.loads((ui / 'Settings.xctestrun').read_bytes()), 'run', 'sim', 123, '')
            (ui / 'M3Run.xctestrun').write_bytes(plistlib.dumps(configured))
            attachments(root / 'settings/attachments', 'sim')
            (root / 'settings/test.log').write_text('M3SETTINGS ' + json.dumps(selection_row('run', 'sim')) + '\n')
            (root / 'build-logs').mkdir(); (root / 'build-logs/build.log').write_bytes(b'synthetic build')
            write(root / 'input-build-receipt.json', dict(schemaVersion=1, product='sdk-m3', configuration='Release', mediaAdapter='none',
                **identity, sourceStart=identity, sourceEnd=identity, settingsProducts=ui_files,
                buildLogs={'build.log': gate.m0.digest(root / 'build-logs/build.log')},
                files={'binaries/example': gate.m0.digest(root / 'binaries/example'),
                       'binaries/main.jsbundle': gate.m0.digest(root / 'binaries/main.jsbundle'), 'Info.plist': gate.m0.digest(root / 'Info.plist')}))
            write(root / 'environment.json', dict(simulatorID='sim', simulatorRuntimeID='ios-27', simulatorOS='27.0',
                simulatorBuild='fixture', xcodeVersion='27.1'))
            write(root / 'cleanup.json', dict(simulatorID='sim', deleted=True, absentFromInventory=True, globalEnvironmentUnchanged=True))
            rows, dispatch = sample(); write(root / 'dispatch.json', dispatch)
            phases = ['verify-built-signature', 'read-host-entitlements', 'install', 'select-calling-app', 'export-settings-attachments', 'os-tel-dispatch']
            ui_argv = ['xcodebuild', 'test-without-building', '-xctestrun', str(ui / 'M3Run.xctestrun'), '-destination', 'platform=iOS Simulator,id=sim', '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1', '-only-testing:SettingsProbe/DefaultCallingTests/testSelectCallingApp']
            write(root / 'commands.json', dict(steps=[dict(phase=phase, exitCode=0, argv=ui_argv if phase=='select-calling-app' else []) for phase in phases]))
            m0_controls.write_trace(root, gate.NAME, rows)
            m0_controls.change_json(root, gate.NAME + '.receipt.json', lambda receipt: receipt.update(runID='run', simulatorID='sim'))
            manifest = dict(schemaVersion=1, scenario='sdk-m3', runID='run', simulatorID='sim', ownsSimulator=True,
                runtimeInjectionRequested=False, directIngressInjectionRequested=False, **identity,
                files={name: gate.m0.digest(root / name) for name in gate.FILES},
                settingsRunSHA256=gate.m0.digest(ui / 'M3Run.xctestrun'), inheritedDYLDSHA256=hashlib.sha256(b'').hexdigest(),
                settingsFiles={p.relative_to(root).as_posix(): gate.m0.digest(p) for p in (root / 'settings').rglob('*') if p.is_file() and 'products' not in p.parts},
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
                else: self.assertTrue(gate.validate(root)['success'])

    def reject(self, edit):
        rows, dispatch = copy.deepcopy(sample())
        edit(rows, dispatch)
        with self.assertRaises((EvidenceError, KeyError, TypeError, ValueError)):
            qualify(rows, dispatch, 'run', 'sim', 123)

    def test_simulator_claim_is_read_from_exact_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'example'; path.write_bytes(macho())
            self.assertTrue(plistlib.loads(gate.simulated_entitlements(path))['com.apple.developer.calling-app'])
            variants = [b'', b'not Mach-O', macho()[:50]]
            for offset, value in [(16, 2), (20, 0xFFFFFFFF), (32 + 4, 7), (32 + 120, 0xFFFFFFFE)]:
                data = bytearray(macho()); struct.pack_into('<I', data, offset, value); variants.append(data)
            data = bytearray(macho()); data[32 + 72] = ord('x'); variants.append(data)
            for data in variants:
                path.write_bytes(data)
                with self.assertRaises((EvidenceError, ValueError)): gate.simulated_entitlements(path)

    def test_settings_config_is_scoped_and_preserves_existing_injector(self):
        original = {'SettingsProbe': {'IsUITestBundle': True, 'EnvironmentVariables': {'DYLD_INSERT_LIBRARIES': '/system/XCTest.dylib', 'OTHER': 'preserved'}}}
        configured = gate.settings_configuration(original, 'run', 'sim', 123, '/fixture/Argent.dylib')
        environment = configured['SettingsProbe']['EnvironmentVariables']
        self.assertEqual(environment['DYLD_INSERT_LIBRARIES'], '/system/XCTest.dylib:/fixture/Argent.dylib')
        self.assertEqual(environment['OTHER'], 'preserved')
        self.assertNotIn('SDK_M3_SETTINGS_RUN_ID', original['SettingsProbe']['EnvironmentVariables'])
        self.assertEqual(environment['SDK_M3_SETTINGS_APP_PID'], '123')

    def test_rehashed_host_claim_and_settings_evidence_rejected(self):
        def edit_plist(root, name, edit):
            path = root / name; value = plistlib.loads(path.read_bytes()); edit(value); path.write_bytes(plistlib.dumps(value))
            m0_controls.change_json(root, 'manifest.json', lambda row: row['files'].update({name: gate.m0.digest(path)}))
        self.capture(lambda root: edit_plist(root, 'host-entitlements.plist', lambda value: value.update({'com.apple.developer.calling-app': True})))
        def change_settings(root, name, edit):
            m0_controls.change_json(root, name, edit)
            m0_controls.change_json(root, 'manifest.json', lambda row: row['settingsFiles'].update({name: gate.m0.digest(root / name)}))
        self.capture(lambda root: change_settings(root, 'settings/attachments/manifest.json', lambda rows: rows[0]['attachments'][0].update(deviceId='other-sim')))
        self.capture(lambda root: (root / 'settings/attachments/after-selection-accessibility.txt').unlink())
        def mutate_event(root, edit):
            path = root / 'settings/test.log'; event = json.loads(path.read_text().removeprefix('M3SETTINGS ')); edit(event)
            path.write_text('M3SETTINGS ' + json.dumps(event) + '\n')
            m0_controls.change_json(root, 'manifest.json', lambda row: row['settingsFiles'].update({'settings/test.log': gate.m0.digest(path)}))
        for edit in [lambda row: row.update(appPID=999), lambda row: row.update(selected=False), lambda row: row.update(tapped=False),
                     lambda row: row.update(wallTimeMS=1_790_000_000_001), lambda row: row.update(wallTimeMS=1_790_000_000_999)]:
            self.capture(lambda root, edit=edit: mutate_event(root, edit))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'commands.json', 'commandsSHA256', lambda row: row['steps'][3]['argv'].__setitem__(5, 'platform=iOS Simulator,id=other')))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'commands.json', 'commandsSHA256', lambda row: row['steps'][3].update(argv=['xcodebuild', 'test-without-building', '-destination'])))

    def test_mocked_settings_failure_prevents_os_dispatch(self):
        for options in [dict(settings_selected=False), dict(settings_pid=999), dict(settings_device='other')]:
            status, result = self.run_capture(**options)
            self.assertEqual(status, 1); self.assertFalse(result['success'])

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

    def test_protocol_scalars_reject_bool_and_float_aliases(self):
        for field, value in [('schemaVersion', True), ('schemaVersion', 1.0), ('exitCode', False), ('exitCode', 0.0), ('appPID', 123.0)]:
            self.reject(lambda _, dispatch, field=field, value=value: dispatch.update({field: value}))
        for index, field, value in [(0, 'sequence', 1.0), (0, 'pid', 123.0), (1, 'traceVersion', 2.0),
                                    (2, 'conversationCount', False), (4, 'conversationCount', 0.0)]:
            self.reject(lambda rows, _, index=index, field=field, value=value: rows[index].update({field: value}))
        self.capture(lambda root: m0_controls.change_json(root, 'manifest.json', lambda row: row.update(schemaVersion=True)))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'input-build-receipt.json', 'inputBuildReceiptSHA256', lambda row: row.update(schemaVersion=1.0)))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'commands.json', 'commandsSHA256', lambda row: row['steps'][0].update(exitCode=False)))

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
        self.capture(lambda root: plist(root, 'simulated-entitlements.plist', lambda value: value.update({'com.apple.developer.calling-app': False})))
        self.capture(lambda root: plist(root, 'Info.plist', lambda value: value.update(CFBundleURLTypes=[{'CFBundleURLSchemes': ['tel']}])) )
        self.capture(lambda root: plist(root, 'Info.plist', lambda value: value.update(CFBundleDisplayName='Post-build edit')))

    def test_cleanup_supervisor_and_control_evidence_required(self):
        self.capture(lambda root: m0_controls.change_bound_json(root, 'cleanup.json', 'cleanupSHA256', lambda row: row.update(deleted=False)))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'cleanup.json', 'cleanupSHA256', lambda row: row.update(globalEnvironmentUnchanged=False)))
        self.capture(lambda root: m0_controls.change_json(root, gate.NAME + '.receipt.json', lambda row: row.update(launcherAppPID=999)))
        self.capture(lambda root: m0_controls.change_bound_json(root, 'commands.json', 'commandsSHA256', lambda row: row['steps'][0].update(exitCode=1)))
        self.capture(lambda root: (root / 'dispatch.json').unlink())

    def test_mocked_runner_keeps_built_signature_and_preserves_environment(self):
        status, result = self.run_capture()
        self.assertEqual(status, 0)
        self.assertTrue(result['success'])

    def test_mocked_preboot_checkpoint_precedes_boot(self):
        status, result = self.run_capture(preboot=True)
        self.assertEqual(status, 0)
        self.assertTrue(result['success'])

    def test_uncertain_create_recovers_only_exact_owned_name(self):
        for options in [dict(create_timeout=True), dict(create_invalid=True)]:
            status, result = self.run_capture(**options)
            self.assertEqual(status, 1); self.assertFalse(result['success'])

    def test_mocked_runner_failures_still_delete_owned_simulator(self):
        for options in [dict(dyld_status=1), dict(dyld_timeout=True), dict(dyld_stderr=b'diagnostic'),
                        dict(dispatch_status=1), dict(omit_receipt=True), dict(terminate_during_boot=True)]:
            with self.subTest(options=options):
                status, result = self.run_capture(**options)
                self.assertEqual(status, 1)
                self.assertFalse(result['success'])


if __name__ == '__main__':
    unittest.main()
