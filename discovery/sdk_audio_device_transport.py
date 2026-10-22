#!/usr/bin/env python3
"""Check a bounded physical notification-transport slice, never the full probe.

The committed packet preserves a failed four-operation ordinary-session probe.
Its raw Apple notifications, actual C decoder and actual Swift consumer still
provide a source-bound scalar transport measurement. Private build/cleanup
receipts are hash references and local custody assertions, not CI attestation.
"""
import hashlib
import json
from pathlib import Path

from summarize import EvidenceError, one, require

ROOT = Path(__file__).resolve().parent.parent
PACKET = Path('docs/research/callkit-simulator-probe/audio-session-lifecycle/2026-10-22-iphone13-ios27')
MANIFEST_SHA256 = '0c6b26bf65d3f5ac5e4ab2028046b9643e85163afab364bcce2ee92fed8263ce'
AUDIO_FILES = (
    'Sources/VoIPPlatform/VSAudioSessionLifecycleObserver.m',
    'Sources/VoIPPlatform/VSAudioSessionQueue.m',
    'Sources/VoIPPlatform/include/VSAudioSessionLifecycleObserver.h',
    'Sources/VoIPPlatform/include/VSAudioSessionQueue.h',
    'Sources/VoIPSDK/AudioRoutes.swift', 'Sources/VoIPSDK/AudioSessionConfiguration.swift',
    'Sources/VoIPSDK/AudioSessionQueue.swift', 'Sources/VoIPSDK/SystemAudioSession.swift')
PROBE_FILES = ('probe/AudioOperations.h', 'probe/AudioOperations.m', 'probe/Info.plist',
               'probe/Probe-Bridging.h', 'probe/Probe.swift', 'project.yml')
SCALARS = ('kind', 'hasSource', 'source', 'hasInterruptionReason', 'interruptionReason', 'shouldResume')
NAMES = dict(active='AVAudioSessionDidBecomeActiveNotification',
             inactive='AVAudioSessionDidBecomeInactiveNotification',
             recommended='AVAudioSessionResumptionRecommendationNotification')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def tagged(row):
    return tuple((type(row.get(key)).__name__, row.get(key)) for key in ('phase', *SCALARS))


def validate_transport(rows, receipt):
    """Validate the measured transport facts independently of their file hashes."""
    run, build, capture = receipt['run'], receipt['build'], receipt['capture']
    require(rows and len(rows) == capture['rows'] and
            [r.get('sequence') for r in rows] == list(range(1, len(rows) + 1)) and
            all(type(r.get('sequence')) is int and type(r.get('t_ms')) is int and r['t_ms'] >= 0 and
                type(r.get('wallTimeMS')) is int and r['wallTimeMS'] > 0 for r in rows) and
            all(a['t_ms'] <= b['t_ms'] and a['wallTimeMS'] <= b['wallTimeMS']
                for a, b in zip(rows, rows[1:])), 'physical transport: invalid trace sequence/time')
    require(type(run.get('trustedPID')) is int and run['trustedPID'] > 0 and run.get('simulator') is False and
            run.get('osVersion') == '27.0' and run.get('deviceModel') == 'iPhone 13' and
            all(r.get('runID') == run['runID'] and type(r.get('pid')) is int and
                r['pid'] == run['trustedPID'] and r.get('bundleID') == 'dev.iosvoipsdk.audio-lifecycle-probe'
                and r.get('main') is True for r in rows), 'physical transport: mixed device/run/PID/main identity')
    launch = one(rows, 'launch')
    require(rows[0] is launch and rows[-1]['event'] == 'done' and launch.get('simulator') is False and
            launch.get('osVersion') == run['osVersion'] and sha(build.get('executableSHA256')) and
            launch.get('executableSHA256') == build['executableSHA256'] and sha(build.get('infoSHA256')) and
            build.get('configuration') == 'Release' and build.get('localCodeSignatureVerified') is True and
            build.get('sourceBuildInstalledCustodyAndTrustedLaunchBound') is True and build.get('ciAttested') is False,
            'physical transport: unbound local build/launch')
    installed = one(rows, 'observers.installed')
    require(installed.get('actualSwiftConsumer') is True and installed.get('independentCDecoder') is True and
            set(NAMES.values()) <= set(installed.get('rawNotificationNames', [])) and
            one(rows, 'session.configured').get('actualSDKConfiguration') is True,
            'physical transport: actual observer/decoder/consumer/configuration missing')
    for event in ('control.privateSentinelPosted', 'control.privateSentinelReceived', 'control.privateSentinelReturned'):
        control = one(rows, event)
        require(control.get('syntheticPrivateControl') is True and control.get('countsAsAVNotification') is False,
                'physical transport: private sentinel relabeled as Apple notification')

    streams = {event: [r for r in rows if r['event'] == event and r.get('kind') in NAMES]
               for event in ('raw.notification', 'decoder.lifecycle', 'consumer.lifecycle')}
    require(all(streams.values()) and all(r.get('kind') in NAMES for r in rows
            if r['event'] in ('decoder.lifecycle', 'consumer.lifecycle')), 'physical transport: lifecycle stream empty/unknown')
    inventories = {}
    for event, stream in streams.items():
        for row in stream:
            require(all(type(row.get(k)) is bool for k in ('hasSource', 'hasInterruptionReason', 'shouldResume')) and
                    all(type(row.get(k)) is int for k in ('source', 'interruptionReason')),
                    'physical transport: lifecycle scalar types differ')
            require((row['hasSource'] or row['source'] == 0) and
                    (row['hasInterruptionReason'] or row['interruptionReason'] == 0),
                    'physical transport: absent context has nonzero scalar')
            if event == 'raw.notification':
                require(row.get('notificationName') == NAMES[row['kind']], 'physical transport: wrong Apple notification name')
                if row['kind'] == 'inactive':
                    require(row.get('contextClass') == receipt['observations']['rawInactiveContextClass'] ==
                            'AVAudioSessionDeactivationContext' and row['hasSource'] is True and
                            row['source'] == receipt['observations']['rawInactiveSource'],
                            'physical transport: real typed inactive context missing')
        inventories[event] = {kind: sum(r['kind'] == kind for r in stream) for kind in NAMES}
    # Independent observers need not run raw→C→Swift. Compare each stream's
    # ordered, type-tagged scalar inventory, not their interleaved callback order.
    require(list(map(tagged, streams['raw.notification'])) == list(map(tagged, streams['decoder.lifecycle'])) ==
            list(map(tagged, streams['consumer.lifecycle'])), 'physical transport: raw/C/Swift scalar inventory differs')
    require(inventories == receipt['observations']['modernInventories'] and
            inventories['raw.notification']['active'] > 0 and inventories['raw.notification']['inactive'] > 0 and
            inventories['raw.notification']['recommended'] == 0 and
            receipt['observations'].get('modernScalarFields') == list(SCALARS) and
            receipt['observations'].get('typeTaggedInventoriesEqual') is True,
            'physical transport: receipt inventory differs; recommendation remains unmeasured')

    requested = [r for r in rows if r['event'] == 'operation.requested']
    require([r.get('phase') for r in requested] == receipt['result']['requestedOperations'] ==
            ['sync-activate', 'sync-deactivate', 'async-activate'] and
            [r.get('index') for r in requested] == [0, 1, 2] and
            receipt['result'].get('notRun') == ['async-deactivate'], 'physical transport: operation scope differs')
    for request in requested:
        phase = request['phase']
        result, observed = one(rows, 'operation.result', phase=phase), one(rows, 'operation.observed', phase=phase)
        require(rows.index(request) < rows.index(result) < rows.index(observed) and
                result.get('sessionAttempted') is True and result.get('sessionSuccess') is True and
                result.get('callAudioQueue') is True and result.get('callMain') is False,
                'physical transport: operation/actual audio queue result missing')
    observed = one(rows, 'operation.observed', phase='async-activate')
    initial = one(rows, 'operation.result', phase='async-activate')
    require(initial.get('engineRunning') is True and observed.get('engineRunning') is False and
            initial.get('renderFrames') == observed.get('renderFrames') and
            one(rows, 'experiment.failed').get('errorType') == 'ProbeFailure' and
            receipt['result'].get('fullFixturePassed') is False and receipt['result'].get('fourOperationsCompleted') is False and
            receipt['result'].get('unchangedStrictValidator') == 'RED: experiment incomplete/failed' and
            receipt['result'].get('engineStopCause') == 'UNKNOWN', 'physical transport: full probe RED was erased/reclassified')
    cleanup = one(rows, 'fixture.cleanup')
    require(cleanup.get('engineRunning') is False and cleanup.get('cleanupDeactivationRequested') is True and
            cleanup.get('sessionSuccess') is True and all(receipt['cleanup'].get(key) is True for key in
                ('fixtureEngineStopped', 'fixtureDeactivationSucceeded', 'exactInstalledExecutableVerifiedBeforePIDStop',
                 'trustedPIDStopRequested', 'twoIndependentPIDAbsenceReadbacks', 'ownedAppUninstalled',
                 'independentOwnAppAbsence', 'nativeStopDeadlineMet')) and
            receipt['cleanup']['launchToFirstPIDAbsenceSeconds'] < receipt['cleanup']['nativeCapSeconds'] and
            receipt['cleanup']['operatorElapsedSeconds'] < receipt['cleanup']['operatorHardBudgetSeconds'],
            'physical transport: owned cleanup/caps incomplete')
    return dict(transportSlicePassed=True, notificationTransportExercised=True, inventories=inventories,
                fullFixturePassed=False, fourOperationsCompleted=False, resumptionRecommendationExercised=False,
                hardwareLCKInterruptionExercised=False, ciAttested=False)


def validate(source_root=ROOT, packet=None):
    source_root = Path(source_root)
    packet = source_root / PACKET if packet is None else Path(packet)
    require(digest(packet / 'MANIFEST.json') == MANIFEST_SHA256, 'physical transport: packet manifest differs')
    manifest = json.loads((packet / 'MANIFEST.json').read_text())
    source_names = {'core/' + name for name in AUDIO_FILES} | set(PROBE_FILES)
    require(type(manifest.get('schemaVersion')) is int and manifest['schemaVersion'] == 1 and
            set(manifest.get('sourceFileSHA256', {})) == source_names and
            set(manifest.get('files', {})) == source_names | {'README.md', 'device-trace.jsonl', 'receipt.json'} and
            all((packet / name).is_file() and (packet / name).stat().st_size > 0 and sha(value) and
                digest(packet / name) == value for name, value in manifest['files'].items()) and
            all(manifest['files'][name] == value for name, value in manifest['sourceFileSHA256'].items()),
            'physical transport: missing/empty/unbound packet source/evidence')
    require(all(digest(source_root / name) == manifest['sourceFileSHA256']['core/' + name] for name in AUDIO_FILES),
            'physical transport: current shipping audio differs from measured source')
    receipt = json.loads((packet / 'receipt.json').read_text())
    require(type(receipt.get('schemaVersion')) is int and receipt['schemaVersion'] == 1 and
            receipt['source'].get('frozenPacketManifestSHA256') == manifest['frozenPacketManifestSHA256'] and
            receipt['source'].get('copiedSourceFiles') == len(source_names) and
            receipt['source'].get('eightProductionAudioFilesByteIdenticalAtBothCommits') is True and
            receipt['capture'].get('file') == 'device-trace.jsonl' and
            receipt['capture'].get('sha256') == manifest['files']['device-trace.jsonl'] and
            len(receipt.get('privateReceiptSHA256', {})) == 15 and all(sha(v) for v in receipt['privateReceiptSHA256'].values()),
            'physical transport: source/capture/private custody receipt unbound')
    rows = [json.loads(line) for line in (packet / 'device-trace.jsonl').read_text().splitlines()]
    result = validate_transport(rows, receipt)
    return dict(scope='physical ordinary-session raw/C/Swift scalar transport only',
                packetManifestSHA256=MANIFEST_SHA256, traceSHA256=receipt['capture']['sha256'],
                sourceFileSHA256=manifest['sourceFileSHA256'], runID=receipt['run']['runID'],
                executableSHA256=receipt['build']['executableSHA256'], **result)


if __name__ == '__main__':
    try:
        print(json.dumps(validate(), indent=2))
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps(dict(transportSlicePassed=False, error=str(error)), indent=2))
        raise SystemExit(1)
