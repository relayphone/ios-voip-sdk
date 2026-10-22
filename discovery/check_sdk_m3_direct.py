#!/usr/bin/env python3
"""Host controls for the explicitly direct A9 evidence boundary; no simulator."""
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_sdk_m0 as common
import check_sdk_m3 as os_controls
import sdk_m3_direct_conformance as gate
from summarize import EvidenceError


def sample():
    control = dict(schemaVersion=1, runID='run', simulatorID='sim', appPID=123, delivery=gate.DELIVERY)
    control_bytes = (json.dumps(control, indent=2) + '\n').encode()
    manifest = dict(runID='run', simulatorID='sim', directControlSHA256=hashlib.sha256(control_bytes).hexdigest(),
                    directControlCreatedWallTimeMS=1_790_000_000_065)
    rows = []
    events = [
        ('app.entry', {}), ('launch', dict(mode='sdk-m3-direct', traceVersion=2)),
        ('sdk.activation', dict(active=True)), ('sdk.managerCreated', dict(owner='ConversationClient.shared')),
        ('sdk.snapshot', dict(conversations=[])), ('m3.listenerReady', dict(conversationCount=0)),
        ('m3.directControl', dict(conversationCount=0, controlSHA256=manifest['directControlSHA256'])),
    ]
    for kind, method, raw, handle, video in gate.STEPS:
        events.append(('m3.directDelivery', dict(kind=kind, method=method, inputSHA256=hashlib.sha256(raw.encode()).hexdigest())))
        events.append(('m3.nativeIngress', dict(kind='url', urlSHA256=hashlib.sha256(raw.encode()).hexdigest())) if kind == 'url'
                      else ('m3.directIntentEntered', dict(isStartCallIntent=True)))
        events.append(('m3.directDeliveryReturned', dict(kind=kind, handled=True)))
        events.append(('m3.dialRequest', dict(conversationCount=0, handleSHA256=hashlib.sha256(handle.encode()).hexdigest(), video=video)))
    events += [('sdk.result', dict(success=True)), ('done', {})]
    for index, (event, fields) in enumerate(events):
        rows.append(dict(event=event, sequence=index + 1, t_ms=index * 10,
                         wallTimeMS=1_790_000_000_000 + index * 10, pid=123, runID='run', simulatorID='sim',
                         bundleID=gate.BUNDLE, main=True, **fields))
    # The external control is written between readiness and its native read.
    manifest['directControlCreatedWallTimeMS'] = rows[5]['wallTimeMS'] + 5
    return rows, control, manifest


def fixture(root):
    (root / 'binaries').mkdir()
    (root / 'binaries/example').write_bytes(os_controls.macho())
    (root / 'binaries/main.jsbundle').write_bytes(b'synthetic direct fixture JS')
    (root / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=gate.BUNDLE, UIBackgroundModes=['voip'])))
    (root / 'simulated-entitlements.plist').write_bytes(gate.simulated_entitlements(root / 'binaries/example'))
    (root / 'host-entitlements.plist').write_bytes(plistlib.dumps({}))
    (root / 'settings').mkdir()
    products = os_controls.products(root / 'settings/products')
    (root / 'build-logs').mkdir(); (root / 'build-logs/build.log').write_bytes(b'synthetic build only')
    identity = common.IDENTITY
    common.write_json(root / 'input-build-receipt.json', dict(schemaVersion=1, product='sdk-m3', configuration='Release',
        mediaAdapter='none', **identity, sourceStart=identity, sourceEnd=identity, settingsProducts=products,
        files={name: gate.m0.digest(root / name) for name in ('binaries/example', 'binaries/main.jsbundle', 'Info.plist')},
        buildLogs={'build.log': gate.m0.digest(root / 'build-logs/build.log')}))
    common.write_json(root / 'environment.json', dict(simulatorID='sim', simulatorRuntimeID='ios-27', simulatorOS='27.0',
        simulatorBuild='synthetic', xcodeVersion='27.1'))
    common.write_json(root / 'cleanup.json', dict(simulatorID='sim', deleted=True, absentFromInventory=True, globalEnvironmentUnchanged=True))
    common.write_json(root / 'commands.json', dict(steps=[dict(phase=phase, exitCode=0) for phase in
        ('verify-built-signature', 'read-host-entitlements', 'install', 'app-data')]))
    rows, control, manifest = sample()
    (root / 'direct-control.json').write_text(json.dumps(control, indent=2) + '\n')
    common.write_trace(root, gate.NAME, rows)
    common.change_json(root, gate.NAME + '.receipt.json', lambda value: value.update(runID='run', simulatorID='sim'))
    manifest.update(schemaVersion=1, scenario='sdk-m3-direct', delivery=gate.DELIVERY, ownsSimulator=True,
        runtimeInjectionRequested=False, directIngressInjectionRequested=True, **identity,
        files={name: gate.m0.digest(root / name) for name in gate.FILES},
        installed={key: gate.m0.digest(root / name) for key, name in [('executableSHA256', 'binaries/example'),
            ('javascriptSHA256', 'binaries/main.jsbundle'), ('infoPlistSHA256', 'Info.plist')]})
    for name, key in [('input-build-receipt.json', 'inputBuildReceiptSHA256'), ('cleanup.json', 'cleanupSHA256'),
                      ('commands.json', 'commandsSHA256'), ('environment.json', 'environmentSHA256')]:
        manifest[key] = gate.m0.digest(root / name)
    common.write_json(root / 'manifest.json', manifest)


class Controls(unittest.TestCase):
    def test_actual_direct_statements_against_public_simulator_interfaces(self):
        root = Path(__file__).resolve().parent.parent
        source = (root / 'example/modules/journey/apple/VoIPExampleJourneyModule.swift').read_text()
        start = source.index('    let tel = URL(string: "tel:+15555550142")!')
        end = source.index('    finish(success: true)', start)
        # Typecheck the exact production statements and real SDK entry points;
        # only fixture tracing/wait bookkeeping is substituted. No app is run.
        program = '''
import CryptoKit
import Intents
import UIKit
private enum JourneyError: Error { case invalidPayload }
@MainActor private enum JourneyTrace { static func record(_ event: String, _ fields: [String: Any]) {} }
@MainActor final class Control {
  var directDialObservations = 0
  static func digest(_ value: String) -> String { "typecheck only" }
  func waitUntil(_ condition: @MainActor () -> Bool) async throws {}
  func check() async throws {
''' + source[start:end] + '''
  }
}
'''
        with tempfile.TemporaryDirectory(prefix='sdk-m3-direct-interfaces-') as directory:
            output = Path(directory); code = output / 'Control.swift'; code.write_text(program)
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
            result = subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '6', '-warnings-as-errors',
                '-parse-as-library', '-sdk', sdk, '-target', 'arm64-apple-ios17.4-simulator',
                '-module-cache-path', str(output / 'cache'),
                str(root / 'Sources/VoIPSDK/DialRequest.swift'), str(root / 'Sources/VoIPSDK/DialRequest+Intents.swift'),
                str(root / 'Sources/VoIPSDK/VoIPSystemEntryPoints.swift'), str(code)],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_native_control_identity_parser(self):
        program = '''
import Foundation
@main struct Control {
  static func main() throws {
    let valid = "{\\"schemaVersion\\":1,\\"runID\\":\\"run\\",\\"simulatorID\\":\\"sim\\",\\"appPID\\":123,\\"delivery\\":\\"direct-url-and-intent\\"}"
    func accepts(_ string: String, run: String = "run", sim: String = "sim", pid: Int32 = 123) -> Bool {
      M3DirectControl.matches(Data(string.utf8), runID: run, simulatorID: sim, pid: pid)
    }
    precondition(accepts(valid))
    precondition(!accepts(valid, run: "other")); precondition(!accepts(valid, sim: "other"))
    precondition(!accepts(valid, pid: 456)); precondition(!accepts("[]")); precondition(!accepts("not JSON"))
    precondition(!accepts(valid.replacingOccurrences(of: "\\"schemaVersion\\":1", with: "\\"schemaVersion\\":true")))
    precondition(!accepts(valid.replacingOccurrences(of: "\\"schemaVersion\\":1", with: "\\"schemaVersion\\":1.0")))
    precondition(!accepts(valid.replacingOccurrences(of: "\\"appPID\\":123", with: "\\"appPID\\":123.0")))
    precondition(!accepts(valid.replacingOccurrences(of: "\\"appPID\\":123", with: "\\"appPID\\":123.5")))
    precondition(!accepts(valid.replacingOccurrences(of: "direct-url-and-intent", with: "os")))
    precondition(!accepts(valid.replacingOccurrences(of: "}", with: ",\\"url\\":\\"tel:private\\"}")))
  }
}
'''
        source = Path(__file__).resolve().parent.parent / 'example/modules/journey/apple/M3DirectControl.swift'
        with tempfile.TemporaryDirectory(prefix='sdk-m3-direct-parser-') as directory:
            root = Path(directory); code = root / 'Control.swift'; code.write_text(program)
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-module-cache-path', str(root / 'cache'), str(source), str(code), '-o', str(root / 'control')],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / 'control')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_runner_direct_control_and_no_os_dispatch(self):
        result, summary = os_controls.Controls().run_capture(direct_rows=sample()[0])
        self.assertEqual(result, 0, summary)
        self.assertEqual(summary['publicDialRequests'], 2)

    def test_direct_runner_missing_receipt_stays_red_and_cleans(self):
        result, summary = os_controls.Controls().run_capture(direct_rows=sample()[0], omit_receipt=True)
        self.assertEqual(result, 1)
        self.assertFalse(summary['success'])

    def test_direct_runner_term_stays_red_and_cleans(self):
        result, summary = os_controls.Controls().run_capture(direct_rows=sample()[0], terminate_during_boot=True)
        self.assertEqual(result, 1)
        self.assertFalse(summary['success'])

    def check_rows(self, edit=None):
        rows, control, manifest = sample()
        if edit is None:
            self.assertEqual(gate.qualify(rows, control, manifest, 123)['publicDialRequests'], 2)
        else:
            edit(rows, control, manifest)
            with self.assertRaises((EvidenceError, KeyError, TypeError, StopIteration)):
                gate.qualify(rows, control, manifest, 123)

    def check_capture(self, edit=None):
        with tempfile.TemporaryDirectory(prefix='sdk-m3-direct-controls-') as directory:
            root = Path(directory); fixture(root)
            if edit: edit(root)
            with patch.object(gate.m0, 'source_identity', return_value=common.IDENTITY), \
                 patch.object(gate.m0.subprocess, 'run', side_effect=AssertionError('native command forbidden')):
                if edit is None: self.assertTrue(gate.validate(root)['success'])
                else:
                    with self.assertRaises((EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration)):
                        gate.validate(root)

    def test_positive_direct_public_roundtrips(self):
        self.check_rows(); self.check_capture()

    def test_both_public_events_required(self):
        self.check_rows(lambda rows, *_: rows.remove(next(r for r in rows if r['event'] == 'm3.dialRequest')))
        self.check_rows(lambda rows, *_: rows.append(copy.deepcopy(next(r for r in rows if r['event'] == 'm3.dialRequest'))))

    def test_actual_url_subscriber_and_typed_intent_required(self):
        for event in ('m3.nativeIngress', 'm3.directIntentEntered'):
            self.check_rows(lambda rows, *_, event=event: rows.remove(next(r for r in rows if r['event'] == event)))
        self.check_rows(lambda rows, *_: next(r for r in rows if r['event'] == 'm3.directDelivery').update(method='private-router'))

    def test_direct_never_qualifies_original_os_gate(self):
        rows, _, _ = sample()
        _, dispatch = os_controls.sample()
        with self.assertRaises(EvidenceError): gate.os_gate.qualify(rows, dispatch, 'run', 'sim', 123)
        self.check_capture(lambda root: common.change_json(root, 'manifest.json', lambda m: m.update(directIngressInjectionRequested=False)))

    def test_payload_order_and_zero_conversations(self):
        for key, value in (('video', False), ('conversationCount', 1), ('handleSHA256', '0' * 64)):
            self.check_rows(lambda rows, *_, key=key, value=value: [r for r in rows if r['event'] == 'm3.dialRequest'][1].update({key: value}))
        self.check_rows(lambda rows, *_: next(r for r in rows if r['event'] == 'sdk.snapshot').update(conversations=[{}]))
        self.check_rows(lambda rows, *_: next(r for r in rows if r['event'] == 'm3.directDeliveryReturned').update(handled=False))

    def test_exact_scalar_protocol(self):
        for key, value in (('pid', 123.0), ('sequence', True), ('t_ms', 0.0), ('wallTimeMS', True)):
            self.check_rows(lambda rows, *_, key=key, value=value: rows[0].update({key: value}))
        for value in (True, 1.0):
            self.check_rows(lambda rows, control, manifest, value=value: control.update(schemaVersion=value))
        self.check_rows(lambda rows, *_: next(r for r in rows if r['event'] == 'm3.dialRequest').update(conversationCount=False))

    def test_listener_control_and_privacy(self):
        self.check_rows(lambda rows, control, manifest: manifest.update(directControlCreatedWallTimeMS=0))
        self.check_rows(lambda rows, *_: next(r for r in rows if r['event'] == 'm3.directControl').update(controlSHA256='0' * 64))
        self.check_rows(lambda rows, *_: rows[0].update(payload='private'))
        self.check_rows(lambda rows, control, manifest: control.update(appPID=456))

    def test_source_build_install_and_supervisor_binding(self):
        for name, key in [('input-build-receipt.json', 'inputBuildReceiptSHA256'), ('cleanup.json', 'cleanupSHA256'),
                          ('direct-control.json', 'directControlSHA256')]:
            self.check_capture(lambda root, name=name: (root / name).write_text('{}'))
        self.check_capture(lambda root: (root / (gate.NAME + '.receipt.json')).unlink())
        self.check_capture(lambda root: common.change_bound_json(root, 'commands.json', 'commandsSHA256',
            lambda c: c['steps'][0].update(exitCode=False)))
        self.check_capture(lambda root: common.change_bound_json(root, 'commands.json', 'commandsSHA256',
            lambda c: c['steps'].append(dict(phase='os-tel-dispatch', exitCode=0))))
        def change_info(root):
            value = plistlib.loads((root / 'Info.plist').read_bytes()); value['CFBundleIdentifier'] = 'other'
            (root / 'Info.plist').write_bytes(plistlib.dumps(value))
            common.change_json(root, 'manifest.json', lambda m: m['files'].update({'Info.plist': gate.m0.digest(root / 'Info.plist')}))
        self.check_capture(change_info)


if __name__ == '__main__':
    unittest.main()
