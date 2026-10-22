#!/usr/bin/env python3
"""Bind the completed physical no-I/O transport run, separately from LCK/audio rendering."""
from collections import Counter
import json
import math
from pathlib import Path
import uuid

import sdk_audio_device_transport as old
from summarize import EvidenceError, one, require

ROOT = old.ROOT
PACKET = old.PACKET.with_name('2026-10-22-iphone13-ios27-noio')
MANIFEST_SHA256 = '164074e6adc853069c75ed1692c7820b95423772aee37bb209d9dae6a96de8eb'
PHASES = ('sync-activate', 'sync-deactivate', 'async-activate', 'async-deactivate')
EXTRA_NAMES = dict(legacy='AVAudioSessionInterruptionNotification', route='AVAudioSessionRouteChangeNotification')


def exact(value, expected):
    """Keep bool/int and integer/float distinctions in derived evidence."""
    if type(value) is not type(expected): return False
    if isinstance(expected, dict):
        return value.keys() == expected.keys() and all(exact(value[k], v) for k, v in expected.items())
    if isinstance(expected, (tuple, list)):
        return len(value) == len(expected) and all(exact(a, b) for a, b in zip(value, expected))
    return value == expected


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_transport(rows, receipt):
    run, build, observations = receipt['run'], receipt['build'], receipt['observations']
    require(rows and len(rows) == receipt['capture']['rows'] and
            all(isinstance(r, dict) and isinstance(r.get('event'), str) and isinstance(r.get('phase'), str) and
                type(r.get('sequence')) is int and type(r.get('t_ms')) is int and r['t_ms'] >= 0 and
                type(r.get('wallTimeMS')) is int and r['wallTimeMS'] > 0 for r in rows) and
            [r['sequence'] for r in rows] == list(range(1, len(rows) + 1)) and
            all(a['t_ms'] <= b['t_ms'] and a['wallTimeMS'] <= b['wallTimeMS'] for a, b in zip(rows, rows[1:])),
            'no-I/O: invalid trace sequence/time')
    require(type(run.get('trustedPID')) is int and run['trustedPID'] > 0 and run.get('simulator') is False and
            run.get('deviceModel') == 'iPhone 13' and run.get('osVersion') == '27.0' and
            isinstance(run.get('runID'), str) and str(uuid.UUID(run['runID'])).upper() == run['runID'] and
            all(r.get('runID') == run['runID'] and type(r.get('pid')) is int and r['pid'] == run['trustedPID'] and
                r.get('bundleID') == 'dev.iosvoipsdk.audio-lifecycle-probe' and r.get('main') is True for r in rows),
            'no-I/O: mixed physical/run/PID/main identity')
    launch = one(rows, 'launch')
    require(rows[0] is launch and launch.get('silentOutputRequested') is False and launch.get('simulator') is False and
            launch.get('osVersion') == run['osVersion'] and old.sha(build.get('executableSHA256')) and
            launch.get('executableSHA256') == build['executableSHA256'] and old.sha(build.get('infoSHA256')) and
            build.get('configuration') == 'Release' and build.get('sameFrozenSignedExecutableAsSilentRun') is True and
            build.get('localCodeSignatureVerified') is True and build.get('sourceBuildInstalledCustodyAndTrustedLaunchBound') is True and
            build.get('rebuiltOrResignedForThisRun') is False and build.get('ciAttested') is False,
            'no-I/O: mode or local build/launch custody differs')
    require(rows[-1]['event'] == 'done' and not any(r['event'] == 'experiment.failed' for r in rows),
            'no-I/O: experiment incomplete/failed')
    done = one(rows, 'done')
    installed = one(rows, 'observers.installed')
    configured, active = one(rows, 'session.configured'), one(rows, 'application.activeBeforeAudio')
    sentinels = [one(rows, 'control.privateSentinel' + name) for name in ('Posted', 'Received', 'Returned')]
    require(installed.get('actualSwiftConsumer') is True and installed.get('independentCDecoder') is True and
            type(installed.get('tokensRetained')) is int and installed['tokensRetained'] == 6 and
            exact(installed.get('rawNotificationNames'), [*old.NAMES.values(), *EXTRA_NAMES.values()]) and
            configured.get('actualSDKConfiguration') is True and active.get('active') is True and
            all(r.get('syntheticPrivateControl') is True and r.get('countsAsAVNotification') is False for r in sentinels) and
            [r['sequence'] for r in [installed, *sentinels, active, configured]] ==
            sorted({r['sequence'] for r in [installed, *sentinels, active, configured]}),
            'no-I/O: actual observer/control/foreground/configuration missing or unordered')

    requested = [r for r in rows if r['event'] == 'operation.requested']
    results = [r for r in rows if r['event'] == 'operation.result']
    observed = [r for r in rows if r['event'] == 'operation.observed']
    require(len(requested) == len(results) == len(observed) == 4, 'no-I/O: four operations missing/duplicated')
    phases, previous = [], configured
    for index, (request, result, observation, phase) in enumerate(zip(requested, results, observed, PHASES)):
        require(type(request.get('index')) is int and request['index'] == index and request.get('applicationActive') is True and
                all(r.get('phase') == phase for r in (request, result, observation)) and
                previous['sequence'] < request['sequence'] < result['sequence'] < observation['sequence'],
                'no-I/O: operation order/index/foreground differs')
        require(all(result.get(k) is True for k in ('sessionAttempted', 'sessionSuccess', 'ioSuccess', 'callAudioQueue')) and
                result.get('callMain') is False and type(result.get('completionMain')) is bool and
                all(result.get(k) == '' for k in ('sessionErrorDomain', 'ioErrorDomain')) and
                all(type(result.get(k)) is int and result[k] == 0 for k in ('sessionErrorCode', 'ioErrorCode')),
                'no-I/O: actual API failed or ran on the wrong queue')
        require(number(observation.get('observationElapsedMS')) and observation['observationElapsedMS'] >= 4990 and
                observation['t_ms'] - result['t_ms'] >= 4990 and type(observation.get('mainHeartbeatTicks')) is int and
                observation['mainHeartbeatTicks'] >= 10, 'no-I/O: observation window/heartbeat missing')
        phases.append(dict(phase=phase, requestedSequence=request['sequence'], resultSequence=result['sequence'],
                           observedSequence=observation['sequence'], observationElapsedMS=observation['observationElapsedMS'],
                           mainHeartbeatTicks=observation['mainHeartbeatTicks']))
        previous = observation
    cleanup, completed = one(rows, 'fixture.cleanup'), one(rows, 'experiment.completed')
    require(type(completed.get('operations')) is int and completed['operations'] == 4 and
            completed.get('ordinarySessionOnly') is True and completed.get('notLCKInterruptionAcceptance') is True and
            previous['sequence'] < cleanup['sequence'] < completed['sequence'] < done['sequence'], 'no-I/O: completion differs')
    io_rows = [r for r in rows if any(k in r for k in ('engineRunning', 'renderFrames', 'renderCallbacks'))]
    require(len(io_rows) == 9 and io_rows == [r for r in rows if r['event'] in
            ('operation.result', 'operation.observed', 'fixture.cleanup')] and
            all(r.get('engineRunning') is False and all(type(r.get(k)) is int and r[k] == 0
                for k in ('renderFrames', 'renderCallbacks')) for r in io_rows), 'no-I/O: nine typed zero-I/O snapshots required')

    inventories, extras, streams = {}, {}, {}
    allowed = {'raw.notification': {*old.NAMES, *EXTRA_NAMES},
               'decoder.lifecycle': {*old.NAMES, 'reset'}, 'consumer.lifecycle': {*old.NAMES, 'reset'}}
    for event in allowed:
        all_rows = [r for r in rows if r['event'] == event]
        require(all(r.get('kind') in allowed[event] for r in all_rows), 'no-I/O: unexpected lifecycle kind')
        for row in all_rows:
            require(all(type(row.get(k)) is bool for k in ('hasSource', 'hasInterruptionReason', 'shouldResume')) and
                    all(type(row.get(k)) is int for k in ('source', 'interruptionReason')) and
                    (row['hasSource'] or row['source'] == 0) and (row['hasInterruptionReason'] or row['interruptionReason'] == 0) and
                    isinstance(row.get('contextClass'), str) and (event == 'raw.notification' or row['contextClass'] == ''),
                    'no-I/O: lifecycle scalar types/context differ')
            if event == 'raw.notification':
                require(row.get('notificationName') == {**old.NAMES, **EXTRA_NAMES}[row['kind']] and
                        (row['kind'] != 'inactive' or (row['contextClass'] == 'AVAudioSessionDeactivationContext' and
                         row['hasSource'] is True and row['source'] == 1 and exact(observations.get('rawInactiveSource'), 1))) and
                        (row['kind'] != 'active' or row['contextClass'] == ''), 'no-I/O: raw context/name differs')
        streams[event] = [r for r in all_rows if r['kind'] in old.NAMES]
        inventories[event] = {kind: sum(r['kind'] == kind for r in streams[event]) for kind in old.NAMES}
        extras[event] = dict(Counter(r['kind'] for r in all_rows if r['kind'] not in old.NAMES))
    require(list(map(old.tagged, streams['raw.notification'])) == list(map(old.tagged, streams['decoder.lifecycle'])) ==
            list(map(old.tagged, streams['consumer.lifecycle'])), 'no-I/O: ordered raw/C/Swift scalar inventories differ')
    # Counts are compared with this immutable run's receipt, never an OS-wide event-count rule.
    require(exact(inventories, observations['modernInventories']) and exact(extras, observations['nonTargetNotificationCounts']) and
            inventories['raw.notification']['active'] >= 2 and inventories['raw.notification']['inactive'] >= 2 and
            inventories['raw.notification']['recommended'] == 0 and observations.get('typeTaggedInventoriesEqual') is True and
            observations.get('scalarRawValuesComparedWithoutNormalization') is True and
            observations.get('modernScalarFields') == list(old.SCALARS) and
            observations.get('rawInactiveContextClass') == 'AVAudioSessionDeactivationContext', 'no-I/O: observed inventory differs')
    require(exact(phases, observations['phases']) and type(observations.get('ioSnapshots')) is int and
            observations['ioSnapshots'] == len(io_rows) and observations.get('allIOSnapshotsEngineRunning') is False and
            all(type(observations.get(k)) is int and observations[k] == 0 for k in
                ('allIOSnapshotsRenderFrames', 'allIOSnapshotsRenderCallbacks')) and
            all(observations.get(k) is True for k in ('allFourAPICallsSucceeded', 'allFourAPICallsOffMainOnAudioSessionQueue')) and
            number(completed.get('maxMainHeartbeatGapMS')) and completed['maxMainHeartbeatGapMS'] >= 0 and
            exact(observations.get('maxMainHeartbeatGapMS'), completed['maxMainHeartbeatGapMS']) and
            observations.get('mainThreadStallThresholdQualified') is False and
            observations.get('privateSyntheticControlCountsAsAVNotification') is False,
            'no-I/O: observation receipt differs; no stall threshold qualified')
    result = receipt['result']
    require(all(result.get(k) is True for k in ('fullNoIOComplete', 'ordinaryPhysicalProducerDecoderConsumerQualified',
                                              'fourOperationsCompleted')) and result.get('requestedOperations') == list(PHASES) and
            result.get('silentOutputRequested') is False and result.get('recommendationMeasured') is False and
            result.get('originalSilentEngineFixtureStatus') == 'RED; unchanged; engine-stop cause UNKNOWN', 'no-I/O: result scope differs')
    custody = receipt['cleanup']
    times = [custody.get(k) for k in ('launchRequestToPIDStopCompleteSeconds', 'launchRequestToFirstPIDAbsenceSeconds',
                                    'launchRequestToIndependentPIDAbsenceSeconds')]
    require(cleanup.get('sessionAttempted') is False and cleanup.get('sessionSuccess') is True and
            cleanup.get('sessionErrorDomain') == '' and type(cleanup.get('sessionErrorCode')) is int and cleanup['sessionErrorCode'] == 0 and
            cleanup.get('cleanupDeactivationRequested') is custody.get('fixtureCleanupDeactivationRequested') is False and
            all(custody.get(k) is True for k in ('fixtureEngineStopped', 'fixtureCleanupSucceeded',
                'exactInstalledExecutableVerifiedBeforePIDStop', 'trustedPIDStopRequested', 'twoIndependentPIDAbsenceReadbacks',
                'ownedAppUninstalled', 'independentOwnAppAbsence', 'nativeStopDeadlineMet')) and
            all(number(v) and v > 0 for v in times) and times == sorted(times) and
            type(custody.get('nativeCapSeconds')) is int and times[-1] < custody['nativeCapSeconds'] == 90 and
            number(custody.get('operatorElapsedSeconds')) and type(custody.get('operatorHardBudgetSeconds')) is int and
            0 < custody['operatorElapsedSeconds'] < custody['operatorHardBudgetSeconds'] == 360, 'no-I/O: cleanup/caps incomplete')
    return dict(fullNoIOComplete=True, ordinaryPhysicalProducerDecoderConsumerQualified=True,
                notificationTransportExercised=True, fourOperationsCompleted=True, inventories=inventories,
                ioSnapshots=len(io_rows), silentRenderingExercised=False, hardwareLCKInterruptionExercised=False,
                resumptionRecommendationExercised=False, ciAttested=False)


def validate(source_root=ROOT, packet=None, shared_packet=None):
    source_root = Path(source_root)
    packet = source_root / PACKET if packet is None else Path(packet)
    shared = source_root / old.PACKET if shared_packet is None else Path(shared_packet)
    require(old.digest(packet / 'MANIFEST.json') == MANIFEST_SHA256, 'no-I/O: packet manifest differs')
    manifest = json.loads((packet / 'MANIFEST.json').read_text())
    require(type(manifest.get('schemaVersion')) is int and manifest['schemaVersion'] == 1 and manifest.get('mode') == 'ordinary-noio' and
            set(manifest.get('files', {})) == {'README.md', 'device-trace.jsonl', 'receipt.json'} and
            all((packet / name).is_file() and (packet / name).stat().st_size > 0 and old.sha(value) and
                old.digest(packet / name) == value for name, value in manifest['files'].items()), 'no-I/O: missing/empty/unbound packet')
    shared_manifest = json.loads((shared / 'MANIFEST.json').read_text())
    sources = {'core/' + name for name in old.AUDIO_FILES} | set(old.PROBE_FILES)
    require(manifest.get('sharedSourceDirectory') == '../' + old.PACKET.name and
            manifest.get('sharedSourceManifestSHA256') == old.digest(shared / 'MANIFEST.json') == old.MANIFEST_SHA256 and
            manifest.get('frozenPacketManifestSHA256') == shared_manifest['frozenPacketManifestSHA256'] and
            manifest.get('sourceFileSHA256') == shared_manifest['sourceFileSHA256'] and set(manifest['sourceFileSHA256']) == sources and
            all((shared / name).is_file() and (shared / name).stat().st_size > 0 and old.digest(shared / name) == value
                for name, value in manifest['sourceFileSHA256'].items()), 'no-I/O: shared source manifest/files differ')
    require(all(old.digest(source_root / name) == manifest['sourceFileSHA256']['core/' + name] for name in old.AUDIO_FILES),
            'no-I/O: current shipping audio differs from measured source')
    receipt = json.loads((packet / 'receipt.json').read_text())
    earlier = json.loads((shared / 'receipt.json').read_text())
    require(type(receipt.get('schemaVersion')) is int and receipt['schemaVersion'] == 1 and receipt.get('mode') == 'ordinary-noio' and
            all(receipt['source'].get(k) == manifest[k] for k in
                ('sharedSourceDirectory', 'sharedSourceManifestSHA256', 'frozenPacketManifestSHA256')) and
            type(receipt['source'].get('sharedSourceFiles')) is int and receipt['source']['sharedSourceFiles'] == len(sources) and
            receipt['source'].get('eightProductionAudioFilesByteIdenticalAtBothCommits') is True and
            all(receipt['build'].get(k) == earlier['build'][k] for k in ('executableSHA256', 'infoSHA256')) and
            receipt['capture'].get('file') == 'device-trace.jsonl' and receipt['capture'].get('sha256') == manifest['files']['device-trace.jsonl'] and
            type(receipt['capture'].get('rows')) is int and len(receipt.get('privateReceiptSHA256', {})) == 18 and
            all(old.sha(v) for v in receipt['privateReceiptSHA256'].values()), 'no-I/O: source/capture/local custody unbound')
    trace = (packet / 'device-trace.jsonl').read_bytes()
    require(trace.endswith(b'\n'), 'no-I/O: partial trace')
    result = validate_transport([json.loads(line) for line in trace.decode().splitlines()], receipt)
    return dict(scope='completed physical ordinary-session no-I/O raw/C/Swift scalar transport only',
                packetManifestSHA256=MANIFEST_SHA256, traceSHA256=receipt['capture']['sha256'],
                sourceFileSHA256=manifest['sourceFileSHA256'], runID=receipt['run']['runID'],
                executableSHA256=receipt['build']['executableSHA256'], **result)


if __name__ == '__main__':
    try:
        print(json.dumps(validate(), indent=2))
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps(dict(fullNoIOComplete=False, error=str(error)), indent=2))
        raise SystemExit(1)
