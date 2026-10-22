#!/usr/bin/env python3
"""Debug native contracts; synthetic controls do not qualify native behavior."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

from device_oracles import check_deadline, deadline_bands
from sdk_m0_conformance import bound_rows, digest
from summarize import EvidenceError, load, one, require

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'dev.iosvoipsdk.m1contracts'
CASES = ('guard', 'unhandled-accept', 'duplicate-wrapper')
OWN_FILES = ('discovery/probe/sdk_m1_contracts.swift', 'discovery/build_sdk_m1_contracts.sh',
             'discovery/sdk_m1_contracts_conformance.py', 'discovery/check_sdk_m1_contracts.py',
             'discovery/probe/Info.plist', 'discovery/run_scenario.py', 'discovery/sdk_m0_conformance.py',
             'discovery/sdk_bootstrap_conformance.py', 'discovery/summarize.py', 'discovery/device_oracles.py', 'VERSION')
REFERENCE = 'docs/research/callkit-simulator-probe/livecommunicationkit/2026-10-21-iphone13-ios27-lck-basic.jsonl'
WARNING = 'Another CXProvider was created. D13 routes actions to the newest provider; keep one ConversationManager in this process.'
BUILD_FILES = ('SDKM1Contracts.app/SDKM1Contracts', 'SDKM1Contracts.app/Info.plist',
               'SDKM1Contracts.app/IosVoipSDKRuntime.bundle/ios-27.0.json',
               'SDKM1Contracts.app/IosVoipSDKRuntime.bundle/Info.plist', 'build.log',
               'source-before.json', 'source-after.json')


def source_identity(root=ROOT):
    names = set(subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard',
                                        '-z', '--', 'Sources'], cwd=root).decode().split('\0'))
    names.discard(''); names.update((*OWN_FILES, REFERENCE))
    value = hashlib.sha256()
    for name in sorted(names):
        value.update(name.encode() + b'\0' + (root / name).read_bytes() + b'\0')
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', *sorted(names)], cwd=root)
    return dict(sourceCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                sourceInputsSHA256=value.hexdigest(), sourceDirty=bool(dirty))


def record_build(directory, target):
    after = source_identity()
    (directory / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
    require(json.loads((directory / 'source-before.json').read_text()) == after, 'sources changed during build')
    info = dict(schemaVersion=1, product='sdk-m1-contracts', configuration='Debug', target=target, **after,
                files={name: digest(directory / name) for name in BUILD_FILES},
                xcodeVersion=subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                sdkVersion=subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip())
    (directory / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')


def guard_contract(rows, engine):
    owner = one(rows, 'contract.owner')
    require(owner.get('warnings') == 0 and isinstance(owner.get('identity'), str) and
            owner['identity'] and owner['identity'] == owner.get('sharedIdentity'), 'SDK singleton/owned warning mismatch')
    warnings = [r for r in rows if r['event'] == 'contract.warning']
    require([(r.get('phase'), r.get('count'), r.get('message')) for r in warnings] ==
            [(phase, count, WARNING) for phase, count in [('extra-cx', 1), ('extra-lck', 2)]],
            'foreign provider warning inventory/identity differs')
    created = [r for r in engine if r['event'] == 'provider.created']
    require(len(created) == 3 and len({r.get('provider') for r in created}) == 3, 'expected exactly three fixture providers')
    identities = [owner['identity']]
    for phase, count, warning in zip(('extra-cx', 'extra-lck'), (1, 2), warnings):
        begin = one(rows, 'contract.creationBegin', phase=phase)
        end = one(rows, 'contract.creationEnd', phase=phase)
        require(rows.index(owner) < rows.index(begin) < rows.index(warning) < rows.index(end) and
                end.get('warnings') == count and isinstance(end.get('identity'), str) and end['identity'],
                'foreign provider warning order/count differs')
        identities.append(end['identity'])
    require(len(set(identities)) == 3 and identities[1] == created[1]['provider'], 'foreign provider identity differs')
    return dict(success=True, warnings=2, providers=3)


def duplicate_contract(rows, engine):
    """Public duplicate result through genuine LCK, not NSError-depth inspection.

    `.pushKit` is a public API source argument here, not a real push delivery.
    The runtime supplies CX service behavior; the LCK framework is unchanged.
    """
    owner = one(rows, 'contract.owner')
    require(type(owner.get('warnings')) is int and owner['warnings'] == 0 and
            isinstance(owner.get('identity'), str) and owner['identity'] and
            owner['identity'] == owner.get('sharedIdentity') and owner.get('entryPoint') == 'VoIPApplication.start',
            'duplicate public application owner differs')
    require(not any(r['event'] in ('contract.warning', 'contract.duplicateUnexpectedAction') for r in rows),
            'duplicate contract received an unexpected owner/action')
    requests = [r for r in rows if r['event'] == 'contract.duplicateReportRequested']
    results = [r for r in rows if r['event'] == 'contract.duplicateReportResult']
    require(len(requests) == len(results) == 2, 'duplicate requires two public report attempts/results')
    call = results[0].get('conversationID')
    require(isinstance(call, str) and str(uuid.UUID(call)).upper() == call, 'invalid duplicate conversation UUID')
    payload_hash = requests[0].get('payloadSHA256')
    require(isinstance(payload_hash, str) and re.fullmatch('[0-9a-f]{64}', payload_hash), 'invalid duplicate payload digest')
    previous = rows.index(owner)
    markers = [r for r in engine if r['event'] == 'contract.duplicateReportBoundary']
    incoming = [r for r in engine if r['event'] == 'report.incoming']
    completed = [r for r in engine if r['event'] == 'report.completed']
    require(len(markers) == 4 and len(incoming) == len(completed) == 2,
            'duplicate must enter and complete two native reports')
    for index, tag in enumerate(('foreground', 'pushKit')):
        ordinal = index + 1
        request, result = requests[index], results[index]
        for row in (request, result):
            require(type(row.get('ordinal')) is int and row['ordinal'] == ordinal and
                    row.get('source') == tag and row.get('payloadSHA256') == payload_hash,
                    'duplicate public payload/source/order differs')
        require(result.get('accepted') is True and result.get('conversationID') == call and
                result.get('conversations') == [dict(id=call, status='ringing', hasConnectedAt=False, hasPending=False)] and
                result['conversations'][0].get('hasConnectedAt') is False and
                result['conversations'][0].get('hasPending') is False,
                'duplicate result must preserve one unconnected ringing conversation')
        require(previous < rows.index(request) < rows.index(result), 'duplicate public awaits overlap or reorder')
        previous = rows.index(result)
        before, after = markers[index * 2:index * 2 + 2]
        for marker, stage in ((before, 'requested'), (after, 'returned')):
            require(type(marker.get('ordinal')) is int and marker['ordinal'] == ordinal and
                    marker.get('stage') == stage and marker.get('source') == tag and
                    marker.get('payloadSHA256') == payload_hash, 'unbound duplicate native marker')
        require(after.get('callUUID') == call and incoming[index].get('callUUID') == call and
                completed[index].get('callUUID') == call and type(completed[index].get('error')) is int and
                completed[index]['error'] == (0, 2)[index], 'native duplicate completion identity/error differs')
        require(engine.index(before) < engine.index(incoming[index]) < engine.index(completed[index]) < engine.index(after),
                'native report escaped its awaited public call')
    require(engine.index(markers[1]) < engine.index(markers[2]), 'native duplicate calls overlap')
    end_request = one(rows, 'contract.duplicateEndRequested')
    handler = one(rows, 'contract.duplicateEndHandler')
    end_result = one(rows, 'contract.duplicateEndCommandResult')
    observation = one(rows, 'contract.duplicateObservation')
    require(all(r.get('conversationID') == call for r in (end_request, handler, end_result, observation)) and
            handler.get('origin') == 'app' and isinstance(handler.get('actionID'), str) and
            str(uuid.UUID(handler['actionID'])).upper() == handler['actionID'] and
            end_result.get('accepted') is True and observation.get('empty') is True and
            previous < rows.index(end_request) < rows.index(handler) < rows.index(observation) and
            rows.index(end_request) < rows.index(end_result) < rows.index(observation),
            'duplicate cleanup lacks public end request/handler/command result')
    snapshots = [r for r in rows if r['event'] == 'contract.duplicateSnapshot']
    require(snapshots and all(type(r.get('revision')) is int for r in snapshots) and
            all(a['revision'] < b['revision'] for a, b in zip(snapshots, snapshots[1:])), 'invalid duplicate snapshot revisions')
    pending = []
    for snapshot in snapshots:
        calls = snapshot.get('conversations')
        require(isinstance(calls, list) and len(calls) <= 1, 'duplicate projected another conversation')
        for value in calls:
            require(value.get('id') == call and value.get('status') in ('ringing', 'ending', 'ended') and
                    value.get('hasConnectedAt') is False, 'duplicate projection identity/state differs')
            if 'pending' in value:
                require(value['pending'] == dict(id=handler['actionID'], kind='end', origin='app') and
                        rows.index(end_request) < rows.index(snapshot) < rows.index(handler),
                        'duplicate pending action is not the observed public end')
                pending.append(snapshot)
    require(pending and snapshots[-1]['conversations'] == [] and
            rows.index(end_request) < rows.index(snapshots[-1]) < rows.index(observation),
            'duplicate cleanup lacks pending/empty SDK projections')
    created = [r for r in engine if r['event'] == 'provider.created']
    classifications = [r for r in engine if r['event'] == 'provider.apiKind' and r.get('delegatePresent') is True]
    require(len(created) == 1 and isinstance(created[0].get('provider'), str) and created[0]['provider'] and classifications and
            all(r.get('provider') == created[0].get('provider') and r.get('apiKind') == 'livecommunicationkit'
                for r in classifications), 'duplicate did not use one genuine LCK provider')
    boundaries = [r for r in engine if r['event'] == 'contract.duplicateEndBoundary']
    delivered = [r for r in engine if r['event'] == 'transaction.delivered']
    settled = [r for r in engine if r['event'] == 'action.settled']
    require(len(boundaries) == 3 and [r.get('stage') for r in boundaries] ==
            ['requested', 'command-returned', 'observed-complete'] and
            all(r.get('callUUID') == call for r in boundaries) and boundaries[-1].get('empty') is True,
            'unbound duplicate native end request/completion observation')
    require(len(delivered) == len(settled) == 1 and delivered[0].get('kinds') == ['CXEndCallAction'] and
            delivered[0].get('origin') == 'application' and delivered[0].get('provider') == created[0].get('provider') and
            isinstance(settled[0].get('actionID'), str) and settled[0]['actionID'] and
            delivered[0].get('actionIDs') == [settled[0]['actionID']] and settled[0].get('fulfilled') is True,
            'duplicate native cleanup was not one fulfilled app End action')
    states = [r for r in engine if r['event'] == 'call.changed']
    require(len(states) == 2 and all(r.get('uuid') == call and r.get('outgoing') is False and r.get('connected') is False for r in states) and
            states[0].get('ended') is False and states[-1].get('ended') is True and
            engine.index(incoming[0]) < engine.index(states[0]) < engine.index(completed[0]) and
            engine.index(markers[-1]) < engine.index(boundaries[0]) < engine.index(delivered[0]) <
            engine.index(settled[0]) < engine.index(states[-1]) < engine.index(boundaries[-1]),
            'duplicate native call did not end before its explicit completion observation')
    require(not any(r['event'] in ('action.timeout', 'provider.reset', 'report.ended') for r in engine),
            'duplicate cleanup timed out/reset or used a report-ended shortcut')
    return dict(success=True, nativeReportCompletionErrors=[0, 2], publicResultsSameUUID=True,
                liveConversations=1, cleanup='public app End action',
                classification='genuine LCK public-result compatibility on the simulator runtime',
                limits='Public source tag only; no PushKit delegate, NSError nesting-depth or physical-device claim.')


def accept_contract(rows, engine, source_root):
    configuration = one(rows, 'contract.configuration')
    require(configuration.get('policy') == 'accept' and configuration.get('handlerAttached') is False and
            rows.index(configuration) < rows.index(one(rows, 'contract.owner')), 'accept policy configured too late')
    require(not any(r['event'] == 'contract.warning' for r in rows) and one(rows, 'contract.owner').get('warnings') == 0,
            'unexpected provider ownership warning')
    incoming = one(rows, 'contract.incoming'); call = incoming.get('conversationID')
    pending = one(rows, 'contract.pending'); deadline = pending.get('deadlineMS')
    require(isinstance(call, str) and call and pending.get('conversationID') == call and
            pending.get('kind') == 'join' and pending.get('origin') == 'app' and
            pending.get('handlerAttached') is False and isinstance(pending.get('actionID'), str) and
            pending['actionID'] and type(deadline) is int, 'invalid native pending join')
    require(abs(deadline - pending['wallTimeMS'] - pending['remainingMS']) <= 2, 'pending deadline sample differs')
    reference = load(source_root / Path(REFERENCE).parent, Path(REFERENCE).stem)
    check_deadline(dict(kind='JoinConversationAction', timeoutIn=pending['remainingMS'] / 1000), deadline_bands(reference))
    snapshots = [r for r in rows if r['event'] == 'contract.snapshot']
    require(snapshots and all(type(r.get('revision')) is int for r in snapshots) and
            all(a['revision'] < b['revision'] for a, b in zip(snapshots, snapshots[1:])), 'invalid snapshot revision')
    connected = []
    native_pending = []
    for row in snapshots:
        calls = row.get('conversations')
        require(isinstance(calls, list) and len(calls) <= 1, 'duplicate conversation projection')
        for value in calls:
            require(value.get('id') == call and value.get('hasConnectedAt') is False, 'unbound/fabricated connected report')
            require(value.get('status') in ('ringing', 'connecting', 'connected', 'ending', 'ended'), 'unexpected accept state')
            if 'pending' in value:
                action = value['pending']
                require(action == dict(id=pending['actionID'], kind='join', origin='app', deadlineMS=deadline), 'pending identity/deadline changed')
                native_pending.append(row)
            if value.get('status') == 'connected':
                require(row['wallTimeMS'] >= deadline - 1 and value.get('pending') is None, 'accepted before deadline or still pending')
                connected.append(row)
    require(native_pending and native_pending[0]['wallTimeMS'] < deadline and connected and
            deadline - 1 <= connected[0]['wallTimeMS'] <= deadline + 3000, 'no deadline-bound connected state')
    require(one(rows, 'contract.observation').get('connected') is True and
            one(rows, 'contract.joinResult').get('accepted') is True, 'join never became connected')
    end_request = one(rows, 'contract.endReportRequested')
    ended = one(rows, 'contract.reportEnded')
    require(ended.get('conversationID') == call and rows.index(connected[0]) < rows.index(ended) and
            end_request.get('conversationID') == call and rows.index(connected[0]) < rows.index(end_request) <
            rows.index(snapshots[-1]) and snapshots[-1]['conversations'] == [], 'reported cleanup did not empty the SDK')
    delivered = [r for r in engine if r['event'] == 'transaction.delivered']
    settled = [r for r in engine if r['event'] == 'action.settled']
    require(len(delivered) == len(settled) == 1 and delivered[0].get('kinds') == ['CXAnswerCallAction'] and
            delivered[0].get('actionIDs') == [settled[0].get('actionID')] and settled[0].get('fulfilled') is True and
            not any(r['event'] == 'action.timeout' for r in engine), 'native answer settlement differs')
    native_connected = [r for r in engine if r['event'] == 'call.changed' and r.get('uuid') == call and
                        r.get('connected') is True and r.get('ended') is False]
    require(native_connected, 'native call never connected')
    marker = one(engine, 'contract.pendingClock')
    require(marker.get('actionID') == pending['actionID'] and type(pending.get('clockBeforeMS')) is int and
            0 <= pending['wallTimeMS'] - pending['clockBeforeMS'] <= 25, 'unbound or imprecise native clock sample')
    # The marker is synchronously journaled between two native wall-clock reads.
    # A 25 ms binding budget covers that interval; it never changes action expiry.
    for event in (settled[0], native_connected[0]):
        relative = event['t_ms'] - marker['t_ms']
        require(pending['clockBeforeMS'] + relative >= deadline - 25 and
                pending['wallTimeMS'] + relative <= deadline + 3025, 'native settlement/connection outside deadline budget')
    native_end = one(engine, 'report.ended')
    call_states = [r for r in engine if r['event'] == 'call.changed' and r.get('uuid') == call]
    require(native_end.get('callUUID') == call and call_states[-1].get('ended') is True and
            engine.index(delivered[0]) < engine.index(marker) < engine.index(settled[0]) <
            engine.index(native_connected[0]) < engine.index(native_end) < engine.index(call_states[-1]),
            'native delivery/settlement/connection/cleanup order differs')
    require(len([r for r in engine if r['event'] == 'provider.created']) == 1, 'accept created another provider')
    return dict(success=True, pendingDeadlineMS=deadline, connectedAfterDeadlineMS=connected[0]['wallTimeMS'] - deadline)


def validate_build(build, source_root=ROOT):
    info = json.loads((build / 'build-info.json').read_text())
    identity = source_identity(source_root)
    require(info.get('schemaVersion') == 1 and info.get('product') == 'sdk-m1-contracts' and
            info.get('configuration') == 'Debug' and identity['sourceDirty'] is False and
            all(info.get(k) == v for k, v in identity.items()), 'uncommitted or mismatched build source')
    require(info.get('files') == {name: digest(build / name) for name in BUILD_FILES} and
            json.loads((build / 'source-before.json').read_text()) == identity ==
            json.loads((build / 'source-after.json').read_text()), 'build files/source binding differs')
    return info, identity


def validate(build, capture, source_root=ROOT, parent_manifest=None):
    info, identity = validate_build(build, source_root)
    first = json.loads((capture / 'sdk-m1-contract-guard.receipt.json').read_text())
    manifest = {k: first.get(k) for k in ('runID', 'simulatorID')}
    require(all(isinstance(v, str) and v for v in manifest.values()), 'missing run/simulator identity')
    if parent_manifest is not None:
        parent = json.loads(parent_manifest.read_text())
        require(all(parent.get(k) == v for k, v in manifest.items()) and
                parent.get('sourceCommit') == identity['sourceCommit'], 'contracts differ from the parent SDK run')
    results = {}
    execution_os = None
    processes = set()
    for case in CASES:
        name = 'sdk-m1-contract-' + case
        rows, receipt = bound_rows(capture, name, manifest, BUNDLE)
        require(receipt['appPID'] not in processes, 'contracts reused a process')
        processes.add(receipt['appPID'])
        require(receipt.get('appEntryObserved') is True and [r['event'] for r in rows[:2]] == ['app.entry', 'launch'], 'missing app entry')
        require([r.get('sequence') for r in rows] == list(range(1, len(rows) + 1)) and
                all(type(r.get('wallTimeMS')) is int and r['wallTimeMS'] > 0 and
                    r.get('simulatorID') == manifest['simulatorID'] for r in rows) and
                all(a['wallTimeMS'] <= b['wallTimeMS'] for a, b in zip(rows, rows[1:])), 'invalid sequence/wall time')
        launch = one(rows, 'launch')
        require(isinstance(launch.get('simulatorOS'), str) and launch['simulatorOS'], 'missing execution OS')
        if execution_os is None: execution_os = launch['simulatorOS']
        require(launch['simulatorOS'] == execution_os, 'execution OS changed between contracts')
        require(launch.get('mode') == 'sdk-m1-contracts' and launch.get('case') == case and
                launch.get('traceVersion') == 2 and launch.get('runtimeInjectionPresent') is False and
                launch.get('executableSHA256') == info['files']['SDKM1Contracts.app/SDKM1Contracts'], 'launch/build contract differs')
        require(one(rows, 'contract.activation').get('active') is True and
                rows.index(one(rows, 'contract.activation')) < rows.index(one(rows, 'contract.owner')), 'runtime activation order differs')
        journal = capture / (name + '.runtime.jsonl')
        require(receipt.get('journalSHA256') == digest(journal), 'journal hash mismatch')
        engine = [json.loads(line) for line in journal.read_text().splitlines()]
        require(engine and [r.get('sequence') for r in engine] == list(range(1, len(engine) + 1)) and
                all(type(r.get('t_ms')) is int and r['t_ms'] >= 0 for r in engine) and
                all(a['t_ms'] <= b['t_ms'] for a, b in zip(engine, engine[1:])) and
                all(r.get('runID') == manifest['runID'] and r.get('pid') == receipt['appPID'] and
                    r.get('bundleID') == BUNDLE and r.get('profile') == 'ios-27.0' for r in engine), 'mixed runtime journal')
        require(one(engine, 'runtime.installed').get('version') == (source_root / 'VERSION').read_text().strip(), 'runtime version differs')
        if case == 'guard': results[case] = guard_contract(rows, engine)
        elif case == 'duplicate-wrapper': results[case] = duplicate_contract(rows, engine)
        else: results[case] = accept_contract(rows, engine, source_root)
        require(one(rows, 'contract.result').get('success') is True and not any(r['event'] == 'contract.error' for r in rows), 'native contract reported failure')
    return dict(success=True, classification='measured native contracts', cases=results,
                simulatorOS=execution_os, source=identity, buildInfoSHA256=digest(build / 'build-info.json'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path); parser.add_argument('capture', type=Path)
    parser.add_argument('--parent-manifest', type=Path)
    args = parser.parse_args()
    try: result = validate(args.build, args.capture, parent_manifest=args.parent_manifest)
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.SubprocessError) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['success'] else 1)
