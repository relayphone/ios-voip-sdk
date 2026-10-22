#!/usr/bin/env python3
"""Synthetic M2 positives/tampers and mocked runner controls; no native claims."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, patch

from check_sdk_m0 import IDENTITY, write_json, write_trace
import sdk_m2_conformance as gate
from sdk_m2_environment import COMMANDS as ENVIRONMENT_COMMANDS, inspect as inspect_environment
import run_sdk_m2 as runner

CALL = 'E715ACF2-A7C1-4D74-8BD9-EAFA47693255'
PUSH = '62D7BDE8-FA14-40CD-A7E1-AF9D7E512B79'
NONCE = 'E1EA4298-FD17-4ED9-8531-C1FB68396796'
WALL = 1792627200000


def fixture_case(root, case, pid):
    rows = []
    revision = 0
    clock = 0
    bundle = gate.EXAMPLE if case in gate.CASES[:2] else gate.CONTRACTS

    def add(event, at=None, **fields):
        nonlocal clock
        clock = max(clock + 1, 0 if at is None else at)
        row = dict(event=event, t_ms=clock, wallTimeMS=WALL + clock, main=True, pid=pid,
                   runID='run-1', simulatorID='sim-1', bundleID=bundle, **fields)
        rows.append(row)
        return row

    def assertion(label, call=None):
        add('m2.assertion', label=label, passed=True, conversationID=call)

    def snapshot(status=None, connected=False):
        nonlocal revision
        calls = [] if status is None else [dict(id=CALL, direction='incoming', status=status,
            isMuted=False, isVideo=False, hasConnectedAt=connected)]
        add('sdk.snapshot', revision=revision, conversations=calls)
        revision += 1

    def media(label, active=False, counts=(0, 0, 0, 0)):
        add('m2.mediaSnapshot', label=label, moduleID='existing-module', deviceID='existing-adm',
            inputAvailable=label == 'initial' or active, outputAvailable=label == 'initial' or active,
            isEngineRunning=active,
            category='AVAudioSessionCategoryAmbient' if label == 'initial' else 'AVAudioSessionCategoryPlayAndRecord',
            mode='AVAudioSessionModeDefault' if label == 'initial' else 'AVAudioSessionModeVoiceChat',
            routeCount=2, currentRouteType='Speaker', **dict(zip(
                ('activatedCount', 'deactivatedCount', 'missingCount', 'failedCount'), counts)))
        assertion(label + '-media')
        assertion(label + '-same-engine')

    def handler(kind):
        add('m2.handler', kind=kind, conversationID=CALL, origin='app')

    add('app.entry')
    if case in ('media-reentrancy', 'audio-lifecycle'):
        add('launch', mode='sdk-m1-contracts', case=case, traceVersion=2, simulatorOS='27.0',
            runtimeInjectionPresent=False, executableSHA256=gate.digest(root / 'binaries/contracts'))
        add('contract.activation', active=True)
        if case == 'audio-lifecycle':
            from check_sdk_m2_audio_lifecycle import lifecycle_rows
            for row in lifecycle_rows('modern'):
                row = dict(row); add(row.pop('event'), **row)
        else:
            add('contract.mediaReentrancy', authorizationCalls=1, sameOwner=True, warnings=0)
        add('contract.result', success=True)
    else:
        add('launch', mode='sdk-m2', case=case, traceVersion=2)
        add('sdk.activation', active=True)
        add('sdk.managerCreated', owner='VoIPApplication.start')
        snapshot()
        media('initial')
        for label in ('inactive-route-rejected', 'routes-observed'): assertion(label)
        add('m2.controlReady', staleAudio=case == 'stale-audio')
        add('m2.pushInjected', pushID=PUSH, mustReport=True, label='primary')
        snapshot('ringing')
        assertion('push-ringing', CALL)
        handler('join')
        assertion('one-local-audio-track')
        add('m2.localTrack', count=1, enabled=True)
        recording = add('m2.recordingDemand', accepted=True)
        media('demand')
        snapshot('connecting')
        add('sdk.state', state='joining', conversationID=CALL)
        assertion('joined', CALL)
        snapshot('connected', True)
        add('sdk.state', state='joined', conversationID=CALL)
        assertion('backend-connected', CALL)
        if case == 'livekit':
            add('m2.audioEvent', name='audioActivated', count=1)
            media('active', True, (1, 0, 0, 0))
            media('speaker', True, (1, 0, 0, 0))
            handler('hold')
            snapshot('held', True)
            add('m2.audioEvent', name='audioDeactivated', count=1)
            media('held', False, (1, 1, 0, 0))
            handler('hold')
            snapshot('connected', True)
            add('m2.audioEvent', name='audioActivated', count=2)
            media('resumed', True, (2, 1, 0, 0))
            handler('end')
            snapshot('ended', True)
            snapshot()
            add('m2.audioEvent', name='audioDeactivated', count=2)
            media('ended', False, (2, 2, 0, 0))
            assertion('ended-empty-with-demand', CALL)
        else:
            add('m2.audioEvent', at=recording['t_ms'] + 10000, name='audioActivationMissing', count=1,
                conversationID=CALL)
            add('m2.audioEvent', at=recording['t_ms'] + 15000, name='audioActivationFailed', count=1,
                conversationID=CALL)
            snapshot('ended', True)
            snapshot()
            media('failed', False, (0, 0, 1, 1))
            assertion('stale-ended-empty-with-demand', CALL)
        add('m2.localTrackReleased', count=1)
        add('m2.result', success=True)
    add('done')
    name = 'sdk-m2-' + case
    write_trace(root, name, rows)
    path = root / (name + '.receipt.json')
    receipt = json.loads(path.read_text())
    receipt.update(appPID=pid, launcherAppPID=pid)

    engine = []

    def native(event, **fields):
        engine.append(dict(event=event, sequence=len(engine) + 1, t_ms=len(engine),
            runID='run-1', pid=pid, bundleID=bundle, profile='ios-27.0', **fields))

    native('runtime.installed', version=(gate.ROOT / 'VERSION').read_text().strip())
    native('provider.created', provider='one-provider')
    if case == 'audio-lifecycle':
        from check_sdk_m2_audio_lifecycle import lifecycle_engine
        for row in lifecycle_engine():
            row = dict(row)
            if row['event'] == 'transaction.delivered': row['provider'] = 'one-provider'
            native(row.pop('event'), **row)
    elif case in gate.CASES[:2]:
        native('push.received', pushID=PUSH, api='metadata', mustReport=True)
        native('report.incoming', pushID=PUSH, callUUID=CALL)
        native('call.changed', uuid=CALL, outgoing=False, connected=False, held=False, ended=False)
        native('report.completed', pushID=PUSH, callUUID=CALL, error=0)
        native('push.completed', pushID=PUSH, api='metadata')
        kinds = ['CXAnswerCallAction', 'CXSetHeldCallAction', 'CXSetHeldCallAction', 'CXEndCallAction'] if case == 'livekit' else ['CXAnswerCallAction']
        for index, kind in enumerate(kinds):
            action = str(uuid.UUID(int=index + 1)).upper()
            native('transaction.delivered', provider='one-provider', actionIDs=[action], kinds=[kind])
            native('action.settled', actionID=action, fulfilled=True)
            if index < 3:
                native('call.changed', uuid=CALL, outgoing=False, connected=True, held=index == 1, ended=False)
        if case == 'livekit':
            for event in ('audio.activated', 'audio.deactivated', 'audio.activated', 'audio.deactivated'): native(event)
        else:
            native('fault.audioSuppressed')
            native('report.ended', callUUID=CALL, reason=1)
        native('call.changed', uuid=CALL, outgoing=False, connected=True, held=False, ended=True)
    journal = root / (name + '.runtime.jsonl')
    journal.write_text(''.join(json.dumps(r) + '\n' for r in engine))
    receipt['journalSHA256'] = gate.digest(journal)
    write_json(path, receipt)
    if case in gate.CASES[:2]:
        write_json(root / (name + '.session.json'), dict(schemaVersion=1, runID='run-1', pid=pid,
            bundleID=gate.EXAMPLE, profile='ios-27.0', notification=f'dev.callkitsim.control.{pid}'))
        write_json(root / (name + '.control.request.json'), dict(id=NONCE, runID='run-1', pid=pid,
            bundleID=gate.EXAMPLE, operation='faults', faults=dict(staleAudio=case == 'stale-audio',
                reportCallbackDelayMS=0, invalidateDuringHandoff=False)))
        write_json(root / (name + '.control.response.json'), dict(id=NONCE, runID='run-1', pid=pid,
            bundleID=gate.EXAMPLE, success=True, result=dict(configured=True)))
        write_json(root / (name + '.control-ready.json'), dict(runID='run-1', case=case, pid=pid,
            staleAudio=case == 'stale-audio'))
        write_json(root / (name + '.control-binding.json'), dict(runID='run-1', case=case, pid=pid, nonce=NONCE,
            requestSHA256=gate.digest(root / (name + '.control.request.json')),
            responseSHA256=gate.digest(root / (name + '.control.response.json')),
            readySHA256=gate.digest(root / (name + '.control-ready.json'))))


def fixture(root):
    for name in gate.PRODUCT_FILES:
        path = root / name
        path.parent.mkdir(exist_ok=True)
        path.write_text('synthetic ' + name)
    shutil.copyfile(gate.ROOT / 'Sources/Engine/Resources/ios-27.0.json', root / 'products/ios-27.0.json')
    write_json(root / 'products/versions.json', gate.VERSIONS)
    write_json(root / 'products/Podfile.properties.json', {'ios-voip-sdk.mediaAdapter': 'livekit'})
    (root / 'products/Podfile.lock').write_text('PODS:\n  - livekit-react-native (3.1.0)\n  - livekit-react-native-webrtc (150.1.0)\n  - LiveKitWebRTC (150.7871.03)\n')
    (root / 'products/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=gate.EXAMPLE,
        CFBundleExecutable='Example', VoIPSDK=dict(mediaAdapter='livekit', simulatorSupport=True),
        UIBackgroundModes=['voip', 'audio'], NSMicrophoneUsageDescription='Local fixture capture.')))
    (root / 'products/LiveKitWebRTC.Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='io.livekit.LiveKitWebRTC', CFBundleExecutable='LiveKitWebRTC',
        CFBundleShortVersionString='1.0', CFBundleVersion='1.0')))
    write_json(root / 'products/IosVoipSDK.podspec.json', dict(source_files=[
        'Sources/**/*.{swift,h,m}', 'Expo/apple/**/*.{swift,h}', 'ExpoMedia/Shared/ExpoMediaSupport.swift',
        'ExpoMedia/LiveKit/**/*.{swift,h,m}', 'ExpoMedia/Shared/VSMediaBinding.h',
        'ExpoMedia/Shared/QueuedMediaAdapter.swift'], dependencies={
            'ExpoModulesCore': [], 'React-Core': [], 'livekit-react-native-webrtc': ['>= 150.1.0', '< 151.0.0']}))
    write_json(root / 'products/contracts-build-info.json', dict(schemaVersion=1, product='sdk-m1-contracts',
        configuration='Debug', sourceDirty=False, sourceCommit=IDENTITY['sourceCommit'], files={
            'SDKM1Contracts.app/SDKM1Contracts': gate.digest(root / 'binaries/contracts'),
            'SDKM1Contracts.app/IosVoipSDKRuntime.bundle/ios-27.0.json': gate.digest(root / 'products/ios-27.0.json')}))
    files = gate.products(root)
    for name in ('source-before.json', 'source-after.json'): write_json(root / name, IDENTITY)
    write_json(root / 'build-info.json', dict(schemaVersion=1, product='sdk-m2', configuration='Release',
        contractsConfiguration='Debug', mediaAdapter='livekit', sourceStart=IDENTITY, sourceEnd=IDENTITY,
        **IDENTITY, files=files))
    write_json(root / 'environment.json', dict(simulatorID='sim-1', simulatorRuntimeID='ios-27', simulatorOS='27.0',
        xcodeVersion='Xcode 27.1\nBuild version 27A9275', sdkVersion='27.1', hostArchitecture='arm64'))
    write_json(root / 'runtime.json', dict(identifier='ios-27', version='27.0', buildversion='27A'))
    environment_outputs = dict(macOS='ProductName: macOS\nProductVersion: 27.0.1\nBuildVersion: 26A434\n',
        architecture='arm64\n', xcode='Xcode 27.1\nBuild version 27A9275\n', simulatorSDKVersion='27.1\n',
        simulatorSDKBuild='24B78\n', simulatorSDKPath='/synthetic/SDK', runtimes=json.dumps(dict(runtimes=[dict(
            platform='iOS', name='iOS 27.0', identifier='ios-27', version='27.0', buildversion='27A', isAvailable=True)])))
    def replay(args, **options):
        key = next(key for key, argv in ENVIRONMENT_COMMANDS.items() if args == argv)
        return SimpleNamespace(returncode=0, stdout=environment_outputs[key], stderr='')
    write_json(root / 'environment-preflight.json', inspect_environment('iOS 27.0', 'modern', '27.1', '27A9275',
        execute=replay, environment=dict(ImageOS='synthetic-image', ImageVersion='synthetic-version', RUNNER_ARCH='ARM64',
            GITHUB_RUN_ID='1', GITHUB_RUN_ATTEMPT='1', GITHUB_SHA=IDENTITY['sourceCommit'])))

    write_json(root / 'cleanup.json', dict(simulatorID='sim-1', deleted=True, deleteExitCode=0, absentFromInventory=True))
    write_json(root / 'installed.json', dict(exampleSHA256=files['binaries/example'],
        javascriptSHA256=files['binaries/main.jsbundle'], contractsSHA256=files['binaries/contracts'],
        livekitWebRTCSHA256=files['binaries/livekit-webrtc'], livekitWebRTCInfoSHA256=files['products/LiveKitWebRTC.Info.plist'],
        exampleProfileSHA256=files['products/ios-27.0.json'], contractsProfileSHA256=files['products/ios-27.0.json']))
    write_json(root / 'host-audio-controls.json', dict(source=IDENTITY, result=dict(success=True, checks=list(gate.HOST_CHECKS))))
    for pid, case in enumerate(gate.CASES, 123): fixture_case(root, case, pid)
    manifest = dict(schemaVersion=1, scenario='sdk-m2', configuration='Release', mediaAdapter='livekit',
        runID='run-1', simulatorID='sim-1', ownsSimulator=True, runtimeInjectionRequested=False, audioPath='modern', **IDENTITY,
        files=files, controlFiles={name: gate.digest(root / name) for name in [
            'sdk-m2-' + case + suffix for case in gate.CASES[:2] for suffix in gate.CONTROL_SUFFIXES]},
        externalDYLDInsertLibrariesPresent=False, externalDYLDInsertLibrariesSHA256=gate.hashlib.sha256(b'').hexdigest())
    for key, name in dict(sourceBeginSHA256='source-before.json', sourceEndSHA256='source-after.json',
            cleanupSHA256='cleanup.json', environmentSHA256='environment.json', runtimeSHA256='runtime.json',
            installedSHA256='installed.json', buildReceiptSHA256='build-info.json', hostAudioControlsSHA256='host-audio-controls.json',
            environmentPreflightSHA256='environment-preflight.json').items():
        manifest[key] = gate.digest(root / name)
    write_json(root / 'manifest.json', manifest)


def rebind(root):
    """Rehash tampered evidence so semantic checks must reject the change."""
    manifest = json.loads((root / 'manifest.json').read_text())
    manifest['files'] = gate.products(root)
    for name in manifest['controlFiles']: manifest['controlFiles'][name] = gate.digest(root / name)
    for key, name in dict(sourceBeginSHA256='source-before.json', sourceEndSHA256='source-after.json',
            cleanupSHA256='cleanup.json', environmentSHA256='environment.json', runtimeSHA256='runtime.json',
            installedSHA256='installed.json', buildReceiptSHA256='build-info.json', hostAudioControlsSHA256='host-audio-controls.json',
            environmentPreflightSHA256='environment-preflight.json').items():
        manifest[key] = gate.digest(root / name)
    write_json(root / 'manifest.json', manifest)


def change_json(root, name, edit):
    value = json.loads((root / name).read_text()); edit(value); write_json(root / name, value)
    rebind(root)


def change_rows(root, case, edit):
    name = 'sdk-m2-' + case
    rows = gate.m0.load(root, name)
    receipt = json.loads((root / (name + '.receipt.json')).read_text())
    edit(rows)
    write_trace(root, name, rows)
    updated = json.loads((root / (name + '.receipt.json')).read_text())
    updated.update(appPID=receipt['appPID'], launcherAppPID=receipt['launcherAppPID'], journalSHA256=receipt['journalSHA256'])
    write_json(root / (name + '.receipt.json'), updated)


def change_engine(root, case, edit):
    name = 'sdk-m2-' + case
    path = root / (name + '.runtime.jsonl')
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    edit(rows)
    for index, row in enumerate(rows): row['sequence'] = index + 1
    path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    receipt = json.loads((root / (name + '.receipt.json')).read_text())
    receipt['journalSHA256'] = gate.digest(path)
    write_json(root / (name + '.receipt.json'), receipt)


class Controls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ios-voip-m2-controls-')
        self.root = Path(self.temporary.name)
        fixture(self.root)
        self.identity = patch.object(gate, 'source_identity', return_value=IDENTITY)
        self.identity.start()

    def tearDown(self):
        self.identity.stop(); self.temporary.cleanup()

    def reject(self, pattern):
        with self.assertRaisesRegex(gate.EvidenceError, pattern): gate.validate(self.root)

    def test_positive_source_bound_four_cases(self):
        result = gate.validate(self.root)
        self.assertTrue(result['success'])
        self.assertEqual(result['hostAudioControls'], 21)
        self.assertEqual(set(result['cases']), set(gate.CASES))

    def test_removed_shared_owner_is_rejected(self):
        change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'sdk.managerCreated').update(
            owner='ConversationClient.shared'))
        self.reject('SDK/result unavailable')

    def test_rebound_environment_preflight_must_identify_the_actual_lane(self):
        mutations = [lambda value: value.update(success=False),
            lambda value: value.update(sourceSHA256='f' * 64),
            lambda value: value['requested'].update(runtime='iOS 27.1'),
            lambda value: value['selectedRuntime'].update(buildversion='different'),
            lambda value: value['commands']['xcode'].update(stdout='Xcode 27.0\nBuild version 27A9275\n'),
            lambda value: value['commands']['architecture'].update(stdout='x86_64\n'),
            lambda value: value['commands']['runtimes'].update(argv=['invented']),
            lambda value: value['runner'].update(GITHUB_SHA='f' * 40),
            lambda value: value['runner'].update(ImageVersion=False)]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture(self.root)
                change_json(self.root, 'environment-preflight.json', mutation)
                self.reject('preflight')
        fixture(self.root)
        change_json(self.root, 'manifest.json', lambda value: value.update(audioPath='legacy'))
        self.reject('audio path/runtime')

    def test_rebound_lifecycle_capture_cannot_be_empty_or_substitute_an_advisory_enable(self):
        change_rows(self.root, 'audio-lifecycle', lambda rows: rows.__setitem__(slice(None),
            [row for row in rows if row['event'] not in ('lifecycle.observed', 'lifecycle.consumed')]))
        self.reject('capture empty')
        fixture(self.root)
        change_rows(self.root, 'audio-lifecycle', lambda rows: gate.one(rows, 'lifecycle.consumed',
            phase='fixture-app-activation').update(authorizedAfter=True))
        self.reject('advisory notification changed authorization')

    def test_missing_empty_or_unbound_products(self):
        for mode in ('missing', 'empty', 'changed'):
            with self.subTest(mode=mode):
                fixture(self.root)
                path = self.root / 'binaries/example'
                if mode == 'missing': path.unlink()
                else: path.write_bytes(b'' if mode == 'empty' else b'different binary')
                self.reject('product|products')

    def test_rehashed_build_selection_and_device_configuration(self):
        mutations = [
            ('products/versions.json', lambda v: v.update({'@livekit/react-native-webrtc': '151.0.0'})),
            ('products/IosVoipSDK.podspec.json', lambda v: v['source_files'].append('ExpoMedia/WebRTC/**/*.{swift,h,m}')),
            ('products/IosVoipSDK.podspec.json', lambda v: v['source_files'].append('ExpoMedia/**/*.{swift,h,m}')),
            ('products/contracts-build-info.json', lambda v: v.update(configuration='Release')),
        ]
        for name, edit in mutations:
            with self.subTest(name=name):
                fixture(self.root); change_json(self.root, name, edit)
                # Rebind build bytes too; this must fail on selection semantics.
                change_json(self.root, 'build-info.json', lambda b: b.update(files=gate.products(self.root)))
                self.reject('versions|Podspec|Debug contract')

    def test_media_stages_identity_and_running(self):
        for field, value in [('deviceID', 'replacement-adm'), ('inputAvailable', False),
                             ('isEngineRunning', False), ('currentRouteType', 'Receiver'), ('activatedCount', 9)]:
            with self.subTest(field=field):
                fixture(self.root)
                change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.mediaSnapshot', label='speaker').update({field: value}))
                self.reject('identity|availability|speaker|counters')
        fixture(self.root)
        def late_activation(rows):
            event = gate.one(rows, 'm2.audioEvent', name='audioActivated', count=1)
            rows.remove(event)
            active = gate.one(rows, 'm2.mediaSnapshot', label='active')
            event.update(t_ms=active['t_ms'], wallTimeMS=active['wallTimeMS'])
            rows.insert(rows.index(active) + 1, event)
        change_rows(self.root, 'livekit', late_activation)
        self.reject('sample counters')

    def test_initial_session_is_observed_without_requiring_launch_configuration(self):
        for availability in ((True, False), (False, True), (False, False)):
            with self.subTest(availability=availability):
                fixture(self.root)
                change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.mediaSnapshot', label='initial').update(
                    inputAvailable=availability[0], outputAvailable=availability[1],
                    category='observed-category', mode='observed-mode'))
                self.assertTrue(gate.validate(self.root)['success'])
        for field, value in [('inputAvailable', 1), ('outputAvailable', 0), ('isEngineRunning', True),
                             ('activatedCount', 1), ('category', ''), ('mode', None)]:
            with self.subTest(field=field):
                fixture(self.root)
                change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.mediaSnapshot', label='initial').update({field: value}))
                self.reject('availability|counters|session')
        fixture(self.root)
        change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.mediaSnapshot', label='demand').update(
            category='AVAudioSessionCategoryAmbient', mode='AVAudioSessionModeDefault'))
        self.reject('session')

    def test_capture_demand_must_follow_actual_join_handler(self):
        for event in ('m2.localTrack', 'm2.recordingDemand'):
            with self.subTest(event=event):
                fixture(self.root)
                def before_join(rows):
                    moved = gate.one(rows, event)
                    rows.remove(moved)
                    join = gate.one(rows, 'm2.handler', kind='join')
                    moved.update(t_ms=join['t_ms'], wallTimeMS=join['wallTimeMS'])
                    rows.insert(rows.index(join), moved)
                change_rows(self.root, 'livekit', before_join)
                self.reject('demand/release/control ordering')

    def test_join_settles_connecting_before_backend_connected_report(self):
        for edit in (lambda call: call.update(status='connected', hasConnectedAt=True),
                     lambda call: call.update(pending={'kind': 'join'}),
                     lambda call: call.update(hasConnectedAt=True)):
            with self.subTest(edit=edit):
                fixture(self.root)
                def corrupt_settlement(rows):
                    call = next(r['conversations'][0] for r in rows if r['event'] == 'sdk.snapshot' and
                                r['conversations'] and r['conversations'][0]['status'] == 'connecting')
                    edit(call)
                change_rows(self.root, 'livekit', corrupt_settlement)
                self.reject('settled connecting')
        fixture(self.root)
        def missing_backend_timestamp(rows):
            call = next(r['conversations'][0] for r in rows if r['event'] == 'sdk.snapshot' and
                        r['conversations'] and r['conversations'][0]['status'] == 'connected')
            call['hasConnectedAt'] = False
        change_rows(self.root, 'livekit', missing_backend_timestamp)
        self.reject('backend connected report/timestamp')
        fixture(self.root)
        def early_active_stage(rows):
            active = gate.one(rows, 'm2.mediaSnapshot', label='active')
            activation = gate.one(rows, 'm2.audioEvent', name='audioActivated', count=1)
            backend = gate.one(rows, 'm2.assertion', label='backend-connected')
            for row in (activation, active):
                rows.remove(row)
                row.update(t_ms=backend['t_ms'], wallTimeMS=backend['wallTimeMS'])
                rows.insert(rows.index(backend), row)
        change_rows(self.root, 'livekit', early_active_stage)
        self.reject('demand/release/control ordering')

    def test_ended_gate_observed_before_demand_release(self):
        change_rows(self.root, 'livekit', lambda rows: rows.insert(rows.index(gate.one(rows, 'm2.mediaSnapshot', label='ended')),
            rows.pop(rows.index(gate.one(rows, 'm2.localTrackReleased')))))
        self.reject('time|ordering')
        for case in ('livekit', 'stale-audio'):
            with self.subTest(case=case):
                fixture(self.root)
                def late_empty(rows):
                    final = [r for r in rows if r['event'] == 'sdk.snapshot'][-1]
                    rows.remove(final)
                    released = gate.one(rows, 'm2.localTrackReleased')
                    final.update(t_ms=released['t_ms'], wallTimeMS=released['wallTimeMS'])
                    rows.insert(rows.index(released) + 1, final)
                change_rows(self.root, case, late_empty)
                self.reject('empty SDK projection')

    def test_push_action_audio_and_terminal_projection_tampers(self):
        edits = [lambda rows: gate.one(rows, 'report.incoming').update(pushID=''),
                 lambda rows: next(r for r in rows if r['event'] == 'action.settled').update(fulfilled=False),
                 lambda rows: next(r for r in rows if r['event'] == 'audio.activated').update(event='audio.deactivated')]
        for edit in edits:
            with self.subTest(edit=edit):
                fixture(self.root); change_engine(self.root, 'livekit', edit)
                self.reject('correlation|failed|lifecycle')
        fixture(self.root)
        change_rows(self.root, 'livekit', lambda rows: [r for r in rows if r['event'] == 'sdk.snapshot'][-1].update(
            conversations=[dict(id=CALL, direction='incoming', status='ending', isMuted=False, isVideo=False, hasConnectedAt=True)]))
        self.reject('not empty')
        fixture(self.root)
        change_engine(self.root, 'livekit', lambda rows: [r.update(connected=False, held=False)
            for r in rows if r['event'] == 'call.changed'])
        self.reject('native connected/held')

    def test_action_identities_must_be_uuids(self):
        for identity in (None, 7, ''):
            with self.subTest(identity=identity):
                fixture(self.root)
                def corrupt(rows):
                    gate.one(rows, 'transaction.delivered').update(actionIDs=[identity])
                    settled = gate.one(rows, 'action.settled')
                    if identity is None: settled.pop('actionID')
                    else: settled['actionID'] = identity
                change_engine(self.root, 'stale-audio', corrupt)
                self.reject('failed/missing/duplicate')
        fixture(self.root)
        def case_aliases(rows):
            variants = [CALL, CALL.lower(), CALL[0].lower() + CALL[1:], CALL[:4] + CALL[4].lower() + CALL[5:]]
            self.assertEqual(len(set(variants)), 4)
            for delivered, settled, identity in zip([r for r in rows if r['event'] == 'transaction.delivered'],
                    [r for r in rows if r['event'] == 'action.settled'], variants):
                delivered['actionIDs'] = [identity]; settled['actionID'] = identity
        change_engine(self.root, 'livekit', case_aliases)
        self.reject('failed/missing/duplicate')

    def test_stale_fault_events_timing_and_failure(self):
        for event, offset in (('audioActivationMissing', 5000), ('audioActivationFailed', -4000)):
            with self.subTest(event=event, offset=offset):
                fixture(self.root)
                def shift(rows):
                    marker = gate.one(rows, 'm2.audioEvent', name=event)
                    for row in rows[rows.index(marker):]:
                        row['t_ms'] += offset; row['wallTimeMS'] += offset
                change_rows(self.root, 'stale-audio', shift)
                self.reject('watchdog')
        fixture(self.root)
        change_engine(self.root, 'stale-audio', lambda rows: gate.one(rows, 'report.ended').update(reason=2))
        self.reject('failed report')
        fixture(self.root)
        change_rows(self.root, 'stale-audio', lambda rows: gate.one(rows, 'm2.audioEvent', name='audioActivationFailed').update(count=2))
        self.reject('counter')

    def test_native_absence_is_bounded_liveness_without_precise_start_claim(self):
        def earlier_missing(rows):
            missing = gate.one(rows, 'm2.audioEvent', name='audioActivationMissing')
            for row in rows[rows.index(missing):]:
                row['t_ms'] -= 9000; row['wallTimeMS'] -= 9000
        change_rows(self.root, 'stale-audio', earlier_missing)
        result = gate.validate(self.root)
        self.assertTrue(result['success'])
        self.assertIn('actual watchdog start', result['recoveryEvidence'])
        self.assertIn('not measured', result['recoveryEvidence'])

    def test_native_audio_events_preserve_conversation_scope(self):
        for event in ('audioActivationMissing', 'audioActivationFailed'):
            for edit in (lambda row: row.pop('conversationID'),
                         lambda row: row.update(conversationID=NONCE),
                         lambda row: row.update(conversationId=row.pop('conversationID'))):
                with self.subTest(event=event, edit=edit):
                    fixture(self.root)
                    change_rows(self.root, 'stale-audio', lambda rows: edit(gate.one(rows, 'm2.audioEvent', name=event)))
                    self.reject('conversation scope|conversation identity')
        for event in ('audioActivated', 'audioDeactivated'):
            with self.subTest(event=event):
                fixture(self.root)
                change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.audioEvent', name=event, count=1).update(
                    conversationID=CALL))
                self.reject('conversation scope')

    def test_control_ack_pid_nonce_and_pre_push_order(self):
        for suffix, edit in [('.session.json', lambda v: v.update(pid=999, notification='dev.callkitsim.control.999')),
                             ('.control.response.json', lambda v: v.update(pid=999)),
                             ('.control-binding.json', lambda v: v.update(nonce=PUSH)),
                             ('.control.request.json', lambda v: v['faults'].update(staleAudio=False)),
                             ('.control-ready.json', lambda v: v.update(case='livekit'))]:
            with self.subTest(suffix=suffix):
                fixture(self.root); change_json(self.root, 'sdk-m2-stale-audio' + suffix, edit)
                self.reject('session|fault command|nonce|readiness')
        fixture(self.root)
        change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.controlReady').update(staleAudio=True))
        self.reject('control not ready')

    def test_protocol_types_do_not_coerce_boolean_number_or_pid(self):
        edits = [('.session.json', lambda v: v.update(pid=124.0)),
                 ('.control.request.json', lambda v: v['faults'].update(staleAudio=1)),
                 ('.control.request.json', lambda v: v['faults'].update(reportCallbackDelayMS=False)),
                 ('.control.request.json', lambda v: v['faults'].update(invalidateDuringHandoff=0)),
                 ('.control-ready.json', lambda v: v.update(staleAudio=1)),
                 ('.control.response.json', lambda v: v.update(success=1))]
        for suffix, edit in edits:
            with self.subTest(suffix=suffix, edit=edit):
                fixture(self.root); change_json(self.root, 'sdk-m2-stale-audio' + suffix, edit)
                self.reject('session|fault command|readiness')
        fixture(self.root)
        change_rows(self.root, 'livekit', lambda rows: gate.one(rows, 'm2.audioEvent', name='audioActivated', count=1).update(count=True))
        self.reject('counter')
        fixture(self.root)
        name = 'sdk-m2-livekit'
        rows = gate.m0.load(self.root, name); rows[0]['sequence'] = True
        path = self.root / (name + '.log')
        path.write_text(''.join('PROBE ' + json.dumps(r) + '\n' for r in rows))
        receipt = json.loads((self.root / (name + '.receipt.json')).read_text())
        receipt['traceSHA256'] = gate.digest(path)
        write_json(self.root / (name + '.receipt.json'), receipt)
        self.reject('invalid process trace')

    def test_scalar_evidence_requires_integer_types(self):
        for event, field, value in [('m2.localTrack', 'count', True), ('m2.localTrackReleased', 'count', True),
                                     ('launch', 'traceVersion', 2.0)]:
            with self.subTest(event=event):
                fixture(self.root)
                change_rows(self.root, 'livekit', lambda rows: gate.one(rows, event).update({field: value}))
                self.reject('demand/release|trace version')
        for case, event, field, value in [('livekit', 'report.completed', 'error', False),
                                           ('stale-audio', 'report.ended', 'reason', True)]:
            with self.subTest(event=event):
                fixture(self.root)
                change_engine(self.root, case, lambda rows: gate.one(rows, event).update({field: value}))
                self.reject('correlation|failed report')
        fixture(self.root)
        change_json(self.root, 'sdk-m2-livekit.receipt.json', lambda receipt: receipt.update(launchExitCode=False))
        self.reject('supervisor')

    def test_source_install_cleanup_and_host_recovery(self):
        edits = [('source-after.json', lambda v: v.update(sourceCommit='c' * 40)),
                 ('installed.json', lambda v: v.update(javascriptSHA256='c' * 64)),
                 ('cleanup.json', lambda v: v.update(absentFromInventory=False)),
                 ('host-audio-controls.json', lambda v: v['result']['checks'].remove('default-activation-and-final-recovery-deadlines'))]
        for name, edit in edits:
            with self.subTest(name=name):
                fixture(self.root); change_json(self.root, name, edit)
                self.reject('source start/end|installed|cleanup|watchdog')

    def test_reentrancy_contract_requires_one_owner(self):
        change_rows(self.root, 'media-reentrancy', lambda rows: gate.one(rows, 'contract.mediaReentrancy').update(authorizationCalls=2, sameOwner=False))
        self.reject('singleton')

    def test_actual_install_app_preflight(self):
        for name, bundle in [('example', gate.EXAMPLE), ('contracts', gate.CONTRACTS)]:
            app = self.root / ('apps/' + name + '.app'); app.mkdir(parents=True)
            if name == 'example': shutil.copyfile(self.root / 'products/Info.plist', app / 'Info.plist')
            else: (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleExecutable='Example')))
            shutil.copyfile(self.root / ('binaries/' + name), app / 'Example')
            resources = app / 'IosVoipSDKRuntime.bundle'; resources.mkdir()
            shutil.copyfile(self.root / 'products/ios-27.0.json', resources / 'ios-27.0.json')
        shutil.copyfile(self.root / 'binaries/main.jsbundle', self.root / 'apps/example.app/main.jsbundle')
        framework = self.root / 'apps/example.app/Frameworks/LiveKitWebRTC.framework'; framework.mkdir(parents=True)
        shutil.copyfile(self.root / 'binaries/livekit-webrtc', framework / 'LiveKitWebRTC')
        shutil.copyfile(self.root / 'products/LiveKitWebRTC.Info.plist', framework / 'Info.plist')
        gate.validate_build(self.root, IDENTITY)
        (self.root / 'apps/example.app/main.jsbundle').write_bytes(b'stale javascript')
        with self.assertRaisesRegex(gate.EvidenceError, 'JS/Info'): gate.validate_build(self.root, IDENTITY)

    def test_runner_preflight_cleanup_handshake_and_teardown(self):
        with patch.object(runner, 'source_identity', return_value=IDENTITY), \
             patch.object(runner, 'validate_build', side_effect=RuntimeError('refused')), patch.object(runner, 'sim') as sim:
            with self.assertRaisesRegex(RuntimeError, 'refused'): runner.run(self.root / 'missing', self.root / 'not-created')
            sim.assert_not_called(); self.assertFalse((self.root / 'not-created').exists())
        cleanup = self.root / 'cleanup'; cleanup.mkdir(); seen = []
        def cleanup_sim(args, **kwargs):
            seen.append(args[0])
            if args[0] == 'shutdown': raise subprocess.TimeoutExpired('shutdown', 30)
            return subprocess.CompletedProcess(args, 0, b'{"devices":{}}' if args[0] == 'list' else b'', b'')
        with patch.object(runner, 'sim', side_effect=cleanup_sim): runner.cleanup(cleanup, 'owned')
        self.assertEqual(seen, ['shutdown', 'delete', 'list'])
        self.assertTrue(json.loads((cleanup / 'cleanup.json').read_text())['deleted'])
        def uncertain_create(args, **kwargs):
            if args[0] == 'create': raise subprocess.TimeoutExpired('create', 30)
            return subprocess.CompletedProcess(args, 0, json.dumps({'devices': {'runtime': [
                {'name': 'sdk-m2-run', 'udid': 'owned'}, {'name': 'other-qa', 'udid': 'unrelated'}]}}).encode(), b'')
        with patch.object(runner, 'sim', side_effect=uncertain_create), patch.object(runner, 'cleanup') as cleanup_mock:
            with self.assertRaises(subprocess.TimeoutExpired): runner.create_simulator(self.root, 'sdk-m2-run', 'runtime')
            cleanup_mock.assert_called_once_with(self.root, 'owned')
        out = self.root / 'runner-capture'; out.mkdir(); data = self.root / 'app-data'
        control = data / 'Documents/.callkit-simulator/run'
        (control / 'requests').mkdir(parents=True); (control / 'responses').mkdir(); (data / 'tmp').mkdir()
        name = 'sdk-m2-stale-audio'
        runner.write(data / 'Documents/.callkit-simulator/session.json', dict(schemaVersion=1, runID='run', pid=42,
            bundleID=runner.EXAMPLE, profile='ios-27.0', notification='dev.callkitsim.control.42'))
        def notify(args, **kwargs):
            self.assertEqual(args, ['spawn', 'owned', self.root / 'notifier', 'dev.callkitsim.control.42'])
            request = json.loads(next((control / 'requests').glob('*.json')).read_text())
            self.assertEqual(request['faults'], dict(staleAudio=True, reportCallbackDelayMS=0, invalidateDuringHandoff=False))
            self.assertFalse(list((data / 'tmp').glob('*.json')))
            runner.write(control / 'responses' / (request['id'] + '.json'), dict(
                **{k: request[k] for k in ('id', 'runID', 'pid', 'bundleID')}, success=True, result={'configured': True}))
            return subprocess.CompletedProcess(args, 0, b'', b'')
        with patch.object(runner, 'sim', side_effect=notify):
            runner.configure_faults(out, data, name, 'stale-audio', 'run', 'owned', SimpleNamespace(poll=lambda: None), self.root / 'notifier')
        self.assertEqual(json.loads((data / 'tmp/sdk-m2-control-run.json').read_text()),
                         dict(runID='run', case='stale-audio', pid=42, staleAudio=True))
        self.assertFalse((out / (name + '.log')).exists(), 'control must not require live console records')
        progress = json.loads((out / (name + '.handshake.json')).read_text())
        self.assertEqual([step['phase'] for step in progress['steps']], [
            'waiting-runtime-session', 'runtime-session-ready', 'notifying-runtime',
            'fault-acknowledged', 'ready-published'])
        process = SimpleNamespace(poll=Mock(return_value=None), wait=Mock(side_effect=[
            subprocess.TimeoutExpired('supervisor', 70), 0]), terminate=Mock(), kill=Mock())
        def stop_sim(args, **kwargs):
            if args[0] == 'get_app_container': return subprocess.CompletedProcess(args, 0, str(data).encode(), b'')
            raise subprocess.TimeoutExpired('terminate', 10)
        with patch.object(runner, 'sim', side_effect=stop_sim), patch.object(runner.subprocess, 'Popen', return_value=process):
            with self.assertRaises(subprocess.TimeoutExpired): runner.scenario(out, self.root, 'run', 'owned', '', 'media-reentrancy', 30)
        self.assertEqual(process.wait.call_count, 2)

    def test_runner_plain_example_console_preserves_contract_pty(self):
        data = self.root / 'launch-mode-data'; data.mkdir()
        session_path = data / 'Documents/.callkit-simulator/session.json'
        session_path.parent.mkdir(parents=True)
        for case in ('livekit', 'stale-audio', 'media-reentrancy'):
            with self.subTest(case=case):
                out = self.root / ('launch-mode-' + case); out.mkdir()
                runner.write(session_path, dict(schemaVersion=1, runID='run', pid=42, bundleID=runner.EXAMPLE,
                    profile='ios-27.0', notification='dev.callkitsim.control.42'))
                process = SimpleNamespace(wait=Mock(return_value=0), poll=Mock(return_value=0))
                def create_supervisor(*args, **kwargs):
                    self.assertEqual(session_path.exists(), case == 'media-reentrancy')
                    return process
                with patch.object(runner, 'sim', return_value=subprocess.CompletedProcess([], 0, str(data).encode(), b'')), \
                     patch.object(runner.subprocess, 'Popen', side_effect=create_supervisor) as launch, \
                     patch.object(runner, 'configure_faults') as faults:
                    runner.scenario(out, self.root, 'run', 'owned', '', case, 30)
                command = launch.call_args.args[0]
                self.assertIn('--console-launcher-stop', command)
                app_command = command[command.index('--launch-command') + 1:]
                self.assertEqual(app_command, ['xcrun', 'simctl', 'launch',
                    '--console-pty' if case == 'media-reentrancy' else '--console',
                    '--terminate-running-process', 'owned',
                    runner.CONTRACTS if case == 'media-reentrancy' else runner.EXAMPLE])
                self.assertEqual(faults.call_count, 0 if case == 'media-reentrancy' else 1)

    def test_runner_retires_only_validated_owned_session(self):
        data = self.root / 'retirement-data'; session_path = data / 'Documents/.callkit-simulator/session.json'
        session_path.parent.mkdir(parents=True)
        session = dict(schemaVersion=1, runID='run', pid=42, bundleID=runner.EXAMPLE,
                       profile='ios-27.0', notification='dev.callkitsim.control.42')
        for label, edits in [('run', {'runID': 'another-run'}), ('bundle', {'bundleID': 'other.app'}),
                ('profile', {'profile': 'unknown'}), ('pid', {'pid': True}),
                ('schema', {'schemaVersion': True}), ('notification', {'notification': 'other'}),
                ('extra', {'unexpected': 1})]:
            with self.subTest(label=label):
                out = self.root / ('refused-' + label); out.mkdir()
                raw = json.dumps(dict(session, **edits)).encode(); session_path.write_bytes(raw)
                with patch.object(runner, 'sim', return_value=subprocess.CompletedProcess([], 0, str(data).encode(), b'')), \
                     patch.object(runner.subprocess, 'Popen') as launch:
                    with self.assertRaisesRegex(RuntimeError, 'runtime session'):
                        runner.scenario(out, self.root, 'run', 'owned', '', 'livekit', 120)
                launch.assert_not_called(); self.assertEqual(session_path.read_bytes(), raw)
                self.assertFalse((out / 'sdk-m2-livekit.retired-session.json').exists())
        out = self.root / 'retirement-owned'; out.mkdir()
        raw = json.dumps(session).encode(); session_path.write_bytes(raw)
        runner.retire_session(out, data, 'case', 'run', 'owned')
        self.assertFalse(session_path.exists())
        self.assertEqual((out / 'case.retired-session.json').read_bytes(), raw)
        retired = json.loads((out / 'case.retirement.json').read_text())
        self.assertEqual((retired['retired'], retired['pid'], retired['simulatorID']), (True, 42, 'owned'))

    def test_runner_fresh_session_schema_and_phase_timeout(self):
        data = self.root / 'fresh-data'; path = data / 'Documents/.callkit-simulator/session.json'
        path.parent.mkdir(parents=True)
        session = dict(schemaVersion=1, runID='run', pid=42, bundleID=runner.EXAMPLE,
                       profile='ios-27.0', notification='dev.callkitsim.control.42')
        for label, edits in [('run', {'runID': 'stale'}), ('pid', {'pid': 0}),
                ('bundle', {'bundleID': 'another.app'}), ('profile', {'profile': 'unknown'}),
                ('schema', {'schemaVersion': 1.0}), ('notification', {'notification': 'other'})]:
            with self.subTest(label=label):
                out = self.root / ('fresh-refused-' + label); out.mkdir()
                path.write_text(json.dumps(dict(session, **edits)))
                with patch.object(runner, 'sim') as notify:
                    with self.assertRaisesRegex(RuntimeError, 'runtime session'):
                        runner.configure_faults(out, data, 'case', 'livekit', 'run', 'owned',
                            SimpleNamespace(poll=lambda: None), self.root / 'notifier')
                notify.assert_not_called()
                self.assertEqual(json.loads((out / 'case.handshake.json').read_text())['steps'][-1]['phase'],
                                 'runtime-session-failed')
        with patch.object(runner.time, 'monotonic', side_effect=[0, 0, 31]), patch.object(runner.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'runtime session: deadline before readiness'):
                runner.wait_for(lambda: None, 30, phase='runtime session')

    def test_runner_inherited_environment_is_preserved_or_refused(self):
        with patch.dict(os.environ, {}, clear=True):
            for stdout, expected in ((b'', ''), (b'\n', ''), (b' /a path.dylib \n', ' /a path.dylib '),
                                     (b'a\r\n', 'a\r'), (b'a\r', 'a\r'), (b'a\r\n\n', 'a\r\n')):
                with self.subTest(stdout=stdout), patch.object(runner, 'sim', return_value=subprocess.CompletedProcess([], 0, stdout, b'')):
                    self.assertEqual(runner.inherited_dyld('owned', self.root), expected)
            for status, stderr in ((1, b''), (0, b'diagnostic\n')):
                with self.subTest(status=status, stderr=stderr), patch.object(runner, 'sim', return_value=subprocess.CompletedProcess([], status, b'', stderr)):
                    with self.assertRaises(RuntimeError): runner.inherited_dyld('owned', self.root)
                self.assertIn('Query exit code:', (self.root / 'launch-environment-query.log').read_text())
            with patch.object(runner, 'sim', side_effect=subprocess.TimeoutExpired('launchctl', 60, stderr=b'hung\n')):
                with self.assertRaises(subprocess.TimeoutExpired): runner.inherited_dyld('owned', self.root)
            self.assertIn('timed out', (self.root / 'launch-environment-query.log').read_text())
            with patch.dict(os.environ, {'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': ' /explicit '}, clear=True), patch.object(runner, 'sim') as sim:
                self.assertEqual(runner.inherited_dyld('owned', self.root), ' /explicit ')
                sim.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
