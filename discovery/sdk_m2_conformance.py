#!/usr/bin/env python3
"""Qualify source-bound selected-LiveKit journeys; no M0 rerun is required.

The native watchdog episode measures absence, its two public events, and clean
termination. Exactly one recovery is proved separately by the source-bound
host controls. Native liveness starts at pre-fulfillment recording demand,
which is not the watchdog's unrecorded start; this capture does not measure the
exact activation interval or count AVAudioSession configuration calls.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import uuid

import sdk_m0_conformance as m0
from sdk_m1_conformance import projected
from summarize import EvidenceError, one, require

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = 'dev.iosvoipsdk.example'
CONTRACTS = 'dev.iosvoipsdk.m1contracts'
CASES = ('livekit', 'stale-audio', 'media-reentrancy')
PRODUCT_FILES = ('binaries/example', 'binaries/main.jsbundle', 'binaries/contracts', 'binaries/cksim-notify',
                 'binaries/livekit-webrtc', 'products/LiveKitWebRTC.Info.plist',
                 'products/Podfile.lock', 'products/Podfile.properties.json', 'products/Info.plist',
                 'products/ios-27.0.json', 'products/versions.json', 'products/IosVoipSDK.podspec.json',
                 'products/contracts-build-info.json')
CONTROL_SUFFIXES = ('.session.json', '.control.request.json', '.control.response.json',
                    '.control-ready.json', '.control-binding.json')
VERSIONS = {'@livekit/react-native': '3.1.0', '@livekit/react-native-webrtc': '150.1.0',
            'livekit-client': '2.23.0', 'react-dom': '19.3.0'}
HOST_CHECKS = (
    'finite-positive-policy', 'default-activation-and-final-recovery-deadlines',
    'caller-configured-activation-and-recovery-intervals', 'healthy-activation-cancels-watchdog',
    'hold-cancels-resume-starts-a-new-absence', 'multicall-demand-preserves-deadline-and-current-ids',
    'suspended-recovery-cannot-delay-clean-end', 'real-activation-invalidates-final-and-late-recovery',
    'stale-call-timers-cannot-end-a-new-call', 'reset-clears-demand-without-synthetic-audio-events',
    'missing-observer-reentrancy-skips-stale-recovery', 'failed-observer-reentrancy-skips-stale-end',
    'end-callback-may-start-a-fresh-episode', 'replacement-demand-without-empty-gap-gets-new-watchdog',
    'suspended-adapter-preparation-orders-callbacks-and-errors', 'route-hydration-and-explicit-null-current',
    'duplicate-routes-and-unchanged-updates-preserve-revision', 'reentrant-route-observers-receive-monotonic-revisions',
    'observed-native-routes-map-to-speaker-and-preferred-input',
    'inactive-stale-and-backend-route-errors-have-no-state-effects',
    'unmatched-current-output-is-observed-without-inventing-selectable-outputs')

digest = m0.digest


def source_identity(root=ROOT):
    # M0's shared source inventory includes these standalone M2 scripts, their
    # workflow and notifier. Reuse its clean-source calculation, not its gate.
    return m0.source_identity(root)


def read(root, name):
    return json.loads((root / name).read_text())


def exact(value, expected):
    """Compare protocol data without Python's bool/int or int/float coercion."""
    if type(value) is not type(expected): return False
    if isinstance(expected, dict):
        return value.keys() == expected.keys() and all(exact(value[k], v) for k, v in expected.items())
    if isinstance(expected, (list, tuple)):
        return len(value) == len(expected) and all(exact(a, b) for a, b in zip(value, expected))
    return value == expected


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)).upper() == value.upper()
    except (ValueError, AttributeError):
        return False


def products(root):
    require(all((root / name).is_file() and (root / name).stat().st_size > 0 for name in PRODUCT_FILES),
            'missing or empty M2 product')
    return {name: digest(root / name) for name in PRODUCT_FILES}


def validate_build(root, identity, require_apps=True):
    """Refuse stale build products before the runner creates any simulator."""
    info = read(root, 'build-info.json')
    files = products(root)
    require(type(info.get('schemaVersion')) is int and info['schemaVersion'] == 1 and info.get('product') == 'sdk-m2' and
            info.get('configuration') == 'Release' and info.get('contractsConfiguration') == 'Debug' and
            info.get('mediaAdapter') == 'livekit' and info.get('sourceStart') == info.get('sourceEnd') == identity and
            all(info.get(k) == v for k, v in identity.items()) and info.get('files') == files,
            'M2 build source/configuration/products differ')
    require(read(root, 'source-before.json') == read(root, 'source-after.json') == identity,
            'M2 build source start/end differ')
    require(read(root, 'products/versions.json') == VERSIONS, 'selected NPM versions differ')
    lock = (root / 'products/Podfile.lock').read_text()
    for pod, version in (('livekit-react-native', '3.1.0'), ('livekit-react-native-webrtc', '150.1.0'),
                         ('LiveKitWebRTC', '150.7871.03')):
        require(f'  - {pod} ({version})' in lock, 'selected Pod version differs: ' + pod)
    require(read(root, 'products/Podfile.properties.json').get('ios-voip-sdk.mediaAdapter') == 'livekit',
            'generated adapter selection differs')
    native = plistlib.loads((root / 'products/Info.plist').read_bytes())
    framework = plistlib.loads((root / 'products/LiveKitWebRTC.Info.plist').read_bytes())
    require(framework.get('CFBundleIdentifier') == 'io.livekit.LiveKitWebRTC' and
            framework.get('CFBundleExecutable') == 'LiveKitWebRTC' and
            all(isinstance(framework.get(k), str) and framework[k] for k in
                ('CFBundleShortVersionString', 'CFBundleVersion')), 'embedded LiveKit framework metadata differs')
    config = native.get('VoIPSDK', {})
    require(native.get('CFBundleIdentifier') == EXAMPLE and config.get('mediaAdapter') == 'livekit' and
            config.get('simulatorSupport') is True and {'voip', 'audio'} <= set(native.get('UIBackgroundModes', [])) and
            isinstance(native.get('NSMicrophoneUsageDescription'), str) and native['NSMicrophoneUsageDescription'].strip(),
            'selected native launch/audio/permission configuration missing')
    spec = read(root, 'products/IosVoipSDK.podspec.json')
    sources = spec.get('source_files', [])
    require(sources == ['Sources/**/*.{swift,h,m}', 'Expo/apple/**/*.{swift,h}',
            'ExpoMedia/Shared/ExpoMediaSupport.swift', 'ExpoMedia/LiveKit/**/*.{swift,h,m}',
            'ExpoMedia/Shared/VSMediaBinding.h', 'ExpoMedia/Shared/QueuedMediaAdapter.swift'],
            'Podspec does not select only the LiveKit branch and shared bridge')
    deps = spec.get('dependencies', {})
    require(deps.get('livekit-react-native-webrtc') == ['>= 150.1.0', '< 151.0.0'] and
            'react-native-webrtc' not in deps, 'Podspec media dependency differs')
    contract = read(root, 'products/contracts-build-info.json')
    require(type(contract.get('schemaVersion')) is int and contract['schemaVersion'] == 1 and contract.get('product') == 'sdk-m1-contracts' and
            contract.get('configuration') == 'Debug' and contract.get('sourceDirty') is False and
            contract.get('sourceCommit') == identity['sourceCommit'] and
            contract.get('files', {}).get('SDKM1Contracts.app/SDKM1Contracts') == files['binaries/contracts'] and
            contract['files'].get('SDKM1Contracts.app/IosVoipSDKRuntime.bundle/ios-27.0.json') ==
            files['products/ios-27.0.json'], 'Debug contract product/source binding differs')
    if require_apps:
        for name, bundle in (('example', EXAMPLE), ('contracts', CONTRACTS)):
            app = root / ('apps/' + name + '.app')
            require(plistlib.loads((app / 'Info.plist').read_bytes()).get('CFBundleIdentifier') == bundle and
                    digest(m0.executable(app)) == files['binaries/' + name], 'install app executable differs: ' + name)
            profiles = list(app.rglob('IosVoipSDKRuntime.bundle/ios-27.0.json'))
            require(len(profiles) == 1 and digest(profiles[0]) == files['products/ios-27.0.json'],
                    'install app runtime profile differs: ' + name)
        app = root / 'apps/example.app'
        require(digest(app / 'main.jsbundle') == files['binaries/main.jsbundle'] and
                digest(app / 'Info.plist') == files['products/Info.plist'], 'install example JS/Info differs')
        framework = app / 'Frameworks/LiveKitWebRTC.framework'
        require(digest(framework / 'LiveKitWebRTC') == files['binaries/livekit-webrtc'] and
                digest(framework / 'Info.plist') == files['products/LiveKitWebRTC.Info.plist'],
                'install embedded LiveKit framework differs')
    return info


def journal(root, name, manifest, receipt, bundle, version):
    path = root / (name + '.runtime.jsonl')
    require(path.stat().st_size > 0 and digest(path) == receipt.get('journalSHA256'), name + ': unbound journal')
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    require(rows and all(isinstance(r, dict) and isinstance(r.get('event'), str) and type(r.get('sequence')) is int and
            type(r.get('t_ms')) is int and r['t_ms'] >= 0 for r in rows) and
            [r.get('sequence') for r in rows] == list(range(1, len(rows) + 1)) and
            all(a['t_ms'] <= b['t_ms'] for a, b in zip(rows, rows[1:])), name + ': invalid journal sequence/time')
    require(all(r.get('runID') == manifest['runID'] and r.get('pid') == receipt['appPID'] and
                type(r.get('pid')) is int and r.get('bundleID') == bundle and r.get('profile') == 'ios-27.0'
                for r in rows), name + ': mixed journal identity')
    require(one(rows, 'runtime.installed').get('version') == version, name + ': wrong runtime version')
    provider = one(rows, 'provider.created').get('provider')
    require(isinstance(provider, str) and provider and
            not any(r['event'] in ('diagnostic.multipleProviders', 'action.timeout', 'provider.reset', 'audio.failed')
                    or r['event'].startswith('diagnostic.') for r in rows), name + ': runtime error/extra provider/timeout')
    require(all(r.get('provider') == provider for r in rows if r['event'] == 'transaction.delivered'),
            name + ': action routed elsewhere')
    return rows


def controls(root, name, case, manifest, receipt, rows):
    pid = receipt['appPID']
    session = read(root, name + '.session.json')
    require(exact(session, dict(schemaVersion=1, runID=manifest['runID'], pid=pid, bundleID=EXAMPLE,
                            profile='ios-27.0', notification=f'dev.callkitsim.control.{pid}')),
            case + ': runtime control session differs')
    request = read(root, name + '.control.request.json')
    require(valid_uuid(request.get('id')) and exact(request, dict(id=request['id'], runID=manifest['runID'], pid=pid,
            bundleID=EXAMPLE, operation='faults', faults=dict(staleAudio=case == 'stale-audio',
            reportCallbackDelayMS=0, invalidateDuringHandoff=False))), case + ': wrong or unbound fault command')
    response = read(root, name + '.control.response.json')
    require(exact(response, dict(id=request['id'], runID=manifest['runID'], pid=pid, bundleID=EXAMPLE,
                             success=True, result=dict(configured=True))), case + ': fault command not acknowledged')
    require(exact(read(root, name + '.control-ready.json'), dict(runID=manifest['runID'], case=case, pid=pid,
            staleAudio=case == 'stale-audio')), case + ': invalid control readiness file')
    require(exact(read(root, name + '.control-binding.json'), dict(runID=manifest['runID'], case=case, pid=pid,
            nonce=request['id'], requestSHA256=digest(root / (name + '.control.request.json')),
            responseSHA256=digest(root / (name + '.control.response.json')),
            readySHA256=digest(root / (name + '.control-ready.json')))), case + ': control digest/nonce differs')
    ready = one(rows, 'm2.controlReady')
    require(type(ready.get('staleAudio')) is bool and ready['staleAudio'] == (case == 'stale-audio') and
            rows.index(ready) < rows.index(one(rows, 'm2.pushInjected')), case + ': control not ready before push')


def trace_shape(rows, case):
    require([r['event'] for r in rows[:2]] == ['app.entry', 'launch'] and
            all(type(r.get('sequence')) is int for r in rows) and
            [r.get('sequence') for r in rows] == list(range(1, len(rows) + 1)) and
            all(type(r.get('wallTimeMS')) is int and r['wallTimeMS'] > 0 for r in rows), case + ': invalid process trace')
    require(type(one(rows, 'launch').get('traceVersion')) is int, case + ': invalid trace version type')
    require(not any(r.get('error') or r.get('errorType') or r['event'] in ('sdk.error', 'sdk.timeout', 'contract.warning')
                    for r in rows), case + ': native/JS failure')
    require(not any(any(k in r for k in ('token', 'value', 'payload', 'caller')) for r in rows), case + ': private data in trace')


def media_case(rows, engine, case, simulator_os):
    trace_shape(rows, case)
    launch = one(rows, 'launch')
    require(launch.get('mode') == 'sdk-m2' and launch.get('case') == case and launch.get('traceVersion') == 2,
            case + ': wrong example mode')
    require(one(rows, 'sdk.activation').get('active') is True and
            one(rows, 'sdk.managerCreated').get('owner') == 'ConversationClient.shared' and
            one(rows, 'm2.result').get('success') is True, case + ': SDK/result unavailable')
    labels = ['initial', 'demand'] + (['active', 'speaker', 'held', 'resumed', 'ended'] if case == 'livekit' else ['failed'])
    expected = ['initial-media', 'initial-same-engine', 'inactive-route-rejected', 'routes-observed',
                'push-ringing', 'one-local-audio-track', 'demand-media', 'demand-same-engine', 'joined',
                'backend-connected']
    for label in labels[2:]: expected.extend([label + '-media', label + '-same-engine'])
    expected.append('ended-empty-with-demand' if case == 'livekit' else 'stale-ended-empty-with-demand')
    assertions = [r for r in rows if r['event'] == 'm2.assertion']
    require([r.get('label') for r in assertions] == expected and all(r.get('passed') is True for r in assertions),
            case + ': assertion inventory/outcome differs')
    call = one(rows, 'm2.assertion', label='push-ringing').get('conversationID')
    require(valid_uuid(call) and all(r.get('conversationID') in (None, call) for r in rows), case + ': conversation identity differs')
    snapshots = projected(rows, call)
    samples = [r for r in rows if r['event'] == 'm2.mediaSnapshot']
    require([r.get('label') for r in samples] == labels, case + ': media stage inventory differs')
    identities = {(r.get('moduleID'), r.get('deviceID')) for r in samples}
    require(len(identities) == 1 and all(isinstance(v, str) and v for v in next(iter(identities))),
            case + ': existing media object identity changed/missing')
    counters = ('activatedCount', 'deactivatedCount', 'missingCount', 'failedCount')
    event_counters = dict(zip(('audioActivated', 'audioDeactivated', 'audioActivationMissing', 'audioActivationFailed'), counters))
    observed_counts = dict.fromkeys(counters, 0)
    for row in rows:
        if row['event'] == 'm2.audioEvent':
            key = event_counters.get(row.get('name'))
            require(key is not None, case + ': unknown native audio event')
            scoped = row.get('name') in ('audioActivationMissing', 'audioActivationFailed')
            require('conversationId' not in row and
                    (row.get('conversationID') == call if scoped else 'conversationID' not in row),
                    case + ': native audio event conversation scope differs')
            observed_counts[key] += 1
            require(type(row.get('count')) is int and row['count'] == observed_counts[key],
                    case + ': native audio event counter differs')
        elif row['event'] == 'm2.mediaSnapshot':
            require(all(type(row.get(key)) is int and row[key] == count for key, count in observed_counts.items()),
                    case + ': media sample counters precede/differ from native audio events')
    states = {'initial': (False, 0, 0, 0, 0), 'demand': (False, 0, 0, 0, 0),
              'active': (True, 1, 0, 0, 0), 'speaker': (True, 1, 0, 0, 0),
              'held': (False, 1, 1, 0, 0), 'resumed': (True, 2, 1, 0, 0),
              'ended': (False, 2, 2, 0, 0), 'failed': (False, 0, 0, 1, 1)}
    for sample in samples:
        active, *counts = states[sample['label']]
        initial = sample['label'] == 'initial'
        # Launch observes the existing ADM/session. Gating and call category are
        # established only by native preparation of the actual join action.
        require(all(type(sample.get(k)) is bool for k in
                    ('inputAvailable', 'outputAvailable', 'isEngineRunning')) and
                (sample['isEngineRunning'] is False if initial else
                 all(sample[k] == active for k in ('inputAvailable', 'outputAvailable', 'isEngineRunning'))) and
                all(type(sample.get(k)) is int and sample[k] == count for k, count in zip(counters, counts)),
                case + ': native availability/running/event counts differ at ' + sample['label'])
        require(type(sample.get('routeCount')) is int and sample['routeCount'] > 0 and
                (sample.get('currentRouteType') is None or isinstance(sample['currentRouteType'], str)) and
                all(isinstance(sample.get(k), str) and sample[k] for k in ('category', 'mode')) and
                (initial or (sample['category'] == 'AVAudioSessionCategoryPlayAndRecord' and
                             sample['mode'] == 'AVAudioSessionModeVoiceChat')),
                case + ': route/session observation differs')
    if case == 'livekit':
        require(one(samples, 'm2.mediaSnapshot', label='speaker').get('currentRouteType') == 'Speaker',
                'livekit: speaker selection was not observed')
        require(any(c.get('hasConnectedAt') is True for r in snapshots for c in r['conversations']) and
                any(c.get('status') == 'held' for r in snapshots for c in r['conversations']),
                'livekit: connected report/held projection absent')
    handlers = [r for r in rows if r['event'] == 'm2.handler']
    kinds = ['join', 'hold', 'hold', 'end'] if case == 'livekit' else ['join']
    require([r.get('kind') for r in handlers] == kinds and all(r.get('origin') == 'app' and
            r.get('conversationID') == call for r in handlers), case + ': handler delivery differs')
    ringing = one(rows, 'm2.assertion', label='push-ringing')
    joined = one(rows, 'm2.assertion', label='joined')
    backend = one(rows, 'm2.assertion', label='backend-connected')
    require(all(c['hasConnectedAt'] is False and c['status'] != 'connected'
                for r in snapshots if rows.index(r) < rows.index(joined) for c in r['conversations']) and
            any(rows.index(samples[1]) < rows.index(r) < rows.index(joined) and
                len(r['conversations']) == 1 and r['conversations'][0]['status'] == 'connecting' and
                'pending' not in r['conversations'][0] and r['conversations'][0]['hasConnectedAt'] is False
                for r in snapshots), case + ': joined action lacks settled connecting projection')
    require(any(rows.index(joined) < rows.index(r) < rows.index(backend) and
                len(r['conversations']) == 1 and r['conversations'][0]['status'] == 'connected' and
                'pending' not in r['conversations'][0] and r['conversations'][0]['hasConnectedAt'] is True
                for r in snapshots) and
            all(c['hasConnectedAt'] is True for r in snapshots for c in r['conversations']
                if c['status'] == 'connected'), case + ': backend connected report/timestamp projection absent')
    track, demand, release = one(rows, 'm2.localTrack'), one(rows, 'm2.recordingDemand'), one(rows, 'm2.localTrackReleased')
    require(exact((track.get('count'), release.get('count')), (1, 1)) and track.get('enabled') is True and
            demand.get('accepted') is True and rows.index(samples[0]) < rows.index(one(rows, 'm2.controlReady')) <
            rows.index(one(rows, 'm2.pushInjected')) < rows.index(ringing) < rows.index(handlers[0]) <
            rows.index(track) < rows.index(demand) < rows.index(samples[1]) < rows.index(joined) < rows.index(backend) and
            rows.index(backend) < rows.index(samples[2]) and
            any(rows.index(one(rows, 'm2.pushInjected')) < rows.index(r) < rows.index(ringing) and
                len(r['conversations']) == 1 and r['conversations'][0]['status'] == 'ringing' for r in snapshots) and
            rows.index(samples[-1]) < rows.index(assertions[-1]) < rows.index(release) < rows.index(one(rows, 'm2.result')),
            case + ': local demand/release/control ordering differs')
    require(rows.index(snapshots[-1]) < rows.index(assertions[-1]) and
            (case != 'livekit' or rows.index(snapshots[-1]) < rows.index(samples[-1])),
            case + ': empty SDK projection was not observed while demand remained')
    push = one(rows, 'm2.pushInjected')
    received, incoming, reported, completed = [one(engine, event) for event in
        ('push.received', 'report.incoming', 'report.completed', 'push.completed')]
    modern = tuple(map(int, simulator_os.split('.')[:2])) >= (26, 4)
    require(valid_uuid(push.get('pushID')) and push.get('mustReport') is True and push.get('label') == 'primary' and
            all(r.get('pushID') == push['pushID'] for r in (received, incoming, reported, completed)) and
            received.get('api') == completed.get('api') == ('metadata' if modern else 'legacy') and
            received.get('mustReport') is True and incoming.get('callUUID') == reported.get('callUUID') == call and
            type(reported.get('error')) is int and reported['error'] == 0 and
            [engine.index(r) for r in (received, incoming, reported, completed)] ==
            sorted(engine.index(r) for r in (received, incoming, reported, completed)), case + ': push/report correlation differs')
    delivered = [r for r in engine if r['event'] == 'transaction.delivered']
    action_kinds = ['CXAnswerCallAction', 'CXSetHeldCallAction', 'CXSetHeldCallAction', 'CXEndCallAction'] if case == 'livekit' else ['CXAnswerCallAction']
    require([r.get('kinds') for r in delivered] == [[k] for k in action_kinds] and
            all(isinstance(r.get('actionIDs'), list) and len(r['actionIDs']) == 1 for r in delivered),
            case + ': provider transaction inventory differs')
    actions = [r['actionIDs'][0] for r in delivered]
    settled = [r for r in engine if r['event'] == 'action.settled']
    require(all(valid_uuid(action) for action in actions) and all(valid_uuid(r.get('actionID')) for r in settled),
            case + ': provider action failed/missing/duplicate')
    normalized_actions = [uuid.UUID(action) for action in actions]
    normalized_settled = [uuid.UUID(r['actionID']) for r in settled]
    require(len(set(normalized_actions)) == len(actions) and len(settled) == len(actions) and
            set(normalized_settled) == set(normalized_actions) and all(r.get('fulfilled') is True for r in settled),
            case + ': provider action failed/missing/duplicate')
    changes = [r for r in engine if r['event'] == 'call.changed']
    require(changes and all(r.get('uuid') == call and r.get('outgoing') is False and
            all(type(r.get(k)) is bool for k in ('connected', 'held', 'ended')) for r in changes) and
            changes[-1].get('ended') is True, case + ': native call did not end')
    native_events = [r for r in rows if r['event'] == 'm2.audioEvent']
    if case == 'livekit':
        require(any(r['connected'] is True and r['ended'] is False for r in changes) and
                any(r['held'] is True and r['ended'] is False for r in changes),
                'livekit: native connected/held projection absent')
        require(exact([(r.get('name'), r.get('count')) for r in native_events],
                [('audioActivated', 1), ('audioDeactivated', 1), ('audioActivated', 2), ('audioDeactivated', 2)]) and
                [r['event'] for r in engine if r['event'] in ('audio.activated', 'audio.deactivated')] ==
                ['audio.activated', 'audio.deactivated', 'audio.activated', 'audio.deactivated'] and
                not any(r['event'] == 'fault.audioSuppressed' for r in engine), 'livekit: audio lifecycle differs')
    else:
        require(exact([(r.get('name'), r.get('count')) for r in native_events],
                [('audioActivationMissing', 1), ('audioActivationFailed', 1)]) and
                any(r['event'] == 'fault.audioSuppressed' for r in engine) and
                not any(r['event'] in ('audio.activated', 'audio.deactivated') for r in engine),
                'stale-audio: suppressed activation/absence event inventory differs')
        missing, failed = native_events
        # Recording demand precedes join fulfillment. The actual watchdog start
        # is not recorded, so this is an upper liveness budget, not a measured
        # ten-second activation deadline. Exact 10+5 policy is host-proved.
        # The recovery/failure and end observations use this same native clock.
        require(rows.index(demand) < rows.index(missing) < rows.index(failed) and
                0 <= missing['t_ms'] - demand['t_ms'] <= 13000 and
                4900 <= failed['t_ms'] - missing['t_ms'] <= 8000 and
                failed['t_ms'] <= snapshots[-1]['t_ms'] <= failed['t_ms'] + 8000,
                'stale-audio: bounded demand/watchdog recovery/termination liveness differs')
        require(one(engine, 'report.ended').get('callUUID') == call and
                type(one(engine, 'report.ended').get('reason')) is int and
                one(engine, 'report.ended')['reason'] == 1, 'stale-audio: failed report missing')
    require(not any(r['event'] == 'm2.hookEvent' and r.get('name') == 'providerReset' for r in rows), case + ': provider reset')
    return dict(success=True, existingMediaObjectStable=True, localCaptureDemand=True, nativeStages=labels)


def reentrancy_case(rows, engine, manifest, simulator_os):
    trace_shape(rows, 'media-reentrancy')
    launch = one(rows, 'launch')
    require(launch.get('mode') == 'sdk-m1-contracts' and launch.get('case') == 'media-reentrancy' and
            launch.get('traceVersion') == 2 and launch.get('simulatorOS') == simulator_os and
            launch.get('runtimeInjectionPresent') is False and
            launch.get('executableSHA256') == manifest['files']['binaries/contracts'], 'reentrancy: unbound contract launch')
    require(one(rows, 'contract.activation').get('active') is True and
            type(one(rows, 'contract.mediaReentrancy').get('authorizationCalls')) is int and
            one(rows, 'contract.mediaReentrancy')['authorizationCalls'] == 1 and
            one(rows, 'contract.mediaReentrancy').get('sameOwner') is True and
            type(one(rows, 'contract.mediaReentrancy').get('warnings')) is int and
            one(rows, 'contract.mediaReentrancy')['warnings'] == 0 and
            one(rows, 'contract.result').get('success') is True, 'reentrancy: singleton/adapter callback contract failed')
    require(not any(r['event'] in ('transaction.delivered', 'call.changed') for r in engine),
            'reentrancy: unexpected call activity')
    return dict(success=True, owners=1, authorizationCalls=1)


def validate(root, source_root=ROOT):
    manifest = read(root, 'manifest.json')
    identity = source_identity(source_root)
    require(type(manifest.get('schemaVersion')) is int and manifest['schemaVersion'] == 1 and manifest.get('scenario') == 'sdk-m2' and
            manifest.get('configuration') == 'Release' and manifest.get('mediaAdapter') == 'livekit' and
            manifest.get('ownsSimulator') is True and manifest.get('runtimeInjectionRequested') is False and
            all(manifest.get(k) == v for k, v in identity.items()), 'invalid M2 source/manifest/injection policy')
    require(all(isinstance(manifest.get(k), str) and manifest[k] for k in ('runID', 'simulatorID')), 'missing run/simulator identity')
    bindings = dict(sourceBeginSHA256='source-before.json', sourceEndSHA256='source-after.json', cleanupSHA256='cleanup.json',
                    environmentSHA256='environment.json', runtimeSHA256='runtime.json', installedSHA256='installed.json',
                    buildReceiptSHA256='build-info.json', hostAudioControlsSHA256='host-audio-controls.json')
    for field, name in bindings.items(): require(digest(root / name) == manifest.get(field), 'unbound ' + name)
    build = validate_build(root, identity, require_apps=False)
    require(manifest.get('files') == build['files'], 'manifest product inventory differs')
    require(build['files']['products/ios-27.0.json'] == digest(source_root / 'Sources/Engine/Resources/ios-27.0.json'),
            'bundled behavior profile differs from source')
    cleanup = read(root, 'cleanup.json')
    require(cleanup.get('simulatorID') == manifest['simulatorID'] and cleanup.get('deleted') is True and
            cleanup.get('absentFromInventory') is True and cleanup.get('deleteExitCode') == 0, 'owned simulator cleanup incomplete')
    require(type(cleanup.get('deleteExitCode')) is int, 'invalid cleanup exit status')
    environment, runtime = read(root, 'environment.json'), read(root, 'runtime.json')
    require(environment.get('simulatorID') == manifest['simulatorID'] and
            environment.get('simulatorRuntimeID') == runtime.get('identifier') and
            environment.get('simulatorOS') == runtime.get('version') and
            all(isinstance(environment.get(k), str) and environment[k] for k in
                ('simulatorRuntimeID', 'simulatorOS', 'xcodeVersion', 'sdkVersion', 'hostArchitecture')) and
            isinstance(runtime.get('buildversion'), str) and runtime['buildversion'], 'unbound execution OS/compiler')
    inherited = manifest.get('externalDYLDInsertLibrariesSHA256')
    require(type(manifest.get('externalDYLDInsertLibrariesPresent')) is bool and isinstance(inherited, str) and
            len(inherited) == 64 and all(c in '0123456789abcdef' for c in inherited) and
            (manifest['externalDYLDInsertLibrariesPresent'] or inherited == hashlib.sha256(b'').hexdigest()),
            'invalid inherited environment digest')
    files = build['files']
    require(read(root, 'installed.json') == dict(exampleSHA256=files['binaries/example'],
            javascriptSHA256=files['binaries/main.jsbundle'], contractsSHA256=files['binaries/contracts'],
            livekitWebRTCSHA256=files['binaries/livekit-webrtc'],
            livekitWebRTCInfoSHA256=files['products/LiveKitWebRTC.Info.plist'],
            exampleProfileSHA256=files['products/ios-27.0.json'], contractsProfileSHA256=files['products/ios-27.0.json']),
            'installed bytes differ from built products')
    host = read(root, 'host-audio-controls.json')
    require(host.get('source') == identity and host.get('result', {}).get('success') is True and
            host['result'].get('checks') == list(HOST_CHECKS), 'source-bound host watchdog/route controls missing')
    control_files = {'sdk-m2-' + case + suffix for case in CASES[:2] for suffix in CONTROL_SUFFIXES}
    require(set(manifest.get('controlFiles', {})) == control_files and
            all(digest(root / name) == manifest['controlFiles'][name] for name in control_files), 'unbound control artifact inventory')
    results = {}
    version = (source_root / 'VERSION').read_text().strip()
    for case in CASES:
        name = 'sdk-m2-' + case
        bundle = CONTRACTS if case == 'media-reentrancy' else EXAMPLE
        rows, receipt = m0.bound_rows(root, name, manifest, bundle)
        require(type(receipt.get('schemaVersion')) is int and type(receipt.get('appPID')) is int and
                type(receipt.get('launcherAppPID')) is int and type(receipt.get('launchExitCode')) is int,
                name + ': invalid supervisor schema/process types')
        engine = journal(root, name, manifest, receipt, bundle, version)
        if case == 'media-reentrancy':
            results[case] = reentrancy_case(rows, engine, manifest, environment['simulatorOS'])
        else:
            controls(root, name, case, manifest, receipt, rows)
            results[case] = media_case(rows, engine, case, environment['simulatorOS'])
    return dict(success=True, scenario='sdk-m2', source=identity, executionOS=environment['simulatorOS'],
                simulatorRuntime=runtime, cases=results, hostAudioControls=len(HOST_CHECKS),
                recoveryEvidence='Exact activation/recovery policy and one recovery are host-proved. Native liveness is bounded from pre-fulfillment recording demand through scoped absence events and clean end; the actual watchdog start, exact activation interval and AV configuration call count are not measured.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.capture.resolve()), indent=2))
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        print(json.dumps(dict(success=False, error=str(error)), indent=2))
        raise SystemExit(1)
