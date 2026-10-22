#!/usr/bin/env python3
"""A9 simulator direct-delivery acceptance; never qualifies OS default dispatch."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib

import sdk_m0_conformance as m0
import sdk_m3_conformance as os_gate
from summarize import EvidenceError, one, require

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = os_gate.BUNDLE
NAME = 'sdk-m3-direct'
FILES = os_gate.FILES
DELIVERY = 'direct-url-and-intent'
STEPS = (
    ('url', 'UIApplicationDelegate.application(open:options:)', os_gate.URL, os_gate.HANDLE, False),
    ('intent', 'VoIPSystemEntryPoints.handle(intent:)', '+15555550143', '+15555550143', True),
)
check_input_build = os_gate.check_input_build
simulated_entitlements = os_gate.simulated_entitlements


def qualify(rows, control, manifest, pid):
    require(type(pid) is int and pid > 0 and rows and
            all(type(row.get('pid')) is int and row.get('pid') == pid and row.get('main') is True and
                row.get('runID') == manifest['runID'] and row.get('simulatorID') == manifest['simulatorID'] and
                row.get('bundleID') == BUNDLE for row in rows), 'mixed direct-delivery process/queue identity')
    require(all(type(row.get(key)) is int for row in rows for key in ('sequence', 't_ms', 'wallTimeMS')) and
            [row['sequence'] for row in rows] == list(range(1, len(rows) + 1)) and
            all(a['t_ms'] <= b['t_ms'] and a['wallTimeMS'] <= b['wallTimeMS'] for a, b in zip(rows, rows[1:])),
            'invalid direct-delivery sequence/clock')
    require([row['event'] for row in rows[:2]] == ['app.entry', 'launch'] and
            one(rows, 'launch').get('mode') == 'sdk-m3-direct' and
            type(one(rows, 'launch').get('traceVersion')) is int and one(rows, 'launch')['traceVersion'] == 2,
            'missing explicit direct-delivery launch')
    require(isinstance(control, dict) and set(control) == {'schemaVersion', 'runID', 'simulatorID', 'appPID', 'delivery'} and
            type(control.get('schemaVersion')) is int and control['schemaVersion'] == 1 and
            control.get('runID') == manifest['runID'] and control.get('simulatorID') == manifest['simulatorID'] and
            type(control.get('appPID')) is int and control['appPID'] == pid and control.get('delivery') == DELIVERY,
            'direct control is not bound to this process and mode')
    ready, accepted = one(rows, 'm3.listenerReady'), one(rows, 'm3.directControl')
    created = manifest.get('directControlCreatedWallTimeMS')
    require(type(created) is int and ready['wallTimeMS'] <= created <= accepted['wallTimeMS'] + 2 and
            accepted.get('controlSHA256') == manifest.get('directControlSHA256') and
            rows.index(ready) < rows.index(accepted), 'direct delivery preceded actual public listener/control')
    require(all(type(row.get('conversationCount')) is int and row['conversationCount'] == 0 for row in (ready, accepted)),
            'direct delivery started with a conversation')
    starts = [row for row in rows if row['event'] == 'm3.directDelivery']
    returned = [row for row in rows if row['event'] == 'm3.directDeliveryReturned']
    events = [row for row in rows if row['event'] == 'm3.dialRequest']
    require(len(starts) == len(returned) == len(events) == 2, 'missing or duplicate direct/public delivery')
    ingress, intent = one(rows, 'm3.nativeIngress'), one(rows, 'm3.directIntentEntered')
    require(ingress.get('kind') == 'url' and ingress.get('urlSHA256') == hashlib.sha256(os_gate.URL.encode()).hexdigest(),
            'URL did not reach the actual application-delegate subscriber')
    require(intent.get('isStartCallIntent') is True, 'missing resolved typed start-call intent')
    last = rows.index(accepted)
    for index, (kind, method, raw, handle, video) in enumerate(STEPS):
        start, result, event = starts[index], returned[index], events[index]
        require(start.get('kind') == result.get('kind') == kind and start.get('method') == method and
                start.get('inputSHA256') == hashlib.sha256(raw.encode()).hexdigest() and result.get('handled') is True,
                'substituted direct entry point or rejected delivery')
        middle = ingress if kind == 'url' else intent
        require(last < rows.index(start) < rows.index(middle) < rows.index(event) and
                rows.index(start) < rows.index(result) < rows.index(events[index + 1] if index == 0 else one(rows, 'sdk.result')),
                'direct entry/public event order differs')
        require(type(event.get('conversationCount')) is int and event['conversationCount'] == 0 and
                event.get('handleSHA256') == hashlib.sha256(handle.encode()).hexdigest() and event.get('video') is video,
                'public direct destination/video differs or routing created a conversation')
        last = max(rows.index(event), rows.index(result))
    snapshots = [row for row in rows if row['event'] == 'sdk.snapshot']
    require(last < rows.index(one(rows, 'sdk.result')) < rows.index(one(rows, 'done')) == len(rows) - 1 and
            one(rows, 'sdk.result').get('success') is True and one(rows, 'sdk.activation').get('active') is True and
            one(rows, 'sdk.managerCreated').get('owner') == 'ConversationClient.shared' and
            snapshots and all(row.get('conversations') == [] for row in snapshots),
            'direct journey failed or created a conversation')
    require(not any(row.get('error') or row.get('errorType') for row in rows) and
            not any(key in row for row in rows for key in ('handle', 'url', 'token', 'value', 'payload', 'caller')),
            'direct journey failed or disclosed private input')
    return dict(success=True, scenario='sdk-m3-direct', delivery=DELIVERY, publicDialRequests=2,
                defaultCallingDispatch='not measured by direct delivery')


def validate(root, source_root=ROOT):
    manifest = json.loads((root / 'manifest.json').read_text())
    identity = m0.source_identity(source_root)
    require(type(manifest.get('schemaVersion')) is int and manifest['schemaVersion'] == 1 and
            manifest.get('scenario') == 'sdk-m3-direct' and manifest.get('delivery') == DELIVERY and
            manifest.get('ownsSimulator') is True and manifest.get('runtimeInjectionRequested') is False and
            manifest.get('directIngressInjectionRequested') is True and
            all(manifest.get(key) == value for key, value in identity.items()), 'invalid explicit direct-delivery source/ownership')
    build = json.loads((root / 'input-build-receipt.json').read_text())
    require(m0.digest(root / 'input-build-receipt.json') == manifest.get('inputBuildReceiptSHA256') and
            type(build.get('schemaVersion')) is int and build['schemaVersion'] == 1 and build.get('product') == 'sdk-m3' and
            build.get('configuration') == 'Release' and build.get('mediaAdapter') == 'none' and
            build.get('sourceStart') == build.get('sourceEnd') == identity and
            all(build.get(key) == value for key, value in identity.items()), 'direct input build is not source-bound')
    require(manifest.get('files') == {name: m0.digest(root / name) for name in FILES} and
            all(build.get('files', {}).get(name) == m0.digest(root / name) for name in
                ('binaries/example', 'binaries/main.jsbundle', 'Info.plist')) and
            manifest.get('installed') == {key: m0.digest(root / name) for key, name in
                [('executableSHA256', 'binaries/example'), ('javascriptSHA256', 'binaries/main.jsbundle'), ('infoPlistSHA256', 'Info.plist')]},
            'direct built/installed bytes differ')
    host = plistlib.loads((root / 'host-entitlements.plist').read_bytes())
    require((root / 'simulated-entitlements.plist').read_bytes() == simulated_entitlements(root / 'binaries/example') and
            isinstance(host, dict) and not {'com.apple.developer.calling-app', 'com.apple.developer.dialing-app'} & host.keys(),
            'simulator claim was substituted or added to the host signature')
    claims = plistlib.loads((root / 'simulated-entitlements.plist').read_bytes())
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == BUNDLE and 'voip' in info.get('UIBackgroundModes', []) and
            claims.get('com.apple.developer.calling-app') is True and 'com.apple.developer.dialing-app' not in claims and
            not any(scheme.lower() == 'tel' for row in info.get('CFBundleURLTypes', []) for scheme in row.get('CFBundleURLSchemes', [])),
            'direct example eligibility/declaration differs')
    require(build.get('settingsProducts') == os_gate.product_files(root / 'settings/products'),
            'retained UI products differ from the unchanged shared build')
    require(build.get('buildLogs') and all(Path(name).name == name and (root / 'build-logs' / name).stat().st_size > 0 and
            m0.digest(root / 'build-logs' / name) == digest for name, digest in build['buildLogs'].items()),
            'missing, empty or unbound direct build log')
    cleanup = json.loads((root / 'cleanup.json').read_text())
    require(m0.digest(root / 'cleanup.json') == manifest.get('cleanupSHA256') and
            cleanup.get('simulatorID') == manifest.get('simulatorID') and cleanup.get('deleted') is True and
            cleanup.get('absentFromInventory') is True and cleanup.get('globalEnvironmentUnchanged') is True,
            'direct owned cleanup/environment preservation did not complete')
    require(m0.digest(root / 'commands.json') == manifest.get('commandsSHA256') and
            m0.digest(root / 'environment.json') == manifest.get('environmentSHA256') and
            m0.digest(root / 'direct-control.json') == manifest.get('directControlSHA256'), 'unbound direct control/environment')
    environment = json.loads((root / 'environment.json').read_text())
    require(environment.get('simulatorID') == manifest['simulatorID'] and
            all(isinstance(environment.get(key), str) and environment[key] for key in
                ('simulatorRuntimeID', 'simulatorOS', 'simulatorBuild', 'xcodeVersion')), 'missing direct execution environment')
    commands = json.loads((root / 'commands.json').read_text())['steps']
    for phase in ('verify-built-signature', 'read-host-entitlements', 'install', 'app-data'):
        matches = [row for row in commands if row.get('phase') == phase]
        require(len(matches) == 1 and type(matches[0].get('exitCode')) is int and matches[0]['exitCode'] == 0,
                'direct control failed: ' + phase)
    require(not any(row.get('phase') in ('os-tel-dispatch', 'select-calling-app') for row in commands),
            'OS/Settings execution cannot be relabeled direct delivery')
    rows, receipt = m0.bound_rows(root, NAME, manifest, BUNDLE)
    result = qualify(rows, json.loads((root / 'direct-control.json').read_text()), manifest, receipt['appPID'])
    return dict(**result, source=identity, installed=manifest['installed'])


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
