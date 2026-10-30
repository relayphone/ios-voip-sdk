#!/usr/bin/env python3
"""Strict system-origin cases; existing M1 app-origin acceptance stays separate."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import runpy
import sys
import uuid

import sdk_m0_conformance as m0
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/sim'))
from sim import bounded
from sdk_m1_conformance import read_journal, timestamp_ms, deadline_oracles
from device_oracles import d5_compositions, check_deadline
from summarize import EvidenceError, load, one, require

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'dev.iosvoipsdk.example'
CASES = ('answer-end', 'decline', 'hold-accept', 'end-accept', 'mute-echo', 'provider-reset', 'push-launch', 'answered-elsewhere')
ANSWERED_ELSEWHERE_BUDGET_MS = 1000
D5 = 'docs/research/callkit-simulator-probe/device-system-ui/2026-10-20-iphone13-ui10-app.jsonl'
COLD_PUSH = 'docs/research/callkit-simulator-probe/livecommunicationkit/push/2026-10-23-iphone13-ios27-d1-locked-cold-answer.jsonl'
NATIVE = dict(join='CXAnswerCallAction', end='CXEndCallAction', hold='CXSetHeldCallAction',
              mute='CXSetMutedCallAction', tones='CXPlayDTMFCallAction')


def cold_push_reference(source_root=ROOT):
    rows = [json.loads(line) for line in (source_root / COLD_PUSH).read_text().splitlines()]
    launch, received, report, returned, completed = (one(rows, 'lckpush.' + event) for event in
        ('launch', 'received', 'reportStart', 'delegateReturn', 'reported'))
    require(launch.get('os') == '27.0' and launch.get('strategy') == 'entered' and
            received.get('mustReport') is True and received.get('main') is False and
            report.get('afterMs') == 0 and returned.get('reportEntered') is True and
            received['t_ms'] <= report['t_ms'] < returned['t_ms'] < completed['t_ms'] and
            completed.get('result') == 'ok', 'cold device reference differs')
    return {COLD_PUSH: m0.digest(source_root / COLD_PUSH)}


def uuid_value(value):
    require(isinstance(value, str) and str(uuid.UUID(value)).upper() == value, 'invalid canonical UUID')
    return value


def package_check(directory, identity, source_root=ROOT):
    runpy.run_path(str(source_root / 'Tools/cksim'))['validate_package'](directory)
    info = json.loads((directory / 'build-info.json').read_text())
    inputs = [source_root / 'VERSION', source_root / 'docs/simulator-runtime.md'] + [path for name in ('Sources', 'Tools', 'scripts')
        for path in (source_root / name).rglob('*') if path.is_file() and '__pycache__' not in path.parts]
    source_hash = hashlib.sha256()
    for path in sorted(inputs): source_hash.update(str(path.relative_to(source_root)).encode() + b'\0' + path.read_bytes() + b'\0')
    require(info.get('sourceCommit') == identity['sourceCommit'] and info.get('sourceDirty') is False and
            info.get('sourceInputsSHA256') == source_hash.hexdigest() and
            m0.digest(directory / 'cksim') == m0.digest(source_root / 'Tools/cksim'), 'unbound cksim control package')
    return info


def supervisor_check(receipt, index, failed_cleanup):
    owner = index.get('supervisorPID')
    require(type(owner) is int and owner > 0 and receipt.get('inheritLauncherGroup') is True and
            all(type(receipt.get(key)) is int and receipt[key] == owner for key in
                ('supervisorPID', 'supervisorPGID', 'supervisorSID', 'launcherPGID')) and
            owner != receipt['launcherPID'] != receipt['appPID'] and owner != receipt['appPID'] and
            receipt.get('supervisorGroupAbsentAfterStop') is True,
            'unbound private supervisor/console group or missing absence proof')
    require(not failed_cleanup, 'failure cleanup cannot qualify a native journey')


def validate_case(rows, engine, index, controls, fixture_commands, case, expected_d5, profile, launch_receipt=None):
    """Pure logical gate, also exercised by synthetic negative controls.

    The enclosing gate binds the original trace/journal, launcher PID, source,
    products, controls and cleanup. No LCK UUID is equated with a CX UUID.
    """
    launch = one(rows, 'launch')
    require(launch.get('mode') == 'sdk-system' and launch.get('case') == case and launch.get('traceVersion') == 2,
            'wrong system journey mode')
    require([row['event'] for row in rows[:2]] == ['app.entry', 'launch'] and
            [row.get('sequence') for row in rows] == list(range(1, len(rows) + 1)) and
            all(type(row.get('wallTimeMS')) is int and row['wallTimeMS'] > 0 for row in rows), 'invalid app sequence/clock')
    require(one(rows, 'sdk.activation').get('active') is True and
            one(rows, 'sdk.managerCreated').get('owner') == 'VoIPApplication.start' and
            one(rows, 'sdk.result').get('success') is True, 'SDK journey failed')
    require(not any(row['event'].startswith(('m1.', 'diagnostic.')) or row.get('errorType') or row.get('error') for row in rows) and
            not any(row['event'].startswith(('diagnostic.', 'action.timeout', 'push.launchRefused')) for row in engine), 'unexpected injection/error/timeout')
    ready = one(rows, 'system.ready')
    require(ready.get('attached') is (case != 'push-launch'), 'wrong cold-handler policy')
    marker = one(engine, 'system.clock')
    require(type(marker.get('t_ms')) is int, 'invalid handler delivery clock')
    require(type(ready.get('clockBeforeMS')) is int and 0 <= ready['wallTimeMS'] - ready['clockBeforeMS'] <= 25,
            'unbounded journal clock bridge')
    bindings = index.get('bindings')
    roles = ['first', 'waiting'] if case in ('hold-accept', 'end-accept') else ['first']
    require(isinstance(bindings, list) and [value.get('role') for value in bindings] == roles, 'wrong call binding inventory')
    for field in ('conversationID', 'callUUID', 'pushID'):
        require(len({uuid_value(value.get(field)) for value in bindings}) == len(bindings), 'ambiguous ' + field)
    by_sdk = {value['conversationID']: value for value in bindings}
    by_native = {value['callUUID']: value for value in bindings}
    for event in [row for row in rows if row['event'] == 'system.event']:
        name = event.get('name')
        require('conversationId' not in event, 'invalid SDK event context field')
        if case == 'answered-elsewhere' and name == 'answeredElsewhere':
            require(event.get('conversationID') in by_sdk, 'unbound answered-elsewhere SDK event')
        else:
            require(name in ('audioActivated', 'audioDeactivated', 'providerReset', 'pushTokenUpdated'),
                    'unexpected SDK event context')
            require('conversationID' not in event, 'invalid global SDK event context')
    snapshots = [row for row in rows if row['event'] == 'sdk.snapshot']
    require(snapshots and all(type(row.get('revision')) is int for row in snapshots) and
            all(a['revision'] < b['revision'] for a, b in zip(snapshots, snapshots[1:])) and
            snapshots[-1].get('conversations') == [], 'invalid/final nonempty projection')
    for snapshot in snapshots:
        calls = snapshot.get('conversations')
        require(isinstance(calls, list) and len(calls) <= len(roles) and len({call['id'] for call in calls}) == len(calls), 'duplicate projection')
        for call in calls:
            require(call.get('id') in by_sdk and call.get('direction') == 'incoming' and
                    call.get('status') in ('ringing', 'connecting', 'connected', 'held', 'ending', 'ended') and
                    all(type(call.get(field)) is bool for field in ('isMuted', 'isVideo', 'hasConnectedAt')), 'unbound projected call')
    hooks = [row for row in rows if row['event'] == 'system.hook']
    require(hooks and hooks[-1].get('count') == 0 and hooks[-1]['sequence'] > snapshots[-1]['sequence'], 'final hook not observed')
    if case == 'decline':
        require(not any(call['status'] in ('connecting', 'connected', 'held') for row in snapshots for call in row['conversations']), 'declined call connected')
    for binding in bindings:
        report = one([row for row in engine if row.get('pushID') == binding['pushID']], 'report.incoming')
        require(report.get('callUUID') == binding['callUUID'] and report['sequence'] == binding.get('reportSequence'), 'incoming/native call binding differs')
        initial = next((row for row in snapshots if any(call['id'] == binding['conversationID'] for call in row['conversations'])), None)
        require(initial and initial['sequence'] == binding.get('snapshotSequence') and
                next(call for call in initial['conversations'] if call['id'] == binding['conversationID'])['status'] == 'ringing', 'incoming/SDK binding differs')
    require(len([row for row in engine if row['event'] == 'report.incoming']) == len(bindings) + (case == 'mute-echo'), 'incoming report-attempt inventory differs')

    requests = []
    actions = []
    expected_operations = {
        'answer-end': ['push', 'answer', 'end'], 'decline': ['push', 'decline'],
        'hold-accept': ['push', 'answer', 'push', 'hold-and-accept', 'end', 'end'],
        'end-accept': ['push', 'answer', 'push', 'end-and-accept', 'end'],
        'mute-echo': ['push', 'answer', 'mute', 'push', 'reset', 'mute', 'tones', 'end'],
        'provider-reset': ['push', 'answer', 'reset'], 'push-launch': ['answer', 'end'],
        'answered-elsewhere': ['push'],
    }[case]
    require(len(controls) == len(expected_operations), 'control inventory differs')
    for control, operation in zip(controls, expected_operations):
        request, response, session = (control.get(key, {}) for key in ('request', 'response', 'session'))
        refusal = case == 'mute-echo' and operation == 'reset'
        require(control.get('schemaVersion') == 1 and request.get('operation') == operation and response.get('success') is (not refusal) and
                session.get('schemaVersion') == 1 and session.get('profile') == 'ios-27.0', 'invalid command receipt/operation')
        if refusal: require('selected-provider reset requires no pending runtime actions' in response.get('error', ''), 'unsafe pending reset was not refused')
        uuid_value(request.get('id'))
        require(all(request.get(key) == response.get(key) == session.get(key) == launch.get(key) for key in ('runID', 'pid', 'bundleID')) and
                request['id'] == response.get('id') and session.get('controlTransport') == 'directory-watch-v1', 'control identity differs')
        requests.append(request)
        if operation in ('push', 'reset'):
            continue
        delivered = one([row for row in engine if row.get('requestID') == request['id']], 'transaction.delivered')
        ids = response.get('result', {}).get('actionIDs')
        require(isinstance(ids, list) and ids and len(set(ids)) == len(ids) and delivered.get('actionIDs') == ids and
                delivered.get('origin') == 'system', 'system native action binding/origin differs')
        for identity in ids: uuid_value(identity)
        if operation in ('hold-and-accept', 'end-and-accept'):
            expected = expected_d5[operation]
            targets = {'active': request.get('activeCallUUID'), 'waiting': request.get('callUUID')}
            require(targets == {'active': bindings[0]['callUUID'], 'waiting': bindings[1]['callUUID']}, 'D5 active/waiting call differs')
            signatures = [(item['kind'], targets[item['role']], {'held': item['onHold']} if 'onHold' in item else {}) for item in expected]
        else:
            kind = {'answer': 'join', 'decline': 'end'}.get(operation, operation)
            params = {field: request[field] for field in ('held', 'muted', 'digits') if field in request}
            signatures = [(NATIVE[kind], request.get('callUUID'), params)]
        require(delivered.get('kinds') == [item[0] for item in signatures] and
                delivered.get('callUUIDs') == [item[1] for item in signatures] and
                delivered.get('parameters') == [item[2] for item in signatures], 'native composition/parameters differ from device/control')
        actions += [dict(id=identity, kind=kind, call=call, params=params, origin='system', delivered=delivered)
                    for identity, (kind, call, params) in zip(ids, signatures)]
    require(len({request['id'] for request in requests}) == len(requests), 'duplicate control nonce')
    if case == 'mute-echo':
        extras = [row for row in engine if row['event'] == 'transaction.delivered' and row.get('origin') in ('application', 'muteEcho')]
        require([row.get('origin') for row in extras] == ['application', 'muteEcho'], 'missing app-mute/automatic-echo transaction')
        for transaction in extras:
            require(transaction.get('kinds') == [NATIVE['mute']] and transaction.get('callUUIDs') == [bindings[0]['callUUID']] and
                    transaction.get('parameters') == [{'muted': False}] and len(transaction.get('actionIDs', [])) == 1, 'wrong app mute/echo')
            actions.append(dict(id=uuid_value(transaction['actionIDs'][0]), kind=NATIVE['mute'], call=bindings[0]['callUUID'],
                                params={'muted': False}, origin=transaction['origin'], delivered=transaction))
    require({action['id'] for action in actions} == {identity for row in engine if row['event'] == 'transaction.delivered' for identity in row.get('actionIDs', [])} and
            len(actions) == sum(len(row.get('actionIDs', [])) for row in engine if row['event'] == 'transaction.delivered'), 'unexpected native action')
    for action in actions:
        require(action['call'] in by_native, 'native action targets unknown call')
        settled = one([row for row in engine if row.get('actionID') == action['id']], 'action.settled')
        advertised = one([row for row in engine if row.get('actionID') == action['id']], 'action.deadline')
        # Effective expiry is independent of timeoutDate and comes from the source-bound profile.
        expiry = (profile['lckMultiCall']['joinExpirySeconds'] if action['kind'] == NATIVE['join'] else
                  profile['lckMultiCall']['pauseEndExpirySeconds'] if action['kind'] in (NATIVE['hold'], NATIVE['end']) else
                  profile['lckActionDeadlineSeconds'])
        require(settled.get('fulfilled') is True and settled.get('expired') is False and settled.get('origin') == action['origin'] and
                action['delivered']['sequence'] < advertised['sequence'] < settled['sequence'] and
                advertised.get('apiKind') == 'livecommunicationkit' and advertised.get('deadlineSeconds') == 30 and
                advertised.get('expirySeconds') == expiry and
                all(type(advertised.get(key)) is int for key in ('deadlineMS', 'issuedAtMS', 'expiryMS')) and
                advertised.get('provider') == action['delivered'].get('provider') and advertised['expiryMS'] == advertised['issuedAtMS'] + expiry * 1000, 'unsettled/expired/wrong native deadline')
        upper = ready['wallTimeMS'] + settled['t_ms'] - marker['t_ms'] + 1
        require(upper < min(advertised['deadlineMS'], advertised['expiryMS']),
                'native settlement reached platform expiry')
        action.update(settled=settled, deadline=advertised)

    handlers = [row for row in rows if row['event'] == 'system.handler']
    # A same-value pending echo and the automatic fulfilled echo must be
    # fulfilled natively without a second JS signaling callback.
    signaling = [action for action in actions if action['origin'] != 'muteEcho']
    if case == 'mute-echo':
        false_mutes = [action for action in signaling if action['kind'] == NATIVE['mute'] and action['params'] == {'muted': False} and action['origin'] == 'system']
        require(len(false_mutes) == 1, 'pending echo identity missing')
        signaling.remove(false_mutes[0])
        app = next(action for action in signaling if action['origin'] == 'application')
        require(app['delivered']['sequence'] < false_mutes[0]['delivered']['sequence'] < false_mutes[0]['settled']['sequence'] < app['settled']['sequence'], 'same-value echo was not pending')
        refused = one(engine, 'control.rejected')
        reset_request = next(request for request in requests if request['operation'] == 'reset')
        require(refused.get('requestID') == reset_request['id'] and refused.get('operation') == 'reset' and
                'selected-provider reset requires no pending runtime actions' in refused.get('error', '') and
                app['delivered']['sequence'] < refused['sequence'] < app['settled']['sequence'], 'pending reset refusal was not bound')
    else: require(not any(row['event'] == 'control.rejected' for row in engine), 'unexpected runtime command rejection')
    require(len(handlers) == len(signaling), 'handler inventory differs/echo escaped')
    require(len([row for row in engine if row['event'] == 'system.handlerEntered']) == len(handlers), 'handler journal markers differ')
    remaining = signaling.copy()
    for handler in handlers:
        kind, call = NATIVE.get(handler.get('kind')), by_sdk.get(handler.get('conversationID'))
        origin = 'application' if handler.get('origin') == 'app' else handler.get('origin')
        candidates = [action for action in remaining if action['kind'] == kind and call and action['call'] == call['callUUID'] and action['origin'] == origin]
        require(candidates, 'handler origin/kind/role unbound')
        action = candidates[0]; remaining.remove(action)
        require(all(handler.get(key) == value for key, value in action['params'].items()), 'handler parameters differ')
        deadline = timestamp_ms(handler.get('deadline'))
        require(type(action['delivered'].get('t_ms')) is int and
                action['delivered']['t_ms'] >= marker['t_ms'], 'invalid handler delivery clock')
        advertised = action['deadline']['deadlineMS']
        cap = {NATIVE['hold']: 5300, NATIVE['end']: 5300, NATIVE['join']: 64000}.get(kind)
        # The runtime mirror precedes LCK's own action construction. Keep the
        # existing upper envelope; start/join now reserves three seconds for
        # audio fulfillment, so its lower margin is stricter.
        margin = 3000 if handler.get('kind') in ('start', 'join') else 1500
        lower, upper = advertised - 3500, advertised - (2500 if margin == 3000 else 1000)
        if cap is not None:
            relative = action['delivered']['t_ms'] - marker['t_ms']
            # The synchronous clock bridge brackets the wall offset within 25 ms.
            # A separate 250 ms cross-layer allowance bounds delegate delivery;
            # it does not prove the SDK's exact capture instant or extend timeoutDate.
            lower = min(lower, ready['clockBeforeMS'] + relative + cap - margin)
            upper = min(upper, ready['wallTimeMS'] + relative + cap + 250 - margin)
        require(lower - 1 <= deadline <= upper + 1 and handler['wallTimeMS'] < deadline,
                'handler deadline differs from selected cap and margin')
        entered = one([row for row in engine if row.get('traceSequence') == handler['sequence']], 'system.handlerEntered')
        require(all(entered.get(key) == handler.get(key) for key in ('kind', 'conversationID', 'origin', 'deadline', *action['params'])) and
                action['delivered']['sequence'] < entered['sequence'] < action['settled']['sequence'], 'handler/native causal order differs')
        pending = [call['pending'] for snapshot in snapshots for call in snapshot['conversations'] if call['id'] == handler['conversationID'] and
                   call.get('pending', {}).get('kind') == handler['kind'] and call['pending'].get('origin') == handler['origin']]
        require(any(value.get('deadline') == handler['deadline'] for value in pending), 'handler/pending deadline mismatch')
    require(not remaining, 'missing signaling handler')
    if case == 'mute-echo':
        for muted, origin in ((True, 'system'), (False, 'app')):
            handler = next(row for row in handlers if row['kind'] == 'mute' and row['origin'] == origin)
            require(any(row['sequence'] > handler['sequence'] and any(call['id'] == handler['conversationID'] and call['isMuted'] is muted and 'pending' not in call
                        for call in row['conversations']) for row in snapshots) and
                    any(row['sequence'] > handler['sequence'] and row.get('conversationID') == handler['conversationID'] and row.get('muted') is muted
                        for row in hooks), 'mute projection/hook did not round trip')

    for request in [value for value in requests if value['operation'] == 'push']:
        push = [row for row in engine if row.get('pushID') == request['id']]
        received, returned, completed = (one(push, event) for event in ('push.received', 'push.callbackReturned', 'push.completed'))
        required = request.get('mustReport') if received.get('api') == 'metadata' else True
        require(type(request.get('mustReport')) is bool and received.get('api') in ('metadata', 'legacy') and received.get('mustReport') is required and
                all(row.get('mustReport') is required and row.get('reportEntered') is True for row in (returned, completed)) and
                received['sequence'] < returned['sequence'] and received['sequence'] < completed['sequence'], 'PushKit delivery/callback receipt differs')
        report, reported = one(push, 'report.incoming'), one(push, 'report.completed')
        expected_error = 2 if case == 'mute-echo' and request['mustReport'] is False else 0
        require(report['sequence'] < returned['sequence'] and report['sequence'] < reported['sequence'] < completed['sequence'] and
                type(reported.get('error')) is int and reported.get('error') == expected_error and reported.get('callUUID') == report.get('callUUID'),
                'incoming wrapper attempt/completion differs')
        if expected_error:
            require(report.get('callUUID') == bindings[0]['callUUID'], 'duplicate invitation targeted another call')
    if case == 'mute-echo':
        pushes = [request for request in requests if request['operation'] == 'push']
        require(len(pushes) == 2 and pushes[0].get('payload') == pushes[1].get('payload') and
                pushes[0].get('mustReport') is True and pushes[1].get('mustReport') is False, 'duplicate push was not the same event')
        first_connected = next(row['sequence'] for row in snapshots if any(call['status'] == 'connected' for call in row['conversations']))
        require(not any(row['sequence'] > first_connected and any(call['status'] == 'ringing' for call in row['conversations']) for row in snapshots),
                'duplicate invitation rang again')

    require(len(fixture_commands) == len(index.get('fixtureCommands', [])), 'fixture command inventory differs')
    for command in fixture_commands:
        uuid_value(command.get('id'))
        require(all(command.get(key) == launch.get(key) for key in ('runID', 'pid')) and command.get('case') == case, 'fixture command identity differs')
        delivered = one([row for row in rows if row.get('id') == command['id']], 'system.commandReceived')
        completed = one([row for row in rows if row.get('id') == command['id']], 'system.commandCompleted')
        require(delivered.get('operation') == completed.get('operation') == command.get('operation') and
                delivered['sequence'] < completed['sequence'], 'fixture command was not acknowledged')
    expected_commands = {
        'answer-end': ['backend-connected', 'finish'], 'decline': ['finish'],
        'hold-accept': ['backend-connected', 'backend-connected', 'finish'],
        'end-accept': ['backend-connected', 'backend-connected', 'finish'],
        'mute-echo': ['backend-connected', 'app-mute', 'release-mute', 'finish'],
        'provider-reset': ['backend-connected', 'finish'],
        'push-launch': ['attach-handler', 'backend-connected', 'finish'],
        'answered-elsewhere': ['answered-elsewhere', 'finish'],
    }[case]
    require([command.get('operation') for command in fixture_commands] == expected_commands, 'unexpected fixture operation')
    if case == 'answered-elsewhere':
        answered_elsewhere_contract(rows, engine, requests, fixture_commands, bindings[0], snapshots, hooks)
    for command in [value for value in fixture_commands if value['operation'] == 'backend-connected']:
        call = by_sdk.get(command.get('conversationID'))
        require(call, 'backend report targets unknown conversation')
        join = next((action for action in actions if action['kind'] == NATIVE['join'] and action['call'] == call['callUUID']), None)
        report = one([row for row in rows if row.get('id') == command['id']], 'system.backendConnected')
        checkpoint = one([row for row in rows if row.get('id') == command['id']], 'system.commandReceived')
        require(join and ready['wallTimeMS'] + join['settled']['t_ms'] - marker['t_ms'] + 1 <= checkpoint['wallTimeMS'] and
                any(row['sequence'] < checkpoint['sequence'] and any(value['id'] == call['conversationID'] and value['status'] == 'connecting' and 'pending' not in value for value in row['conversations']) for row in snapshots) and
                not any(row['sequence'] < checkpoint['sequence'] and any(value['id'] == call['conversationID'] and value['status'] in ('connected', 'held') for value in row['conversations']) for row in snapshots) and
                any(row['sequence'] > checkpoint['sequence'] and row.get('conversationID') == call['conversationID'] and row.get('status') == 'connected' and row.get('hasConnectedAt') is True for row in hooks),
                'connected state was fabricated or backend report preceded join settlement')
        if case in ('hold-accept', 'end-accept') and call['role'] == 'waiting':
            first_id = bindings[0]['conversationID']
            def composed(snapshot):
                calls = snapshot['conversations']
                previous = any(value['id'] == first_id and value['status'] == 'held' for value in calls) if case == 'hold-accept' else all(value['id'] != first_id for value in calls)
                return previous and any(value['id'] == call['conversationID'] and value['status'] == 'connecting' for value in calls)
            require(any(row['sequence'] < checkpoint['sequence'] and composed(row) for row in snapshots), 'D5 projection did not compose')
            if case == 'hold-accept':
                require(any(row.get('conversationID') == first_id and row.get('status') == 'held' and row.get('count') == 2 for row in hooks), 'held first-call hook missing')
    resets = [row for row in engine if row['event'] == 'provider.reset']
    if case == 'provider-reset':
        reset = one(engine, 'provider.reset')
        request = next(request for request in requests if request['operation'] == 'reset')
        response = next(control['response'] for control in controls if control['request']['id'] == request['id'])
        require(response.get('result') == {'reset': True, 'provider': reset.get('provider')} and
                reset.get('requestID') == request['id'] and reset.get('callUUIDs') == [bindings[0]['callUUID']] and
                reset.get('cancelledActionIDs') == [] and
                len([row for row in rows if row['event'] == 'system.event' and row.get('name') == 'providerReset']) == 1,
                'selected-provider reset did not reach the SDK')
    else: require(not resets, 'unexpected provider reset')
    if case == 'push-launch':
        require(launch_receipt and launch_receipt.get('appServiceAbsent') is True and launch_receipt.get('runtimeInjectionRequested') is False and
                launch_receipt.get('mode') == 0o600 and all(launch_receipt.get(key) == launch.get(key) for key in ('runID', 'bundleID', 'simulatorID')), 'cold launch was not external/stopped/bound')
        services = launch_receipt.get('serviceQuery')
        table = [line.split() for line in services.splitlines() if line.split()] if isinstance(services, str) else []
        require(len(table) >= 2 and table[0] == ['PID', 'Status', 'Label'] and
                all(len(row) == 3 and re.fullmatch(r'-|[1-9][0-9]*', row[0]) and re.fullmatch(r'-|-?[0-9]+', row[1]) for row in table[1:]) and
                hashlib.sha256(services.encode()).hexdigest() == launch_receipt.get('serviceQuerySHA256') and
                not any(fields[0].isdigit() and int(fields[0]) > 0 and fields[-1].startswith('UIKitApplication:' + BUNDLE + '[')
                        for line in services.splitlines() if (fields := line.split())), 'cold launch app was still running')
        envelope = launch_receipt.get('envelope', {})
        require(envelope.get('id') == launch_receipt.get('pushID') == bindings[0]['pushID'] and envelope.get('runID') == launch['runID'] and
                envelope.get('bundleID') == BUNDLE and envelope.get('mustReport') is True and
                envelope.get('expiresAtMS', 0) - envelope.get('createdAtMS', 0) == 30000, 'cold envelope identity/lifetime differs')
        require(launch_receipt.get('envelopeSHA256') == hashlib.sha256((json.dumps(envelope, sort_keys=True) + '\n').encode()).hexdigest(),
                'cold launch envelope hash differs')
        consumed = one(engine, 'push.launchConsumed')
        require(consumed.get('pushID') == envelope['id'] and consumed.get('envelopeSHA256') == launch_receipt.get('envelopeSHA256') and
                consumed.get('createdAtMS') == envelope['createdAtMS'] and consumed.get('expiresAtMS') == envelope['expiresAtMS'], 'runtime consumed different launch bytes')
        push = [row for row in engine if row.get('pushID') == envelope['id']]
        received, report, returned, completed, reported = (one(push, event) for event in ('push.received', 'report.incoming', 'push.callbackReturned', 'push.completed', 'report.completed'))
        require(0 <= report['t_ms'] - received['t_ms'] < 500, 'cold PushKit report start exceeded 500 ms')
        require(consumed['sequence'] < received['sequence'] < report['sequence'] < returned['sequence'] and
                received.get('mustReport') is True and all(row.get('mustReport') is True and row.get('reportEntered') is True for row in (returned, completed)) and
                report['sequence'] < reported['sequence'] < completed['sequence'] and reported.get('callUUID') == report.get('callUUID') and
                type(reported.get('error')) is int and reported.get('error') == 0, 'cold PushKit report/callback/completion missing')
        attached = one(rows, 'system.handlerAttached')
        require(any(row['sequence'] < attached['sequence'] and any(value.get('pending', {}).get('kind') == 'join' and value['pending'].get('origin') == 'system' for value in row['conversations']) for row in snapshots), 'cold system answer did not pend without handler')
    else: require(not any(row['event'] == 'push.launchConsumed' for row in engine), 'unexpected staged push launch')
    return dict(case=case, nativeActions=len(actions), handlers=len(handlers), conversations=len(bindings), passed=True)


def answered_elsewhere_contract(rows, engine, requests, commands, binding, snapshots, hooks):
    """Bind the public host signal to native dismissal, without any End action."""
    command = next(value for value in commands if value['operation'] == 'answered-elsewhere')
    request = next(value for value in requests if value['operation'] == 'push')
    server_id = request.get('payload', {}).get('incomingCall', {}).get('serverCallId')
    context = dict(id=command['id'], eventId=command['id'], serverCallId=server_id,
                   conversationID=binding['conversationID'])
    require(isinstance(server_id, str) and server_id and command.get('serverCallId') == server_id and
            command.get('conversationID') == binding['conversationID'], 'answered-elsewhere command targets another call')
    requested = one(rows, 'system.answeredElsewhereRequested')
    accepted = one(rows, 'system.answeredElsewhereAccepted')
    signal = one(engine, 'system.answeredElsewhereSignal')
    delivered = one([row for row in rows if row.get('id') == command['id']], 'system.commandReceived')
    completed = one([row for row in rows if row.get('id') == command['id']], 'system.commandCompleted')
    require(all(row.get(key) == value for row in (requested, accepted, signal) for key, value in context.items()) and
            signal.get('traceSequence') == requested['sequence'] and accepted.get('accepted') is True and
            delivered['sequence'] < requested['sequence'] < accepted['sequence'] < completed['sequence'],
            'answered-elsewhere signal identity/order differs')
    require(type(requested.get('clockBeforeMS')) is int and
            0 <= requested['wallTimeMS'] - requested['clockBeforeMS'] <= 25,
            'unbounded answered-elsewhere signal clock')
    require(type(signal.get('t_ms')) is int, 'invalid answered-elsewhere native signal clock')
    require(not any(row['event'] in ('transaction.delivered', 'action.settled', 'system.handlerEntered') for row in engine) and
            not any(row['event'] == 'system.handler' for row in rows), 'answered-elsewhere submitted a native action or handler')
    require(not any(call['status'] in ('connecting', 'connected', 'held') for row in snapshots for call in row['conversations']),
            'answered-elsewhere call connected')
    native = one(engine, 'report.ended')
    incoming = one([row for row in engine if row.get('pushID') == binding['pushID']], 'report.incoming')
    changes = [row for row in engine if row['event'] == 'call.changed']
    ended = one([row for row in changes if row.get('ended') is True], 'call.changed')
    require(type(native.get('reason')) is int and native['reason'] == 4 and
            native.get('callUUID') == binding['callUUID'] and native.get('pushID') == binding['pushID'] and
            native.get('provider') == incoming.get('provider') and
            all(row.get('uuid') == binding['callUUID'] for row in changes) and ended.get('ringing') is False and
            any(row['sequence'] < signal['sequence'] and row.get('ended') is False and row.get('ringing') is True for row in changes) and
            signal['sequence'] < native['sequence'] < ended['sequence'], 'answered-elsewhere native dismissal differs')
    require(all(type(row.get('t_ms')) is int and 0 <= row['t_ms'] - signal['t_ms'] <= ANSWERED_ELSEWHERE_BUDGET_MS
                for row in (native, ended)), 'answered-elsewhere native dismissal exceeded 1000 ms')
    terminal = next((row for row in snapshots if row['sequence'] > requested['sequence'] and
                     any(call['id'] == binding['conversationID'] and call['status'] == 'ended' and
                         call.get('endedReason') == 'answeredElsewhere' for call in row['conversations'])), None)
    empty = next((row for row in snapshots if terminal and row['sequence'] > terminal['sequence'] and row['conversations'] == []), None)
    event = one([row for row in rows if row['event'] == 'system.event' and row.get('name') == 'answeredElsewhere'], 'system.event')
    require(terminal and empty and all(event.get(key) == value for key, value in context.items() if key != 'id') and
            requested['sequence'] < terminal['sequence'] <= event['sequence'] and
            terminal['wallTimeMS'] >= requested['clockBeforeMS'] + native['t_ms'] - signal['t_ms'] - 1 and
            hooks[-1]['sequence'] > empty['sequence'],
            'answered-elsewhere terminal projection/event differs')
    require(all(requested['wallTimeMS'] <= row['wallTimeMS'] and
                row['wallTimeMS'] - requested['clockBeforeMS'] <= ANSWERED_ELSEWHERE_BUDGET_MS
                for row in (terminal, empty, event, hooks[-1])), 'answered-elsewhere projection/event/hook exceeded 1000 ms')


def record_manifest(root, parent):
    manifest = json.loads((parent / 'manifest.json').read_text())
    result = bounded(['xcrun', 'simctl', 'list', 'devices', '-j'], 30)
    require(result.returncode == 0 and not result.stderr, 'cannot independently verify owned simulator deletion')
    with (root / 'cleanup-inventory.json').open('xb') as stream: stream.write(result.stdout)
    devices = json.loads(result.stdout)['devices']
    absent = all(device.get('udid') != manifest['simulatorID'] for entries in devices.values() for device in entries)
    device_directory = Path.home() / 'Library/Developer/CoreSimulator/Devices' / manifest['simulatorID']
    directory_absent = not device_directory.exists() and not device_directory.is_symlink()
    require(absent and directory_absent, 'owned simulator remains after deletion')
    with (root / 'cleanup-confirmation.json').open('x') as stream:
        json.dump(dict(simulatorID=manifest['simulatorID'], inventoryAbsent=absent, deviceDirectoryAbsent=directory_absent,
                       inventorySHA256=hashlib.sha256(result.stdout).hexdigest()), stream, indent=2)
    value = dict(schemaVersion=1, scenario='sdk-system', **m0.source_identity(),
        parentManifestSHA256=m0.digest(parent / 'manifest.json'), runID=manifest['runID'], simulatorID=manifest['simulatorID'],
        files={str(path.relative_to(root)): m0.digest(path) for path in sorted(root.rglob('*')) if path.is_file()})
    with (root / 'manifest.json').open('x') as stream: json.dump(value, stream, indent=2); stream.write('\n')


def manifest_check(root, parent, identity):
    manifest = json.loads((root / 'manifest.json').read_text())
    parent_manifest = json.loads((parent / 'manifest.json').read_text())
    require(manifest.get('schemaVersion') == 1 and manifest.get('scenario') == 'sdk-system' and
            all(manifest.get(key) == value for key, value in identity.items()) and
            manifest.get('parentManifestSHA256') == m0.digest(parent / 'manifest.json') and
            all(manifest.get(key) == parent_manifest.get(key) for key in ('runID', 'simulatorID')), 'unbound system manifest')
    files = {str(path.relative_to(root)): m0.digest(path) for path in root.rglob('*') if path.is_file() and path.name not in ('manifest.json', 'summary.json')}
    require(manifest.get('files') == files and files, 'missing/extra/changed system evidence')
    cleanup = json.loads((root / 'cleanup-confirmation.json').read_text())
    require(cleanup.get('simulatorID') == manifest['simulatorID'] and cleanup.get('inventoryAbsent') is True and
            cleanup.get('deviceDirectoryAbsent') is True and cleanup.get('inventorySHA256') == m0.digest(root / 'cleanup-inventory.json'), 'independent cleanup confirmation missing')
    devices = json.loads((root / 'cleanup-inventory.json').read_text())['devices']
    require(all(device.get('udid') != manifest['simulatorID'] for entries in devices.values() for device in entries), 'owned simulator remains in cleanup inventory')
    return manifest


def validate(parent, source_root=ROOT):
    m0.validate(parent, source_root)
    root = parent / 'system'
    identity = m0.source_identity(source_root)
    manifest = manifest_check(root, parent, identity)
    package_check(root / 'control-package', identity, source_root)
    expected = d5_compositions([json.loads(line) for line in (source_root / D5).read_text().splitlines()])
    deadlines, reference_files = deadline_oracles(source_root)
    profile = json.loads((source_root / 'Sources/Engine/Resources/ios-27.0.json').read_text())
    reference_files.update(cold_push_reference(source_root))
    results = []
    for case in CASES:
        directory, name = root / case, 'sdk-system-' + case
        rows, receipt = m0.bound_rows(directory, name, manifest, BUNDLE)
        engine = read_journal(directory, name, manifest, receipt, (source_root / 'VERSION').read_text().strip())
        index = json.loads((directory / 'index.json').read_text())
        supervisor_check(receipt, index, (directory / 'failed-cleanup.json').exists())
        require(index.get('controls') == [f'control-{i:02}.json' for i in range(len(index.get('controls', [])))] and
                index.get('fixtureCommands') == [f'fixture-{i:02}.json' for i in range(len(index.get('fixtureCommands', [])))], 'unexpected case receipt paths')
        require(set(index['controls']) == {path.name for path in directory.glob('control-*.json')} and
                set(index['fixtureCommands']) == {path.name for path in directory.glob('fixture-*.json')}, 'unreferenced command receipts')
        controls = [json.loads((directory / name).read_text()) for name in index['controls']]
        commands = [json.loads((directory / name).read_text()) for name in index['fixtureCommands']]
        for row in engine:
            if row['event'] == 'action.deadline':
                kind = next((kind for tx in engine if tx['event'] == 'transaction.delivered' for kind, identity in zip(tx['kinds'], tx['actionIDs']) if identity == row['actionID']), None)
                translated = {value: key.title() + 'ConversationAction' for key, value in NATIVE.items()}
                translated[NATIVE['hold']] = 'PauseConversationAction'
                translated[NATIVE['tones']] = 'PlayToneAction'
                check_deadline(dict(kind=translated.get(kind), timeoutIn=row.get('deadlineSeconds')), deadlines)
        results.append(validate_case(rows, engine, index, controls, commands, case, expected, profile,
                       json.loads((directory / 'launch-push.json').read_text()) if case == 'push-launch' else None))
    return dict(success=True, measurement='measured source-bound simulator system journeys', **identity,
                runID=manifest['runID'], simulatorID=manifest['simulatorID'], simulatorOS=json.loads((parent / 'environment.json').read_text())['simulatorOS'],
                manifestSHA256=m0.digest(root / 'manifest.json'), deviceReferences={D5:m0.digest(source_root / D5), **reference_files}, cases=results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('parent', type=Path)
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    try:
        if args.record: record_manifest(args.parent / 'system', args.parent)
        else: print(json.dumps(validate(args.parent), indent=2))
    except (OSError, ValueError, KeyError, EvidenceError) as error: parser.exit(1, str(error) + '\n')
