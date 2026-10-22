#!/usr/bin/env python3
"""Require real OS tel dispatch, native ingress and the public example event."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib

import sdk_m0_conformance as m0
from summarize import EvidenceError, one, require

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'dev.iosvoipsdk.example'
URL = 'tel:+15555550142'
HANDLE = '+15555550142'
NAME = 'sdk-m3-tel'
FILES = ('binaries/unsigned-example', 'binaries/example', 'binaries/main.jsbundle',
         'Info.plist', 'signed-entitlements.plist')


def qualify(rows, dispatch, run_id, simulator_id, pid):
    require(rows and all(row.get('runID') == run_id and row.get('simulatorID') == simulator_id and
                        row.get('pid') == pid and row.get('main') is True and row.get('bundleID') == BUNDLE
                        for row in rows), 'mixed M3 process/queue identity')
    require([row.get('sequence') for row in rows] == list(range(1, len(rows) + 1)) and
            all(type(row.get('t_ms')) is int and type(row.get('wallTimeMS')) is int for row in rows) and
            all(a['t_ms'] <= b['t_ms'] and a['wallTimeMS'] <= b['wallTimeMS'] for a, b in zip(rows, rows[1:])),
            'invalid M3 sequence/clock')
    require([row['event'] for row in rows[:2]] == ['app.entry', 'launch'] and
            one(rows, 'launch').get('mode') == 'sdk-m3' and one(rows, 'launch').get('traceVersion') == 2,
            'missing M3 app entry/mode')
    ready, ingress, event = (one(rows, name) for name in ('m3.listenerReady', 'm3.nativeIngress', 'm3.dialRequest'))
    require(dispatch.get('schemaVersion') == 1 and dispatch.get('runID') == run_id and
            dispatch.get('simulatorID') == simulator_id and dispatch.get('appPID') == pid and
            dispatch.get('argv') == ['xcrun', 'simctl', 'openurl', simulator_id, URL] and
            dispatch.get('exitCode') == 0, 'missing or substituted OS URL dispatch')
    start, end = dispatch.get('startedWallTimeMS'), dispatch.get('finishedWallTimeMS')
    require(type(start) is int and type(end) is int and ready['wallTimeMS'] <= start <= end and
            start - 2 <= ingress['wallTimeMS'] <= end + 15_000,
            'native ingress does not follow the recorded OS dispatch')
    require((ingress.get('kind') == 'url' and ingress.get('urlSHA256') == hashlib.sha256(URL.encode()).hexdigest()) or
            (ingress.get('kind') == 'activity' and ingress.get('isStartCallIntent') is True),
            'native ingress is not a tel URL or public start-call activity')
    require(rows.index(ready) < rows.index(ingress) < rows.index(event) < rows.index(one(rows, 'sdk.result')) <
            rows.index(one(rows, 'done')) == len(rows) - 1, 'M3 readiness/ingress/public event order differs')
    require(ready.get('conversationCount') == event.get('conversationCount') == 0 and
            event.get('handleSHA256') == hashlib.sha256(HANDLE.encode()).hexdigest() and event.get('video') is False,
            'public dialRequest destination/video changed or routing created a call')
    require(one(rows, 'sdk.result').get('success') is True and
            not any(row.get('error') or row.get('errorType') for row in rows) and
            not any(key in row for row in rows for key in ('handle', 'url', 'token', 'value', 'payload', 'caller')),
            'M3 failed or disclosed private input')
    return dict(success=True, scenario='sdk-m3', nativeIngress=ingress['kind'], publicDialRequest=True)


def check_input_build(app, receipt, identity=None):
    identity = m0.source_identity() if identity is None else identity
    require(receipt.get('schemaVersion') == 1 and receipt.get('sourceStart') == identity and
            all(receipt.get(key) == value for key, value in identity.items()) and
            receipt.get('files', {}).get('binaries/example') == m0.digest(m0.executable(app)) and
            receipt.get('files', {}).get('binaries/main.jsbundle') == m0.digest(app / 'main.jsbundle'),
            'M3 example does not match committed build-time source and bytes')


def validate(root, source_root=ROOT):
    manifest = json.loads((root / 'manifest.json').read_text())
    identity = m0.source_identity(source_root)
    require(manifest.get('schemaVersion') == 1 and manifest.get('scenario') == 'sdk-m3' and
            manifest.get('ownsSimulator') is True and manifest.get('runtimeInjectionRequested') is False and
            manifest.get('directIngressInjectionRequested') is False and
            all(manifest.get(key) == value for key, value in identity.items()), 'invalid M3 source/ownership manifest')
    build = json.loads((root / 'input-build-receipt.json').read_text())
    require(m0.digest(root / 'input-build-receipt.json') == manifest.get('inputBuildReceiptSHA256') and build.get('schemaVersion') == 1 and
            build.get('sourceStart') == identity and all(build.get(key) == value for key, value in identity.items()),
            'input build is not source-bound')
    require(manifest.get('files') == {name: m0.digest(root / name) for name in FILES} and
            build.get('files', {}).get('binaries/example') == m0.digest(root / 'binaries/unsigned-example') and
            build.get('files', {}).get('binaries/main.jsbundle') == m0.digest(root / 'binaries/main.jsbundle'),
            'M3 unsigned/signed build bytes are unbound')
    require(manifest.get('installed') == {key: m0.digest(root / name) for key, name in
            [('executableSHA256', 'binaries/example'), ('javascriptSHA256', 'binaries/main.jsbundle'), ('infoPlistSHA256', 'Info.plist')]},
            'installed M3 example bytes differ')
    plist = plistlib.loads((root / 'Info.plist').read_bytes())
    entitlements = plistlib.loads((root / 'signed-entitlements.plist').read_bytes())
    require(plist.get('CFBundleIdentifier') == BUNDLE and 'voip' in plist.get('UIBackgroundModes', []) and
            'INStartCallIntent' in plist.get('NSUserActivityTypes', []) and
            not any(scheme.lower() == 'tel' for row in plist.get('CFBundleURLTypes', []) for scheme in row.get('CFBundleURLSchemes', [])) and
            entitlements.get('com.apple.developer.calling-app') is True and
            'com.apple.developer.dialing-app' not in entitlements, 'M3 default-calling eligibility differs')
    cleanup = json.loads((root / 'cleanup.json').read_text())
    require(m0.digest(root / 'cleanup.json') == manifest.get('cleanupSHA256') and
            cleanup.get('simulatorID') == manifest.get('simulatorID') and cleanup.get('deleted') is True and
            cleanup.get('globalEnvironmentUnchanged') is True,
            'M3 owned simulator cleanup did not complete')
    require(m0.digest(root / 'dispatch.json') == manifest.get('dispatchSHA256') and
            m0.digest(root / 'environment.json') == manifest.get('environmentSHA256'), 'unbound M3 dispatch/environment')
    environment = json.loads((root / 'environment.json').read_text())
    require(environment.get('simulatorID') == manifest.get('simulatorID') and
            all(isinstance(environment.get(key), str) and environment[key] for key in
                ('simulatorRuntimeID', 'simulatorOS', 'simulatorBuild', 'xcodeVersion')) and
            tuple(int(part) for part in environment['simulatorOS'].split('.')[:2]) >= (18, 2), 'invalid M3 execution environment')
    require(m0.digest(root / 'commands.json') == manifest.get('commandsSHA256'), 'unbound M3 control commands')
    commands = json.loads((root / 'commands.json').read_text())['steps']
    for phase in ('sign-owned-copy', 'verify-owned-signature', 'read-signed-entitlements', 'install', 'os-tel-dispatch'):
        matches = [row for row in commands if row.get('phase') == phase]
        require(len(matches) == 1 and matches[0].get('exitCode') == 0, 'M3 control failed: ' + phase)
    if 'selectionObservationSHA256' in manifest:
        require(m0.digest(root / 'selection-observation.json') == manifest['selectionObservationSHA256'], 'unbound Settings observation')
        selection = json.loads((root / 'selection-observation.json').read_text())
        require(selection.get('runID') == manifest['runID'] and selection.get('simulatorID') == manifest['simulatorID'] and
                selection.get('method') == 'public-settings-ui' and selection.get('selected') is True,
                'Settings observation does not match this run')
    rows, receipt = m0.bound_rows(root, NAME, manifest, BUNDLE)
    result = qualify(rows, json.loads((root / 'dispatch.json').read_text()), manifest['runID'], manifest['simulatorID'], receipt['appPID'])
    return dict(**result, source=identity, installed=manifest['installed'], defaultSelection='UI eligibility/selection is separate setup evidence')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.root)
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['success'] else 1)
