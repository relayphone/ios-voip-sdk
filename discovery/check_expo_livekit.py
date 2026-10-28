#!/usr/bin/env python3
"""Synthetic gate/runner controls only; these do not measure a native engine."""
import hashlib
import json
from pathlib import Path
import plistlib
import queue
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, call, patch

import expo_livekit_conformance as gate
import run_expo_livekit as runner
import run_scenario as supervisor
from summarize import EvidenceError

IDENTITY = dict(sourceCommit='a' * 40, sourceInputsSHA256='b' * 64)
CALL, PUSH, NONCE = [str(uuid.UUID(int=n)).upper() for n in (100, 101, 102)]


def write(path, value):
    path.write_text(json.dumps(value) + '\n')


def log(root, name, rows, pid):
    for sequence, row in enumerate(rows, 1): row['sequence'] = sequence
    path = root / (name + '.log')
    path.write_text(gate.BUNDLE + ': ' + str(pid) + '\n' + ''.join('PROBE ' + json.dumps(r) + '\n' for r in rows))
    receipt = root / (name + '.receipt.json')
    value = json.loads(receipt.read_text()) if receipt.exists() else {}
    value['traceSHA256'] = gate.digest(path); write(receipt, value)


def fixture_case(root, case, pid):
    name = 'expo-livekit-' + case
    rows, engine = [], []
    clock, revision = 0, 0

    def add(event, at=None, **fields):
        nonlocal clock
        clock = max(clock + 1, at or 0)
        row = dict(event=event, t_ms=clock, wallTimeMS=1792627200000 + clock, main=True,
                   pid=pid, runID='run-1', simulatorID='sim-1', bundleID=gate.BUNDLE, **fields)
        rows.append(row); return row

    def assertion(label, call=None): add('m2.assertion', label=label, passed=True, conversationID=call)

    def snapshot(status=None, connected=False):
        nonlocal revision
        calls = [] if status is None else [dict(id=CALL, direction='incoming', status=status,
            isMuted=False, isVideo=False, hasConnectedAt=connected)]
        add('sdk.snapshot', revision=revision, conversations=calls); revision += 1

    def media(label, active=False, counts=(0, 0, 0, 0)):
        add('m2.mediaSnapshot', label=label, moduleID='existing-module', deviceID='existing-adm',
            inputAvailable=label == 'initial' or active, outputAvailable=label == 'initial' or active, isEngineRunning=active,
            category='AVAudioSessionCategoryAmbient' if label in ('initial', 'demand') else 'AVAudioSessionCategoryPlayAndRecord',
            mode='AVAudioSessionModeDefault' if label in ('initial', 'demand') else 'AVAudioSessionModeVoiceChat',
            **dict(zip(('activatedCount', 'deactivatedCount', 'missingCount', 'failedCount'), counts)))

    def handler(kind): add('m2.handler', kind=kind, conversationID=CALL, origin='app')

    def audio(name, count, at=None):
        scope = dict(conversationID=CALL) if name in ('audioActivationMissing', 'audioActivationFailed') else {}
        add('m2.audioEvent', at=at, name=name, count=count, **scope)
        add('m2.hookEvent', name=name, **scope)

    add('app.entry'); add('launch', mode='sdk-m2', case=case, traceVersion=2)
    add('sdk.activation', active=True); add('sdk.managerCreated', owner='VoIPApplication.start')
    snapshot(); media('initial')
    if case == 'stale-audio':
        acknowledged_at = 1792627200000 + clock
        add('m2.controlReady', staleAudio=True, requestID=NONCE, acknowledgedWallTimeMS=acknowledged_at)
    add('m2.pushInjected', pushID=PUSH, mustReport=True, label='primary')
    snapshot('ringing'); assertion('push-ringing', CALL); handler('join')
    add('m2.localTrack', count=1, enabled=True); demand = add('m2.recordingDemand', accepted=True)
    media('demand'); snapshot('connecting'); assertion('joined', CALL)
    snapshot('connected', True); assertion('backend-connected', CALL)
    if case == 'livekit':
        audio('audioActivated', 1); media('active', True, (1, 0, 0, 0))
        handler('hold'); snapshot('held', True); audio('audioDeactivated', 1); media('held', False, (1, 1, 0, 0))
        handler('hold'); snapshot('connected', True); audio('audioActivated', 2); media('resumed', True, (2, 1, 0, 0))
        handler('end'); snapshot('ended', True); snapshot(); audio('audioDeactivated', 2); media('ended', False, (2, 2, 0, 0))
        assertion('ended-empty-with-demand', CALL)
    else:
        audio('audioActivationMissing', 1, at=demand['t_ms'] + 10000)
        audio('audioActivationFailed', 1, at=demand['t_ms'] + 15000)
        snapshot('ended', True); snapshot(); media('failed', False, (0, 0, 1, 1))
        assertion('stale-ended-empty-with-demand', CALL)
    add('m2.localTrackReleased', count=1); add('m2.result', success=True); add('done')
    receipt = dict(schemaVersion=2, success=True, completed=True, launchExitCode=0, lastProbeEvent='done',
        runID='run-1', simulatorID='sim-1', bundleID=gate.BUNDLE, scenario=name, appPID=pid, launcherAppPID=pid,
        launcherPID=9999, terminationMethod='console-launcher-signal', terminationSignal=15, terminationSignalDelivered=True,
        consoleTransport='host-pty', appAbsenceMethod='signal-zero', appAbsentAfterStop=True,
        inheritLauncherGroup=True, supervisorPID=pid + 1000, supervisorPGID=pid + 1000,
        supervisorSID=pid + 1000, launcherPGID=pid + 1000)
    write(root / (name + '.receipt.json'), receipt); log(root, name, rows, pid)

    def native(event, **fields):
        engine.append(dict(event=event, sequence=len(engine) + 1, t_ms=len(engine), runID='run-1', pid=pid,
                           bundleID=gate.BUNDLE, profile='ios-27.0', **fields))

    def changed(connected, held, ended): native('call.changed', uuid=CALL, outgoing=False, connected=connected, held=held, ended=ended)

    native('runtime.installed', version=(gate.ROOT / 'VERSION').read_text().strip())
    native('provider.created', provider='one-provider')
    native('push.received', pushID=PUSH, api='metadata', mustReport=True)
    native('report.incoming', pushID=PUSH, callUUID=CALL); changed(False, False, False)
    native('report.completed', pushID=PUSH, callUUID=CALL, error=0)
    for event in ('push.completed', 'push.callbackReturned'):
        native(event, pushID=PUSH, api='metadata', mustReport=True, reportEntered=True)
    kinds = ['CXAnswerCallAction', 'CXSetHeldCallAction', 'CXSetHeldCallAction', 'CXEndCallAction'] if case == 'livekit' else ['CXAnswerCallAction']
    for i, kind in enumerate(kinds):
        action = str(uuid.UUID(int=i + 1)).upper()
        native('transaction.delivered', provider='one-provider', actionIDs=[action], kinds=[kind])
        native('action.settled', actionID=action, fulfilled=True); changed(True, i == 1, i == 3)
        if case == 'livekit': native('audio.activated' if i in (0, 2) else 'audio.deactivated')
    if case == 'stale-audio':
        native('fault.audioSuppressed'); native('report.ended', callUUID=CALL, reason=1); changed(True, False, True)
    journal = root / (name + '.runtime.jsonl')
    journal.write_text(''.join(json.dumps(r) + '\n' for r in engine))
    receipt = gate.read(root, name + '.receipt.json'); receipt['journalSHA256'] = gate.digest(journal)
    write(root / (name + '.receipt.json'), receipt)
    if case == 'stale-audio':
        write(root / (name + '.session.json'), dict(schemaVersion=1, runID='run-1', pid=pid, bundleID=gate.BUNDLE,
              profile='ios-27.0', notification=f'dev.callkitsim.control.{pid}', controlTransport='directory-watch-v1'))
        write(root / (name + '.request.json'), dict(id=NONCE, runID='run-1', pid=pid, bundleID=gate.BUNDLE,
              operation='faults', faults=dict(staleAudio=True, reportCallbackDelayMS=0, invalidateDuringHandoff=False)))
        write(root / (name + '.response.json'), dict(id=NONCE, runID='run-1', pid=pid, bundleID=gate.BUNDLE,
              success=True, result=dict(configured=True)))
        write(root / (name + '.ready.json'), dict(runID='run-1', case=case, pid=pid, staleAudio=True,
              requestID=NONCE, acknowledgedWallTimeMS=acknowledged_at))


def fixture(root):
    build, capture = root / 'build', root / 'capture'; build.mkdir(); capture.mkdir()
    for name in gate.PRODUCT_FILES:
        path = build / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('synthetic ' + name)
    source = (gate.ROOT / 'Sources/Engine/RuntimeEngine.swift').read_text()
    payload = source.split('  private static let embeddedProfileJSON = #"""\n')[1].split('\n"""#\n')[0].encode()
    (build / gate.APP_FILES[0]).write_bytes(b'synthetic executable\0' + payload)
    (build / 'ios-27.0.json').write_bytes((gate.ROOT / 'Sources/Engine/Resources/ios-27.0.json').read_bytes())
    (build / 'example.app/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=gate.BUNDLE,
        CFBundleExecutable='VoIPSDKExample', VoIPSDK=dict(mediaAdapter='livekit', simulatorSupport=True),
        UIBackgroundModes=['voip', 'audio'], NSMicrophoneUsageDescription='Local fixture capture.')))
    (build / gate.APP_FILES[-1]).write_bytes(plistlib.dumps(dict(CFBundleIdentifier='io.livekit.LiveKitWebRTC', CFBundleExecutable='LiveKitWebRTC')))
    write(build / 'Podfile.properties.json', {'ios-voip-sdk.mediaAdapter': 'livekit'})
    write(build / 'IosVoipSDK.podspec.json', dict(source_files=['Sources/**/*.{swift,h,m}', 'Expo/apple/**/*.{swift,h}',
        'ExpoMedia/Shared/ExpoMediaSupport.swift', 'ExpoMedia/LiveKit/**/*.{swift,h,m}', 'ExpoMedia/Shared/VSMediaBinding.h',
        'ExpoMedia/Shared/QueuedMediaAdapter.swift'], dependencies={'ExpoModulesCore': [], 'React-Core': [], 'livekit-react-native-webrtc': ['= 150.1.0']}))
    (build / 'Podfile.lock').write_text('PODS:\n  - livekit-react-native (3.1.0):\n  - livekit-react-native-webrtc (150.1.0):\n  - LiveKitWebRTC (150.7871.03)\n')
    write(build / 'build.json', dict(schemaVersion=1, product='expo-livekit', configuration='Release', sourceBefore=IDENTITY,
        sourceAfter=IDENTITY, sdkVersion='27.1', files=gate.product_files(build), versions=gate.VERSIONS))
    write(capture / 'capture.json', dict(schemaVersion=1, source=IDENTITY, runID='run-1', simulatorID='sim-1',
        runtime=dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', version='27.0', buildversion='synthetic'),
        installed={k: gate.digest(build / k) for k in gate.APP_FILES}, buildSHA256=gate.digest(build / 'build.json'),
        supervisorPIDs=dict(livekit=1123, **{'stale-audio': 1124}), supervisorGroupsAbsent=dict.fromkeys(gate.CASES, True),
        inheritedExternalDYLD=dict(present=False, sha256=hashlib.sha256(b'').hexdigest())))
    write(capture / 'cleanup.json', dict(simulatorID='sim-1', deleted=True, absent=True, deleteExitCode=0))
    for case, pid in zip(gate.CASES, (123, 124)): fixture_case(capture, case, pid)
    return build, capture


def change_json(path, change):
    value = json.loads(path.read_text()); change(value); write(path, value)


def change_rows(capture, case, change, engine=False):
    name = 'expo-livekit-' + case
    path = capture / (name + ('.runtime.jsonl' if engine else '.log'))
    rows = [json.loads(line if engine else line.split('PROBE ', 1)[1]) for line in path.read_text().splitlines() if engine or 'PROBE ' in line]
    change(rows)
    if engine:
        for index, row in enumerate(rows, 1): row['sequence'] = index
        path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
        change_json(capture / (name + '.receipt.json'), lambda r: r.update(journalSHA256=gate.digest(path)))
    else: log(capture, name, rows, rows[0]['pid'])


class GateControls(unittest.TestCase):
    def reject(self, change):
        with tempfile.TemporaryDirectory(prefix='expo-livekit-synthetic-') as temporary, patch.object(gate, 'source_identity', return_value=IDENTITY):
            build, capture = fixture(Path(temporary)); change(build, capture)
            with self.assertRaises((EvidenceError, OSError)) as rejected: gate.validate(build, capture)
            return str(rejected.exception)

    def test_synthetic_positive_is_only_a_gate_control(self):
        with tempfile.TemporaryDirectory(prefix='expo-livekit-synthetic-') as temporary, patch.object(gate, 'source_identity', return_value=IDENTITY):
            result = gate.validate(*fixture(Path(temporary)))
            self.assertEqual(set(result['cases']), {'livekit', 'stale-audio'})

    def test_handler_demand_preserves_the_observed_initial_session(self):
        with tempfile.TemporaryDirectory(prefix='expo-livekit-synthetic-') as temporary, patch.object(gate, 'source_identity', return_value=IDENTITY):
            build, capture = fixture(Path(temporary))
            for case in gate.CASES:
                change_rows(capture, case, lambda rows: [r.update(category='AVAudioSessionCategoryPlayback',
                    mode='AVAudioSessionModeMoviePlayback') for r in rows
                    if r['event'] == 'm2.mediaSnapshot' and r['label'] in ('initial', 'demand')])
            self.assertTrue(gate.validate(build, capture)['success'])

    def test_handler_demand_cannot_configure_category_or_mode_early(self):
        for case in gate.CASES:
            for field, value in [('category', 'AVAudioSessionCategoryPlayAndRecord'), ('mode', 'AVAudioSessionModeVoiceChat')]:
                with self.subTest(case=case, field=field):
                    self.reject(lambda b, c: change_rows(c, case, lambda rows: next(r for r in rows
                        if r['event'] == 'm2.mediaSnapshot' and r['label'] == 'demand').update({field: value})))

    def test_fulfilled_action_requires_category_and_mode(self):
        for label in ('active', 'held', 'resumed', 'ended'):
            for field, value in [('category', 'AVAudioSessionCategoryAmbient'), ('mode', 'AVAudioSessionModeDefault')]:
                with self.subTest(label=label, field=field):
                    self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
                        if r['event'] == 'm2.mediaSnapshot' and r['label'] == label).update({field: value})))

    def test_native_running_identity_and_scope_are_required(self):
        for event, fields in [('m2.mediaSnapshot', dict(label='active', isEngineRunning=False)),
                              ('m2.mediaSnapshot', dict(label='held', inputAvailable=True)),
                              ('m2.mediaSnapshot', dict(label='resumed', deviceID='replacement-adm')),
                              ('m2.mediaSnapshot', dict(label='resumed', moduleID='replacement-module'))]:
            with self.subTest(fields=fields):
                self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows if r['event'] == event and r.get('label') == fields['label']).update(fields)))
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows if r['event'] == 'm2.audioEvent').update(conversationID=PUSH)))
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in reversed(rows) if r['event'] == 'sdk.snapshot' and r['conversations'] and r['conversations'][0]['status'] == 'connected')['conversations'][0].update(hasConnectedAt=False)))

    def test_every_media_stage_requires_typed_availability_and_exact_counters(self):
        labels = ('initial', 'demand', 'active', 'held', 'resumed', 'ended')
        for label in labels:
            for field in ('inputAvailable', 'outputAvailable', 'isEngineRunning'):
                values = [1] if label == 'initial' and field != 'isEngineRunning' else [1, label not in ('active', 'resumed')]
                for value in values:
                    with self.subTest(label=label, field=field, value=value):
                        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
                            if r['event'] == 'm2.mediaSnapshot' and r['label'] == label).update({field: value})))
            for field in ('activatedCount', 'deactivatedCount', 'missingCount', 'failedCount'):
                for value in (True, 99):
                    with self.subTest(label=label, field=field, value=value):
                        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
                            if r['event'] == 'm2.mediaSnapshot' and r['label'] == label).update({field: value})))

    def test_media_inventory_and_observer_counts_are_independent(self):
        for event in ('m2.mediaSnapshot', 'm2.audioEvent'):
            with self.subTest(event=event):
                self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: rows.remove(next(r for r in rows if r['event'] == event))))
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
            if r['event'] == 'm2.audioEvent').update(count=2)))
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
            if r['event'] == 'm2.mediaSnapshot').update(moduleID='')))

    def test_public_audio_delivery_cannot_be_replaced_by_native_observations(self):
        for fault in ('missing', 'duplicate', 'wrong-name', 'scoped', 'scoped-alias', 'before-demand', 'after-result', 'provider-reset'):
            def change(rows):
                hook = next(r for r in rows if r['event'] == 'm2.hookEvent')
                if fault == 'missing': rows.remove(hook)
                elif fault == 'duplicate': rows.insert(rows.index(hook), dict(hook))
                elif fault == 'wrong-name': hook['name'] = 'audioActivationMissing'
                elif fault == 'scoped': hook['conversationID'] = CALL
                elif fault == 'scoped-alias': hook['conversationId'] = CALL
                elif fault == 'provider-reset': rows.insert(rows.index(hook), {**hook, 'name': 'providerReset'})
                else:
                    rows.remove(hook)
                    marker = next(r for r in rows if r['event'] == ('m2.recordingDemand' if fault == 'before-demand' else 'm2.result'))
                    rows.insert(rows.index(marker) + (fault == 'after-result'), hook)
            with self.subTest(fault=fault):
                self.reject(lambda b, c: change_rows(c, 'livekit', change))

    def test_boundary_markers_and_local_track_cleanup_are_required(self):
        for fields in (dict(passed=1), dict(passed=False), dict(conversationID=None), dict(conversationID=PUSH)):
            with self.subTest(fields=fields):
                self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
                    if r['event'] == 'm2.assertion').update(fields)))
        for event, fields in (('m2.localTrack', dict(count=2)), ('m2.localTrack', dict(enabled=False)),
                              ('m2.recordingDemand', dict(accepted=1)), ('m2.localTrackReleased', dict(count=0))):
            with self.subTest(event=event, fields=fields):
                self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
                    if r['event'] == event).update(fields)))
        def premature_release(rows):
            release = next(r for r in rows if r['event'] == 'm2.localTrackReleased')
            rows.remove(release); rows.insert(rows.index(next(r for r in rows if r['event'] == 'm2.recordingDemand')), release)
        self.reject(lambda b, c: change_rows(c, 'livekit', premature_release))

    def test_healthy_case_cannot_gain_a_fault_or_another_scenario(self):
        def suppressed(rows):
            rows.append({**rows[-1], 'event': 'fault.audioSuppressed'})
        self.reject(lambda b, c: change_rows(c, 'livekit', suppressed, engine=True))
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows
            if r['event'] == 'launch').update(case='other')))
        self.reject(lambda b, c: change_json(c / 'capture.json', lambda row: row['supervisorPIDs'].update(other=1124)))

    def test_stale_ack_allows_additive_result_metadata_and_checks_known_fields(self):
        for result, accepted in (
            (dict(configured=True), True), (dict(configured=True, incomingErrorCode=0), True),
            (dict(configured=True, incomingErrorCode=0, diagnostic='configured'), True),
            (dict(configured=True, diagnostic='configured'), True),
            (dict(configured=True, incomingErrorCode=0, extra=True), True),
            (dict(configured=True, metadata=dict(native=dict(attempts=[1, 2]))), True),
            (dict(configured=True, incomingErrorCode=0, metadata=dict(details=[dict(phase='ready')])), True),
            (dict(configured=False), False), (dict(configured=1), False), ({}, False),
            (dict(configured=True, incomingErrorCode=False), False),
            (dict(configured=True, incomingErrorCode=0.0), False),
            (dict(configured=True, incomingErrorCode='0'), False),
            (dict(configured=True, incomingErrorCode=None), False),
            (dict(configured=True, incomingErrorCode=3), False), ([], False), (None, False),
        ):
            with self.subTest(result=result), tempfile.TemporaryDirectory(prefix='expo-stale-ack-') as temporary, \
                 patch.object(gate, 'source_identity', return_value=IDENTITY):
                build, capture = fixture(Path(temporary))
                change_json(capture / 'expo-livekit-stale-audio.response.json', lambda row: row.update(result=result))
                if accepted: self.assertTrue(gate.validate(build, capture)['success'])
                else:
                    with self.assertRaises(EvidenceError): gate.validate(build, capture)

    def test_stale_session_request_ack_and_readiness_bind_the_current_process(self):
        expected = {
            '.session.json': ('schemaVersion', 'runID', 'pid', 'bundleID', 'profile', 'notification', 'controlTransport'),
            '.request.json': ('id', 'runID', 'pid', 'bundleID', 'operation', 'faults'),
            '.response.json': ('id', 'runID', 'pid', 'bundleID', 'success', 'result'),
            '.ready.json': ('runID', 'case', 'pid', 'staleAudio', 'requestID', 'acknowledgedWallTimeMS'),
        }
        for suffix, fields in expected.items():
            for field in fields:
                for fault in ('missing', 'wrong-type', 'wrong-value'):
                    def change(row):
                        if fault == 'missing': row.pop(field)
                        elif fault == 'wrong-type': row[field] = 1 if field in ('success', 'staleAudio') else True
                        else: row[field] = 'previous'
                    with self.subTest(suffix=suffix, field=field, fault=fault):
                        self.reject(lambda b, c: change_json(c / ('expo-livekit-stale-audio' + suffix), change))
        for suffix, fields in (
            ('.session.json', dict(pid=123)), ('.session.json', dict(controlTransport='notify-v1')),
            ('.request.json', dict(id='not-a-uuid')), ('.request.json', dict(pid=123)),
            ('.request.json', dict(faults=dict(staleAudio=False, reportCallbackDelayMS=0, invalidateDuringHandoff=False))),
            ('.response.json', dict(id=PUSH)), ('.response.json', dict(pid=123)),
            ('.response.json', dict(diagnostic=dict(configured=True))),
            ('.ready.json', dict(case='livekit')), ('.ready.json', dict(staleAudio=False)),
        ):
            with self.subTest(suffix=suffix, fields=fields):
                self.reject(lambda b, c: change_json(c / ('expo-livekit-stale-audio' + suffix), lambda row: row.update(fields)))

    def test_stale_readiness_is_bound_to_the_acknowledged_nonce(self):
        def substitute_ack(build, capture):
            for suffix in ('.request.json', '.response.json'):
                change_json(capture / ('expo-livekit-stale-audio' + suffix),
                            lambda row: row.update(id=PUSH))
        self.reject(substitute_ack)

    def test_stale_ack_time_is_bound_to_native_readiness(self):
        def change(rows):
            next(row for row in rows if row['event'] == 'm2.controlReady')['acknowledgedWallTimeMS'] = 1
        self.reject(lambda b, c: change_rows(c, 'stale-audio', change))

    def test_stale_matching_ack_cannot_arrive_after_push(self):
        def late_ack(build, capture):
            def change(rows):
                after_push = next(row['wallTimeMS'] for row in rows if row['event'] == 'm2.pushInjected') + 1
                next(row for row in rows if row['event'] == 'm2.controlReady')['acknowledgedWallTimeMS'] = after_push
                change_json(capture / 'expo-livekit-stale-audio.ready.json',
                            lambda row: row.update(acknowledgedWallTimeMS=after_push))
            change_rows(capture, 'stale-audio', change)
        self.reject(late_ack)

    def test_stale_native_control_readiness_precedes_push_and_is_not_healthy_setup(self):
        for fault in ('missing', 'false', 'boolean-type', 'before-initial', 'after-push'):
            def change(rows):
                ready = next(row for row in rows if row['event'] == 'm2.controlReady')
                if fault == 'missing': rows.remove(ready)
                elif fault == 'false': ready['staleAudio'] = False
                elif fault == 'boolean-type': ready['staleAudio'] = 1
                else:
                    rows.remove(ready)
                    marker = next(row for row in rows if row['event'] == ('m2.mediaSnapshot' if fault == 'before-initial' else 'm2.pushInjected'))
                    ready['t_ms'] = marker['t_ms']
                    rows.insert(rows.index(marker) + (fault == 'after-push'), ready)
            with self.subTest(fault=fault):
                reason = self.reject(lambda b, c: change_rows(c, 'stale-audio', change))
                if fault in ('before-initial', 'after-push'): self.assertIn('fault control must precede push', reason)
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: rows.insert(5, {**rows[0], 'event': 'm2.controlReady', 'staleAudio': False})))

    def test_each_public_watchdog_event_is_required_once_with_the_exact_call(self):
        for name in ('audioActivationMissing', 'audioActivationFailed'):
            for fault in ('missing', 'wrong-id', 'missing-id', 'alias-id', 'duplicate', 'reorder'):
                def change(rows):
                    hook = next(row for row in rows if row['event'] == 'm2.hookEvent' and row['name'] == name)
                    if fault == 'missing': rows.remove(hook)
                    elif fault == 'wrong-id': hook['conversationID'] = PUSH
                    elif fault == 'missing-id': hook.pop('conversationID')
                    elif fault == 'alias-id': hook['conversationId'] = hook.pop('conversationID')
                    elif fault == 'duplicate': rows.insert(rows.index(hook), dict(hook))
                    else:
                        other = next(row for row in rows if row['event'] == 'm2.hookEvent' and row is not hook)
                        hook['name'], other['name'] = other['name'], hook['name']
                with self.subTest(name=name, fault=fault):
                    reason = self.reject(lambda b, c: change_rows(c, 'stale-audio', change))
                    if fault == 'reorder': self.assertIn('public audio event delivery/scope differs', reason)

    def test_stale_engine_identity_session_and_zero_availability_remain_observed(self):
        for label in ('demand', 'failed'):
            for field in ('inputAvailable', 'outputAvailable', 'isEngineRunning'):
                with self.subTest(label=label, field=field):
                    self.reject(lambda b, c: change_rows(c, 'stale-audio', lambda rows: next(row for row in rows
                        if row['event'] == 'm2.mediaSnapshot' and row['label'] == label).update({field: True})))
        for field, value in (('moduleID', 'other'), ('deviceID', 'other'), ('activatedCount', 1),
                             ('deactivatedCount', 1), ('missingCount', 0), ('failedCount', 0),
                             ('failedCount', True), ('category', 'AVAudioSessionCategoryAmbient'),
                             ('mode', 'AVAudioSessionModeDefault')):
            with self.subTest(field=field):
                self.reject(lambda b, c: change_rows(c, 'stale-audio', lambda rows: next(row for row in rows
                    if row['event'] == 'm2.mediaSnapshot' and row['label'] == 'failed').update({field: value})))

    def test_stale_default_watchdogs_and_native_failure_end_cannot_be_substituted(self):
        for missing_delay in (1000, 9000, 9800):
            def early_watchdog(rows):
                missing = next(row for row in rows if row['event'] == 'm2.audioEvent' and row['name'] == 'audioActivationMissing')
                demand = next(row for row in rows if row['event'] == 'm2.recordingDemand')
                delta = missing['t_ms'] - demand['t_ms'] - missing_delay
                for row in rows[rows.index(missing):]: row['t_ms'] -= delta
            with self.subTest(missing_delay=missing_delay):
                self.reject(lambda b, c: change_rows(c, 'stale-audio', early_watchdog))
        for name, timestamp in (('audioActivationMissing', 14000), ('audioActivationFailed', 2000), ('audioActivationFailed', 20000)):
            with self.subTest(name=name, timestamp=timestamp):
                self.reject(lambda b, c: change_rows(c, 'stale-audio', lambda rows: next(row for row in rows
                    if row['event'] == 'm2.audioEvent' and row['name'] == name).update(t_ms=timestamp)))
        for event, fields in (('report.ended', dict(reason=2)), ('transaction.delivered', dict(kinds=['CXEndCallAction']))):
            with self.subTest(event=event):
                self.reject(lambda b, c: change_rows(c, 'stale-audio', lambda rows: next(row for row in rows
                    if row['event'] == event).update(fields), engine=True))
        self.reject(lambda b, c: change_rows(c, 'stale-audio', lambda rows: rows.remove(next(row for row in rows
            if row['event'] == 'fault.audioSuppressed')), engine=True))
        self.reject(lambda b, c: change_rows(c, 'stale-audio', lambda rows: next(row for row in rows
            if row['event'] == 'm2.handler').update(kind='end')))

    def test_journal_and_push_boundaries_are_independent(self):
        for event, fields in [('call.changed', dict(uuid=PUSH)), ('action.settled', dict(fulfilled=False)),
                              ('push.callbackReturned', dict(reportEntered=False))]:
            with self.subTest(event=event):
                self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: next(r for r in rows if r['event'] == event).update(fields), engine=True))
        self.reject(lambda b, c: change_rows(c, 'livekit', lambda rows: rows.remove(next(r for r in rows if r['event'] == 'audio.deactivated')), engine=True))


    def test_current_supervisor_proof_and_one_pid_header_are_required(self):
        for fields in [dict(consoleTransport='pipe'), dict(appAbsenceMethod='command'), dict(appAbsentAfterStop=False),
                       dict(launcherAppPID=999), dict(schemaVersion=2.0), dict(terminationMethod='command', terminateExitCode=0)]:
            with self.subTest(fields=fields):
                self.reject(lambda b, c: change_json(c / 'expo-livekit-livekit.receipt.json', lambda r: r.update(fields)))
        def duplicate_header(build, capture):
            path = capture / 'expo-livekit-livekit.log'; path.write_text(path.read_text() + gate.BUNDLE + ': 123\n')
            change_json(capture / 'expo-livekit-livekit.receipt.json', lambda r: r.update(traceSHA256=gate.digest(path)))
        self.reject(duplicate_header)

    def test_source_products_install_and_cleanup_are_bound(self):
        self.reject(lambda b, c: (b / gate.APP_FILES[1]).write_text('changed JS'))
        for path, fields in [('capture.json', dict(source={})), ('capture.json', dict(installed={})),
                             ('capture.json', dict(buildSHA256='0' * 64)), ('cleanup.json', dict(absent=False)),
                             ('cleanup.json', dict(deleteExitCode=False))]:
            with self.subTest(path=path, fields=fields):
                self.reject(lambda b, c: change_json(c / path, lambda r: r.update(fields)))
        self.reject(lambda b, c: change_json(b / 'build.json', lambda r: r['versions'].update({'@livekit/react-native-webrtc': '155.0.1'})))
        self.reject(lambda b, c: change_json(c / 'capture.json', lambda r: r['runtime'].update(
            version='27.1', identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-1')))

    def test_supervisor_group_binding_and_absence_are_required(self):
        for fields in [dict(inheritLauncherGroup=False), dict(supervisorPID=123), dict(supervisorPGID=999),
                       dict(supervisorSID=999), dict(launcherPGID=999), dict(supervisorSID=1123.0), dict(launcherPID=123)]:
            with self.subTest(fields=fields):
                self.reject(lambda b, c: change_json(c / 'expo-livekit-livekit.receipt.json', lambda r: r.update(fields)))
        for fields in [dict(supervisorPIDs={}), dict(supervisorPIDs=dict.fromkeys(gate.CASES, True)),
                       dict(supervisorGroupsAbsent=dict.fromkeys(gate.CASES, False)), dict(supervisorGroupsAbsent=dict.fromkeys(gate.CASES, 1))]:
            with self.subTest(fields=fields):
                self.reject(lambda b, c: change_json(c / 'capture.json', lambda r: r.update(fields)))


class RunnerControls(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(runner.os.environ, {'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': ''})
        environment.start(); self.addCleanup(environment.stop)
        patcher = patch.object(runner.os, 'killpg', side_effect=ProcessLookupError)
        self.killpg = patcher.start(); self.addCleanup(patcher.stop)

    def control_fixture(self, root):
        data, out = root / 'data', root / 'out'
        runtime = data / 'Documents/.callkit-simulator/run'
        for path in (out, data / 'tmp', runtime / 'requests', runtime / 'responses'):
            path.mkdir(parents=True)
        session = dict(schemaVersion=1, runID='run', pid=123, bundleID=gate.BUNDLE,
            profile='ios-27.0', notification='dev.callkitsim.control.123', controlTransport='directory-watch-v1')
        write(runtime.parent / 'session.json', session)
        trace = out / 'expo-livekit-stale-audio.log'
        rows = [dict(event=event, wallTimeMS=1000, pid=123, runID='run', bundleID=gate.BUNDLE)
                for event in ('app.entry', 'launch')]
        trace.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
        return data, out, runtime, trace, session

    def test_directory_watcher_ack_releases_only_the_matching_native_barrier(self):
        for result in (dict(configured=True), dict(configured=True, incomingErrorCode=0,
                metadata=dict(details=[dict(phase='ready')]))):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as temporary:
                data, out, runtime, trace, session = self.control_fixture(Path(temporary).resolve())
                ready_path = data / 'tmp/sdk-m2-control-run.json'
                retained = out / 'expo-livekit-stale-audio.ready.json'
                original_trace = trace.read_bytes(); received = []
                def checkpoint(process, condition, seconds):
                    self.assertEqual(seconds, 10)
                    self.assertFalse(ready_path.exists()); self.assertFalse(retained.exists())
                    if len(received) == 0:
                        # A previous process's same-run session cannot authorize
                        # a command for the process whose entry was just observed.
                        write(runtime.parent / 'session.json', {**session, 'pid': 122})
                        self.assertIsNone(condition())
                        self.assertEqual(list((runtime / 'requests').iterdir()), [])
                        write(runtime.parent / 'session.json', session)
                    else:
                        request_path, = (runtime / 'requests').iterdir()
                        request = json.loads(request_path.read_text())
                        self.assertEqual(request, dict(id=NONCE, runID='run', pid=123, bundleID=gate.BUNDLE,
                            operation='faults', faults=dict(staleAudio=True, reportCallbackDelayMS=0,
                            invalidateDuringHandoff=False)))
                        self.assertEqual(request_path.name, NONCE + '.json')
                        self.assertEqual(request_path.stat().st_mode & 0o777, 0o600)
                        self.assertIsNone(condition())
                        write(runtime / 'responses' / request_path.name,
                            dict(id=NONCE, runID='run', pid=123, bundleID=gate.BUNDLE, success=True, result=result))
                    received.append(condition())
                    return received[-1]
                with patch.object(runner, 'wait', side_effect=checkpoint), \
                     patch.object(runner.uuid, 'uuid4', return_value=uuid.UUID(NONCE)), \
                     patch.object(runner.time, 'time_ns', return_value=2_000_000_000), \
                     patch.object(runner.subprocess, 'Popen', side_effect=AssertionError('no control RPC')):
                    runner.stale_audio(Mock(), trace, data, out, 'run', 123)
                self.assertEqual(gate.read(out, 'expo-livekit-stale-audio.session.json'), session)
                self.assertEqual(gate.read(out, 'expo-livekit-stale-audio.response.json')['result'], result)
                ready = dict(runID='run', case='stale-audio', pid=123, staleAudio=True,
                    requestID=NONCE, acknowledgedWallTimeMS=2000)
                self.assertEqual(json.loads(ready_path.read_text()), ready)
                self.assertEqual(ready_path.read_bytes(), retained.read_bytes())
                self.assertEqual(ready_path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(list((data / 'tmp').iterdir()), [ready_path])
                self.assertEqual(trace.read_bytes(), original_trace)

    def test_fault_session_must_be_fresh_exact_and_native_before_any_command(self):
        mutations = [lambda row, key=key: row.pop(key) for key in (
            'schemaVersion', 'runID', 'pid', 'bundleID', 'profile', 'notification', 'controlTransport')]
        mutations += [lambda row, key=key, value=value: row.update({key: value}) for key, value in (
            ('schemaVersion', True), ('runID', 'old-run'), ('pid', 122), ('pid', True),
            ('bundleID', 'foreign'), ('profile', 'other'), ('notification', 'dev.callkitsim.control.122'),
            ('controlTransport', 'notify-v1'), ('extra', 1))]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as temporary:
                data, out, runtime, trace, session = self.control_fixture(Path(temporary).resolve())
                mutate(session); write(runtime.parent / 'session.json', session)
                def checkpoint(process, condition, seconds):
                    value = condition()
                    if value is None: raise RuntimeError('fixture checkpoint deadline')
                    return value
                with patch.object(runner, 'wait', side_effect=checkpoint), self.assertRaises(RuntimeError):
                    runner.stale_audio(Mock(), trace, data, out, 'run', 123)
                self.assertEqual(list((runtime / 'requests').iterdir()), [])
                self.assertEqual(list((data / 'tmp').iterdir()), [])
                self.assertFalse((out / 'expo-livekit-stale-audio.ready.json').exists())

    def test_fault_ack_rejects_wrong_nonce_identity_types_and_failures_without_readiness(self):
        mutations = [lambda row, key=key: row.pop(key) for key in
            ('id', 'runID', 'pid', 'bundleID', 'success', 'result')]
        mutations += [lambda row, key=key, value=value: row.update({key: value}) for key, value in (
            ('id', CALL), ('runID', 'old-run'), ('pid', 122), ('pid', True), ('bundleID', 'foreign'),
            ('success', False), ('success', 1), ('extra', 1), ('result', None), ('result', {}),
            ('result', dict(configured=1)), ('result', dict(configured=False)),
            ('result', dict(configured=True, incomingErrorCode=1)),
            ('result', dict(configured=True, incomingErrorCode=False)),
            ('result', dict(configured=True, incomingErrorCode='0')),
            ('result', dict(configured=True, incomingErrorCode=None)))]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as temporary:
                data, out, runtime, trace, _ = self.control_fixture(Path(temporary).resolve())
                def checkpoint(process, condition, seconds):
                    paths = list((runtime / 'requests').iterdir())
                    if paths:
                        request = json.loads(paths[0].read_text())
                        response = {key: request[key] for key in ('id', 'runID', 'pid', 'bundleID')}
                        response.update(success=True, result=dict(configured=True))
                        mutate(response); write(runtime / 'responses' / paths[0].name, response)
                    return condition()
                with patch.object(runner, 'wait', side_effect=checkpoint), self.assertRaisesRegex(RuntimeError, 'ACK'):
                    runner.stale_audio(Mock(), trace, data, out, 'run', 123)
                self.assertEqual(list((data / 'tmp').iterdir()), [])
                self.assertFalse((out / 'expo-livekit-stale-audio.ready.json').exists())

    def test_fault_ack_timeout_or_early_push_cannot_create_readiness(self):
        for failure in ('timeout', 'early-push', 'early-ready', 'late-push', 'clock-before-entry'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                data, out, runtime, trace, _ = self.control_fixture(Path(temporary).resolve())
                def append(event):
                    with trace.open('a') as stream: stream.write('PROBE ' + json.dumps(dict(event=event)) + '\n')
                if failure.startswith('early-'): append('m2.pushInjected' if failure == 'early-push' else 'm2.controlReady')
                def checkpoint(process, condition, seconds):
                    paths = list((runtime / 'requests').iterdir())
                    if paths and failure != 'timeout':
                        request = json.loads(paths[0].read_text())
                        response = {key: request[key] for key in ('id', 'runID', 'pid', 'bundleID')}
                        response.update(success=True, result=dict(configured=True))
                        write(runtime / 'responses' / paths[0].name, response)
                        if failure == 'late-push': append('m2.pushInjected')
                    value = condition()
                    if value is None: raise RuntimeError('fixture checkpoint deadline')
                    return value
                with patch.object(runner, 'wait', side_effect=checkpoint), \
                     patch.object(runner.time, 'time_ns', return_value=500_000_000 if failure == 'clock-before-entry' else 2_000_000_000), \
                     self.assertRaises(RuntimeError):
                    runner.stale_audio(Mock(), trace, data, out, 'run', 123)
                self.assertEqual(list((data / 'tmp').iterdir()), [])
                self.assertFalse((out / 'expo-livekit-stale-audio.ready.json').exists())
                if failure.startswith('early-'): self.assertEqual(list((runtime / 'requests').iterdir()), [])

    def test_control_paths_cannot_escape_the_bound_native_container(self):
        for part in ('session.json', 'run', 'run/requests', 'run/responses', 'tmp'):
            with self.subTest(part=part), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                data, out, runtime, trace, _ = self.control_fixture(root)
                path = data / 'tmp' if part == 'tmp' else runtime.parent / part
                destination = root / 'foreign'
                path.rename(destination)
                path.symlink_to(destination, target_is_directory=destination.is_dir())
                def checkpoint(process, condition, seconds): return condition()
                with patch.object(runner, 'wait', side_effect=checkpoint), self.assertRaisesRegex(RuntimeError, 'noncanonical'):
                    runner.stale_audio(Mock(), trace, data, out, 'run', 123)
                self.assertFalse((out / 'expo-livekit-stale-audio.request.json').exists())
                self.assertFalse((out / 'expo-livekit-stale-audio.ready.json').exists())

    def test_shared_helper_owns_preparation_checkpoint_launch_and_cleanup(self):
        for failure in (None, 'install', 'privacy', 'launch'):
            for replace in (False, True):
                with self.subTest(failure=failure, replace=replace), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary); build, unused = fixture(root); out = root / 'out'
                    calls, instances = [], []
                    class Setup:
                        current = 'old-simulator'
                        def __init__(self, directory):
                            self.out = directory; instances.append(self)
                        def call(self, command, timeout):
                            phase = command[2]; calls.append((phase, timeout, tuple(command)))
                            if phase == failure: raise RuntimeError('synthetic ' + phase)
                            if phase == 'list': return runner.Result(command, 0, stdout=json.dumps(inventory).encode())
                            if replace and phase == 'install': self.current = 'replacement-simulator'
                            if phase == 'launch': return self.launch(command, timeout)
                        def environment(self):
                            calls.append(('environment', self.current)); return '/private/synthetic Argént.dylib\n'
                        def checkpoint(self): calls.append(('checkpoint', self.current))
                        def cleanup(self, simulator):
                            calls.append(('cleanup', simulator)); write(self.out / 'cleanup.json',
                                dict(simulatorID=simulator, deleted=True, deleteExitCode=0))
                    inventory = dict(runtimes=[dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                        platform='iOS', isAvailable=True, version='27.0', buildversion='synthetic')])
                    with patch.object(runner, 'source_identity', return_value=IDENTITY), \
                         patch.object(runner, 'validate_build', return_value=gate.read(build, 'build.json')), \
                         patch.object(runner, 'validate', return_value={'success': True}), \
                         patch.object(runner, 'scenario', return_value=(4242, {'installed': 'bytes'})) as capture, \
                         patch.object(runner, 'redact') as redact, patch('builtins.print'):
                        if failure:
                            with self.assertRaisesRegex(RuntimeError, 'synthetic ' + failure): runner.run(build, out, Setup)
                            self.assertFalse((out / 'capture.json').exists())
                        else:
                            self.assertTrue(runner.run(build, out, Setup)['success'])
                            self.assertEqual(len(instances), 1)
                            current = 'replacement-simulator' if replace else 'old-simulator'
                            self.assertEqual(calls[-4][0], 'checkpoint')
                            self.assertEqual([c[:2] for c in calls[-3:-1]], [('launch', 120), ('launch', 120)])
                            self.assertEqual(calls[-1], ('cleanup', current))
                            self.assertEqual([c.args[3] for c in capture.call_args_list], ['livekit', 'stale-audio'])
                            self.assertEqual([c.args[4] for c in capture.call_args_list], [capture.call_args.args[4]] * 2)
                            self.assertEqual(capture.call_args.args[5], '/private/synthetic Argént.dylib\n')
                            self.assertEqual(capture.call_args.args[6][5], current)
                            self.assertEqual([c[0] for c in calls].count('environment'), 1)
                            self.assertTrue(gate.read(out, 'cleanup.json')['absent'])
                            self.assertEqual(gate.read(out, 'capture.json')['simulatorID'], current)
                            self.assertEqual(gate.read(out, 'capture.json')['supervisorPIDs'],
                                {'livekit': 4242, 'stale-audio': 4242})
                        self.assertEqual(calls[-1][0], 'cleanup')
                        redact.assert_called_once()
                        self.assertEqual([c[1] for c in calls if c[0] in ('install', 'privacy')],
                            [180] if failure == 'install' else [180, 180])

    def test_explicit_launch_override_is_required_before_any_simulator_work(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(runner.os.environ, {}, clear=True):
            factory = Mock(side_effect=AssertionError('simulator work forbidden'))
            with self.assertRaisesRegex(RuntimeError, 'provide SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'):
                runner.run(Path(temporary), Path(temporary) / 'out', factory)
            factory.assert_not_called()

    def test_primary_failure_survives_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / 'out'
            setup = Mock(); setup.call.side_effect = RuntimeError('primary install failure'); setup.redaction_values = []
            setup.cleanup.side_effect = RuntimeError('secondary cleanup failure')
            inventory = dict(runtimes=[dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', platform='iOS',
                isAvailable=True, version='27.0', buildversion='synthetic')])
            with patch.object(runner, 'source_identity', return_value=IDENTITY), patch.object(runner, 'validate_build'), \
                 patch.object(runner, 'redact'), patch('builtins.print'):
                with self.assertRaisesRegex(RuntimeError, 'primary install failure'):
                    runner.run(Path(temporary), out, lambda directory: setup)
            setup.cleanup.assert_called_once()

    def test_console_executor_delegates_launch_only(self):
        setup = object.__new__(runner.ExpoSetup)
        setup.launch = Mock(return_value=runner.Result([], 0))
        with patch.object(runner.SimulatorSetup, 'execute', return_value='helper') as native:
            self.assertEqual(setup.execute(['xcrun', 'simctl', 'boot', 'owned'], 60), 'helper')
            native.assert_called_once()
            result = setup.execute(['xcrun', 'simctl', 'launch', '--console'], 120)
            self.assertEqual(result.returncode, 0)
            setup.launch.assert_called_once_with(['xcrun', 'simctl', 'launch', '--console'], 120)

    def test_actual_session_keeps_one_budget_and_never_replays_checkpointed_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary); setup = runner.ExpoSetup(out)
            simulator = str(uuid.uuid4()).upper(); native = []
            def recorded(label, arguments, timeout=60, env=None):
                native.append((tuple(arguments), timeout))
                output = simulator.encode() if arguments[2] == 'create' else (
                    b'{"devices": {}}' if arguments[2] == 'list' else b'')
                return runner.Result(arguments, 0, stdout=output)
            with patch.object(setup, 'recorded', side_effect=recorded):
                setup.call(['xcrun', 'simctl', 'create', 'unique-owned-name', 'device', 'runtime'], 30)
                setup.call(['xcrun', 'simctl', 'install', simulator, 'fixture.app'], 180)
                setup.checkpoint()
                state_before = json.loads(setup.state_path.read_text())
                self.assertTrue(state_before['checkpoint']); self.assertFalse(state_before['retry_used'])
                launch = ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', simulator, gate.BUNDLE]
                setup.launch = Mock(side_effect=[runner.Result(launch, 0), runner.Result(launch, 3)])
                with patch.object(runner.sys.modules['sim'], 'summary'):
                    self.assertEqual(setup.session.call(launch, 120).returncode, 0)
                    result = setup.session.call(launch, 120)
                self.assertEqual(result.returncode, 3)
                self.assertEqual(setup.launch.call_args_list, [call(launch, 120), call(launch, 120)])
                state_after = json.loads(setup.state_path.read_text())
                self.assertTrue(state_after['checkpoint']); self.assertFalse(state_after['retry_used'])
                self.assertEqual(state_after['owned'], state_before['owned'])
                self.assertEqual(setup.session.cleanup(timeout=60).returncode, 0)
                self.assertEqual([argv[2] for argv, timeout in native], ['create', 'install', 'shutdown', 'delete'])

    def test_bound_live_paths_require_native_identity_and_canonical_owned_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); sim = str(uuid.uuid4()).upper(); trace = root / 'case.log'
            container = root / sim / 'data/Containers/Data/Application' / str(uuid.uuid4())
            app = root / sim / 'data/Containers/Bundle/Application' / str(uuid.uuid4()) / 'Example.app'
            container.mkdir(parents=True); app.mkdir(parents=True)
            rows = [dict(event=event, pid=123, runID='run', simulatorID=sim, bundleID=gate.BUNDLE)
                    for event in ('app.entry', 'launch')]
            rows[1].update(mode='sdk-m2', case='livekit', dataContainer=str(container), bundlePath=str(app))
            def emit(): trace.write_text(gate.BUNDLE + ': 123\n' + ''.join('PROBE ' + json.dumps(r) + '\n' for r in rows))
            for case in ('livekit', 'stale-audio'):
                rows[1]['case'] = case; emit()
                self.assertEqual(runner.bound_paths(trace, sim, 'run', case, devices_root=root), (123, container, app))
            rows[1]['case'] = 'livekit'; emit()
            # The native console header may flush only when the app stops.
            trace.write_text(''.join('PROBE ' + json.dumps(r) + '\n' for r in rows))
            self.assertEqual(runner.bound_paths(trace, sim, 'run', 'livekit', devices_root=root), (123, container, app))
            for key, value in [('pid', True), ('runID', 'foreign'), ('case', 'stale-audio'),
                               ('dataContainer', str(root)), ('bundlePath', str(container))]:
                original = rows[1][key]; rows[1][key] = value; emit()
                with self.subTest(key=key), self.assertRaises((RuntimeError, ValueError)):
                    runner.bound_paths(trace, sim, 'run', 'livekit', devices_root=root)
                rows[1][key] = original
            shadow = root / 'shadow' / sim / 'data/Containers/Data/Application' / str(uuid.uuid4())
            shadow.mkdir(parents=True); rows[1]['dataContainer'] = str(shadow); emit()
            with self.assertRaises(RuntimeError): runner.bound_paths(trace, sim, 'run', 'livekit', devices_root=root)
            rows[1]['dataContainer'] = str(container)
            linked = container.parent / str(uuid.uuid4()); linked.symlink_to(container, target_is_directory=True)
            rows[1]['dataContainer'] = str(linked); emit()
            with self.assertRaises(RuntimeError): runner.bound_paths(trace, sim, 'run', 'livekit', devices_root=root)
            rows[1]['dataContainer'] = str(container); emit()
            trace.write_text(trace.read_text().replace(gate.BUNDLE + ': 123', gate.BUNDLE + ': 456'))
            with self.assertRaises(RuntimeError): runner.bound_paths(trace, sim, 'run', 'livekit', devices_root=root)

    def test_outer_binding_watchdog_allows_entry_after_the_old_launch_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); out = root / 'out'; out.mkdir(); build, data = fixture(root)
            runtime = data / 'Documents/.callkit-simulator/run'; runtime.mkdir(parents=True)
            (runtime / 'events.jsonl').write_text('original journal')
            write(out / 'expo-livekit-livekit.receipt.json', dict(appPID=123, supervisorPID=4242))
            setup = SimpleNamespace(current='owned', state_path=out / 'owner.json', call=Mock())
            clock = SimpleNamespace(now=0)
            process = Mock(pid=4242); process.poll.return_value = None
            def advance(seconds): clock.now += seconds
            def paths(*_): return (123, data, build / 'example.app') if clock.now >= 150 else None
            def finished(timeout):
                self.assertEqual(timeout, 160); process.poll.return_value = 0; return 0
            process.wait.side_effect = finished
            with patch.object(runner.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.object(runner, 'bound_paths', side_effect=paths), \
                 patch.object(runner.time, 'monotonic', side_effect=lambda: clock.now), \
                 patch.object(runner.time, 'sleep', side_effect=advance), \
                 patch.object(runner, 'validate_build', return_value=gate.read(build, 'build.json')):
                arguments = ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', 'owned', gate.BUNDLE]
                self.assertEqual(runner.scenario(setup, build, out, 'livekit', 'run', '', arguments, 120)[0], 4242)
            self.assertGreaterEqual(clock.now, 150)
            spawn.assert_called_once(); setup.call.assert_not_called()

    def test_reported_timeouts_cross_the_shared_session_without_product_fallback_or_retry(self):
        for label in ('infra:startup', 'infra:capture'):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); build, _ = fixture(root); out = root / 'out'
                simulator = str(uuid.uuid4()).upper(); instances = []
                inventory = dict(runtimes=[dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                    platform='iOS', isAvailable=True, version='27.0', buildversion='synthetic')])
                class Setup(runner.ExpoSetup):
                    def __init__(self, directory): super().__init__(directory); instances.append(self)
                    def recorded(self, name, arguments, timeout=60, env=None):
                        output = simulator.encode() if arguments[2] == 'create' else (
                            json.dumps(inventory if arguments[3] == 'runtimes' else {'devices': {}}).encode()
                            if arguments[2] == 'list' else b'')
                        return runner.Result(arguments, 0, stdout=output)
                    def environment(self): return ''
                with patch.object(runner, 'source_identity', return_value=IDENTITY), \
                     patch.object(runner, 'validate_build'), patch.object(runner, 'redact'), \
                     patch.object(runner, 'scenario', side_effect=runner.ExpoSupervisorTimeout(label)) as capture, \
                     patch.object(runner.sys.modules['sim'], 'summary') as summary:
                    with self.assertRaisesRegex(EvidenceError, 'launch failed: 1'):
                        runner.run(build, out, Setup)
                capture.assert_called_once()
                self.assertFalse(any(c.args[0].startswith('product:') for c in summary.call_args_list))
                state = json.loads(instances[0].state_path.read_text())
                self.assertTrue(state['checkpoint']); self.assertFalse(state['retry_used'])
                self.assertEqual(state['owned'], [])
                self.assertTrue(gate.read(out, 'cleanup.json')['absent'])

    def test_only_matching_reported_timeout_receipts_preserve_infra_classification(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / 'receipt.json'
            for reason, label in (('startup', 'infra:startup'), ('capture', 'infra:capture')):
                row = dict(schemaVersion=2, success=False, completed=False, runID='run', simulatorID='owned',
                    bundleID=gate.BUNDLE, scenario='expo-livekit-livekit', supervisorPID=4242,
                    inheritLauncherGroup=True, failureReported=True, timeoutReason=reason, failureClass=label)
                write(receipt, row)
                self.assertEqual(runner.reported_timeout(receipt, 'owned', 'run', 'expo-livekit-livekit', 4242), label)
                for key, value in [('schemaVersion', True), ('success', 0), ('completed', 0), ('runID', 'foreign'),
                        ('simulatorID', 'foreign'), ('bundleID', 'foreign'), ('scenario', 'foreign'),
                        ('supervisorPID', True), ('inheritLauncherGroup', 1), ('failureReported', 1),
                        ('timeoutReason', [reason]), ('timeoutReason', 'unknown'), ('failureClass', 'product:launch')]:
                    with self.subTest(reason=reason, key=key):
                        write(receipt, {**row, key: value})
                        self.assertIsNone(runner.reported_timeout(receipt, 'owned', 'run', 'expo-livekit-livekit', 4242))
            receipt.write_text('invalid')
            self.assertIsNone(runner.reported_timeout(receipt, 'owned', 'run', 'expo-livekit-livekit', 4242))


    def test_binding_supervisor_exit_keeps_its_reported_startup_classification(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            write(out / 'expo-livekit-livekit.receipt.json', dict(schemaVersion=2, success=False,
                completed=False, runID='run', simulatorID='owned', bundleID=gate.BUNDLE,
                scenario='expo-livekit-livekit', supervisorPID=4242, inheritLauncherGroup=True,
                failureReported=True, timeoutReason='startup', failureClass='infra:startup'))
            setup = SimpleNamespace(current='owned', state_path=out / 'owner.json', call=Mock())
            process = Mock(pid=4242); process.poll.return_value = 1
            with patch.object(runner.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.object(runner, 'bound_paths', return_value=None):
                arguments = ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', 'owned', gate.BUNDLE]
                with self.assertRaisesRegex(runner.ExpoSupervisorTimeout, 'infra:startup'):
                    runner.scenario(setup, out / 'unused-build', out, 'livekit', 'run', '', arguments, 120)
            spawn.assert_called_once(); setup.call.assert_not_called()
            process.wait.assert_not_called()

    def test_valid_timeout_receipt_cannot_relabel_validation_failures(self):
        for failure in ('bound-paths', 'installed-bytes', 'stale-control'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); out = root / 'out'; out.mkdir(); build, data = fixture(root)
                case = 'stale-audio' if failure == 'stale-control' else 'livekit'
                write(out / ('expo-livekit-' + case + '.receipt.json'), dict(schemaVersion=2,
                    success=False, completed=False, runID='run', simulatorID='owned', bundleID=gate.BUNDLE,
                    scenario='expo-livekit-' + case, supervisorPID=4242, inheritLauncherGroup=True,
                    failureReported=True, timeoutReason='capture', failureClass='infra:capture'))
                expected = gate.read(build, 'build.json')
                if failure == 'installed-bytes': (build / gate.APP_FILES[0]).write_text('different installed bytes')
                setup = SimpleNamespace(current='owned', state_path=out / 'owner.json', call=Mock())
                process = Mock(pid=4242); process.poll.return_value = 0
                message = {'bound-paths': 'fresh Expo launch identity differs',
                           'installed-bytes': 'installed consumer bytes differ from bound build',
                           'stale-control': 'Expo fault ACK differs'}[failure]
                with patch.object(runner.subprocess, 'Popen', return_value=process), \
                     patch.object(runner, 'wait', side_effect=lambda process, condition, seconds: condition()), \
                     patch.object(runner, 'bound_paths', return_value=(123, data, build / 'example.app')) as paths, \
                     patch.object(runner, 'validate_build', return_value=expected), \
                     patch.object(runner, 'stale_audio', side_effect=RuntimeError(message)):
                    if failure == 'bound-paths': paths.side_effect = RuntimeError(message)
                    arguments = ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', 'owned', gate.BUNDLE]
                    with self.assertRaisesRegex(RuntimeError, message) as raised:
                        runner.scenario(setup, build, out, case, 'run', '', arguments, 120)
                    self.assertNotIsInstance(raised.exception, runner.ExpoSupervisorTimeout)
                process.wait.assert_not_called(); setup.call.assert_not_called()

    def test_scenario_helper_stop_preserves_launch_environment_and_private_group(self):
        cases = [(case, mode) for case in ('livekit', 'stale-audio')
                 for mode in ('natural', 'exited-child', 'failure', 'forced', 'unowned', 'remaining', 'startup-timeout',
                              'capture-timeout', 'interrupted', 'cancelled')]
        for case, mode in [*cases, ('stale-audio', 'fault-timeout')]:
            with self.subTest(case=case, mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); out = root / 'out'; out.mkdir(); build, data = fixture(root)
                runtime = data / 'Documents/.callkit-simulator/run'; runtime.mkdir(parents=True)
                (runtime / 'events.jsonl').write_text('original journal')
                receipt = out / ('expo-livekit-' + case + '.receipt.json')
                write(receipt, dict(appPID=123, supervisorPID=4242))
                if mode in ('startup-timeout', 'capture-timeout', 'interrupted', 'cancelled'):
                    reason = 'capture' if mode == 'capture-timeout' else 'startup'
                    write(receipt, dict(schemaVersion=2, success=False, completed=False, runID='run',
                        simulatorID='owned', bundleID=gate.BUNDLE, scenario='expo-livekit-' + case,
                        supervisorPID=4242, inheritLauncherGroup=True, failureReported=True,
                        timeoutReason=reason, failureClass='infra:' + reason))
                setup = SimpleNamespace(current='owned', state_path=out / 'owner.json', call=Mock())
                process = Mock(pid=4242)
                process.poll.side_effect = [None, None] if mode in ('forced', 'unowned') else ([0] if mode in ('natural', 'exited-child') else [None])
                def waits(timeout):
                    if timeout == 160 and mode == 'interrupted': raise runner.Interrupted(signal.SIGTERM)
                    if timeout == 160 and mode == 'cancelled': raise KeyboardInterrupt('synthetic cancellation')
                    if timeout == 160 and mode not in ('natural', 'exited-child'): raise RuntimeError('synthetic capture failure')
                    if timeout == 25 and mode in ('forced', 'unowned'): raise subprocess.TimeoutExpired('synthetic', 25)
                    return 0
                process.wait.side_effect = waits
                child = dict(alive=True)
                def group(pid, sig):
                    self.assertEqual(pid, 4242)
                    if sig == signal.SIGKILL and mode == 'exited-child': child['alive'] = False
                    if sig == 0 and mode != 'remaining' and not (mode == 'exited-child' and child['alive']):
                        raise ProcessLookupError
                self.killpg.side_effect = group
                environment = {'SIMCTL_CHILD_SDK_M3_ACCEPTANCE': '1', 'SIMCTL_CHILD_SDK_SYSTEM_CASE': 'foreign',
                    'SIMCTL_CHILD_CKSIM_BAD': 'foreign', 'UNRELATED': 'keep'}
                if mode in ('startup-timeout', 'capture-timeout'): environment['SIM_FAILURE_MARKER'] = str(out / 'explicit.marker')
                with patch.object(runner.subprocess, 'Popen', return_value=process) as spawn, \
                     patch.object(runner, 'wait', return_value=(123, data, build / 'example.app')) as binding, \
                     patch.object(runner, 'validate_build', return_value=gate.read(build, 'build.json')), \
                     patch.object(runner, 'stale_audio') as configure, \
                     patch.object(runner.os, 'getpgid', return_value=9999 if mode == 'unowned' else 4242), \
                     patch.object(runner.os, 'getsid', return_value=4242), patch.dict(runner.os.environ, environment, clear=True):
                    arguments = ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', 'owned', gate.BUNDLE]
                    if mode == 'fault-timeout': configure.side_effect = RuntimeError('fixture checkpoint deadline')
                    if mode in ('natural', 'exited-child'):
                        pid, hashes = runner.scenario(setup, build, out, case, 'run', '/private/Argént.dylib\n', arguments, 120)
                        self.assertEqual(pid, 4242); self.assertEqual(hashes, {k: gate.digest(build / k) for k in gate.APP_FILES})
                        self.assertEqual((out / ('expo-livekit-' + case + '.runtime.jsonl')).read_text(), 'original journal')
                        setup.call.assert_not_called()
                    else:
                        expected_error = (KeyboardInterrupt if mode == 'cancelled' else
                            runner.Interrupted if mode == 'interrupted' else runner.ExpoSupervisorTimeout
                            if mode in ('startup-timeout', 'capture-timeout') else RuntimeError)
                        with self.assertRaises(expected_error):
                            runner.scenario(setup, build, out, case, 'run', '/private/Argént.dylib\n', arguments, 120)
                        setup.call.assert_called_once_with(['xcrun', 'simctl', 'terminate', 'owned', gate.BUNDLE], 10)
                    argv = spawn.call_args.args[0]; options = spawn.call_args.kwargs
                    self.assertIs(options['start_new_session'], True)
                    self.assertIn('--inherit-launcher-group', argv)
                    self.assertEqual(argv[argv.index('--timeout') + 1], '120')
                    self.assertEqual(argv[argv.index('--startup-timeout') + 1], '180')
                    self.assertEqual(binding.call_args.args[2], 340)
                    terminate = argv[argv.index('--terminate-command') + 1:argv.index('--launch-command')]
                    self.assertEqual(terminate, [runner.sys.executable, str(runner.ROOT / 'scripts/sim/sim.py'),
                        'call', str(setup.state_path), '5', 'xcrun', 'simctl', 'terminate', 'owned', gate.BUNDLE])
                    env = options['env']
                    self.assertEqual(env['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'], '/private/Argént.dylib\n')
                    self.assertEqual(env['UNRELATED'], 'keep')
                    self.assertEqual(env['SIM_FAILURE_MARKER'], environment.get('SIM_FAILURE_MARKER', str(setup.state_path) + '.failure'))
                    self.assertNotIn('SIMCTL_CHILD_SDK_M3_ACCEPTANCE', env)
                    self.assertNotIn('SIMCTL_CHILD_SDK_SYSTEM_CASE', env)
                    self.assertNotIn('SIMCTL_CHILD_CKSIM_BAD', env)
                    self.assertEqual(env['SIMCTL_CHILD_SDK_M2_CASE'], case)
                    self.assertEqual(env['SIMCTL_CHILD_SDK_M2_RUN_ID'], 'run')
                    self.assertEqual(env['SIMCTL_CHILD_CKSIM_RUN_ID'], 'run')
                    if case == 'stale-audio':
                        configure.assert_called_once_with(process, out / ('expo-livekit-' + case + '.log'), data, out, 'run', 123)
                    else: configure.assert_not_called()
                    self.assertEqual(dict(runner.os.environ), environment)
                    kills = [c for c in self.killpg.call_args_list if c.args[1] == signal.SIGKILL]
                    self.assertEqual(bool(kills), mode in ('forced', 'remaining', 'exited-child'))
                self.killpg.reset_mock()


class StartupCaptureControls(unittest.TestCase):
    """Virtual host time exercises the real supervisor; no simulator or child is launched."""
    def capture(self, mode):
        app, launcher, owner = 7003, 7002, 7001
        identity = dict(runID='run', simulatorID='owned', bundleID=gate.BUNDLE, scenario='expo-livekit-livekit')
        entry = dict(event='app.entry', pid=app, t_ms=0, **identity)
        launched = dict(event='launch', pid=app, t_ms=1, **identity)
        clock = SimpleNamespace(now=0)
        events = [(0, (gate.BUNDLE + ': ' + str(app) + '\n').encode())]
        def probe(at, row): events.append((at, ('PROBE ' + json.dumps(row) + '\n').encode()))
        if mode != 'no-entry':
            if mode == 'foreign-entry': entry['runID'] = 'foreign'
            probe(180.01 if mode == 'late-entry' else 150, entry)
            probe(180.02 if mode == 'late-entry' else 150.01, launched)
            if mode in ('delayed-entry', 'late-native-terminal', 'late-host-terminal'):
                probe(270.01 if mode == 'late-host-terminal' else 269,
                      dict(event='done', t_ms=120000 if mode == 'late-native-terminal' else 119000, **identity))
                events.append((270.02 if mode == 'late-host-terminal' else 269.01, None))
        class Messages:
            def get(self, timeout):
                if events and events[0][0] <= clock.now + timeout:
                    observed, line = events.pop(0); clock.now = max(clock.now, observed)
                    return line, observed
                clock.now += timeout
                raise queue.Empty
            def get_nowait(self):
                if events and events[0][0] <= clock.now:
                    observed, line = events.pop(0); return line, observed
                raise queue.Empty
        process = Mock(pid=launcher, returncode=None)
        process.stdout = None; process.stderr = SimpleNamespace(fileno=lambda: 7006, close=lambda: None)
        process.poll.side_effect = lambda: process.returncode
        def finished(timeout): process.returncode = 0; return 0
        process.wait.side_effect = finished
        original_close = supervisor.os.close
        def kill(pid, signum):
            if (pid, signum) == (app, 0): raise ProcessLookupError
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); output, receipt = root / 'trace.log', root / 'receipt.json'
            with patch.object(supervisor.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.object(supervisor, 'bounded', return_value=runner.Result(['synthetic-stop'], 0)), \
                 patch.object(supervisor.queue, 'Queue', return_value=Messages()), \
                 patch.object(supervisor.time, 'monotonic', side_effect=lambda: clock.now), \
                 patch.object(supervisor.threading, 'Thread', return_value=SimpleNamespace(
                     start=lambda: None, ident=1, join=lambda timeout: None, is_alive=lambda: False)), \
                 patch.object(supervisor.os, 'openpty', return_value=(7004, 7005)), \
                 patch.object(supervisor.os, 'close', side_effect=lambda fd: None if fd in (7004, 7005) else original_close(fd)), \
                 patch.object(supervisor.tty, 'setraw'), patch.object(supervisor.os, 'kill', side_effect=kill), \
                 patch.object(supervisor.os, 'getpid', return_value=owner), \
                 patch.object(supervisor.os, 'getpgid', return_value=owner), \
                 patch.object(supervisor.os, 'getsid', return_value=owner), \
                 patch.object(supervisor, 'report_timeout', return_value=True) as report:
                code = supervisor.run(['synthetic-launch'], ['synthetic-stop'], output, receipt, 120, identity,
                    console_launcher_stop=True, inherit_launcher_group=True, startup_timeout=180)
            spawn.assert_called_once()
            return code, json.loads(receipt.read_text()), report.call_args_list, clock.now

    def test_delayed_bound_entry_gets_the_full_unchanged_capture_budget(self):
        code, receipt, reports, elapsed = self.capture('delayed-entry')
        self.assertEqual(code, 0); self.assertIs(receipt['success'], True)
        self.assertEqual(receipt['captureStart'], 'observed-app-entry')
        self.assertGreater(elapsed, 180); self.assertEqual(reports, [])

    def test_no_entry_expires_at_startup_without_a_capture_phase(self):
        for mode in ('no-entry', 'late-entry'):
            with self.subTest(mode=mode):
                code, receipt, reports, elapsed = self.capture(mode)
                self.assertEqual(code, 1); self.assertIs(receipt['completed'], False)
                self.assertEqual(receipt['timeoutReason'], 'startup'); self.assertEqual(elapsed, 180)
                self.assertEqual(reports, [call('infra:startup')]); self.assertNotIn('captureStart', receipt)

    def test_post_entry_timeout_and_both_late_terminal_clocks_remain_capture_failures(self):
        for mode in ('post-entry-timeout', 'late-native-terminal', 'late-host-terminal'):
            with self.subTest(mode=mode):
                code, receipt, reports, elapsed = self.capture(mode)
                self.assertEqual(code, 1); self.assertIs(receipt['completed'], False)
                self.assertEqual(receipt['timeoutReason'], 'capture')
                self.assertEqual(reports, [call('infra:capture')]); self.assertLessEqual(elapsed, 270)

    def test_foreign_entry_cannot_end_startup(self):
        code, receipt, reports, _ = self.capture('foreign-entry')
        self.assertEqual(code, 1); self.assertNotIn('captureStart', receipt)
        self.assertEqual(receipt['error'], 'invalid app.entry identity'); self.assertEqual(reports, [])


if __name__ == '__main__':
    unittest.main()
