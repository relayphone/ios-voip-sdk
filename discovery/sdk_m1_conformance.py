#!/usr/bin/env python3
"""Qualify M1 journeys nested beneath a fully source/product-bound M0 capture."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
import uuid

import sdk_m0_conformance as m0
from device_oracles import check_deadline, deadline_bands
from summarize import EvidenceError, one, push_report_boundaries, require

ROOT = Path(__file__).resolve().parent.parent
CASES = ('journey', 'cold-launch', 'unhandled-expiry')
ASSERTIONS = {
    'journey': ('push-ringing', 'ring-survives', 'dedup-event', 'dedup-server',
                'dedup-single-conversation', 'joined', 'connected-report', 'held',
                'resumed', 'ended-empty', 'token-hook-observed'),
    'cold-launch': ('cold-snapshot-pending', 'cold-hook-pending', 'cold-redelivered',
                    'connected-report', 'ended-empty', 'token-hook-observed'),
    'unhandled-expiry': ('cold-snapshot-pending', 'cold-hook-pending', 'platform-deadline-visible',
                         'unhandled-expired-empty', 'token-hook-observed'),
}


def deadline_oracles(source_root=ROOT):
    directory = source_root / 'docs/research/callkit-simulator-probe/livecommunicationkit'
    paths = [directory / ('2026-10-21-iphone13-ios27-lck-' + case + '.jsonl')
             for case in ('basic', 'cx-after', 'lck-after', 'two-managers')]
    reference = [json.loads(line) for path in paths for line in path.read_text().splitlines()]
    return deadline_bands(reference), {path.name: m0.digest(path) for path in paths}


def timestamp_ms(value):
    require(isinstance(value, str) and bool(value), 'missing ISO action deadline')
    date = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(date.tzinfo is not None, 'action deadline has no timezone')
    return date.timestamp() * 1000


def join_expiry_seconds(source_root):
    profile = json.loads((source_root / 'Sources/Engine/Resources/ios-27.0.json').read_text())
    return profile['lckMultiCall']['joinExpirySeconds']


def read_journal(directory, name, manifest, receipt, version):
    path = directory / (name + '.runtime.jsonl')
    require(path.stat().st_size > 0 and m0.digest(path) == receipt.get('journalSHA256'),
            name + ': missing or unbound runtime journal')
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    require(rows and all(isinstance(row, dict) and isinstance(row.get('event'), str) for row in rows),
            name + ': invalid runtime journal')
    require(all(type(row.get('sequence')) is int for row in rows) and
            [row.get('sequence') for row in rows] == list(range(1, len(rows) + 1)) and
            all(type(row.get('t_ms')) is int and row['t_ms'] >= 0 for row in rows) and
            all(a['t_ms'] <= b['t_ms'] for a, b in zip(rows, rows[1:])), name + ': journal sequence/time mismatch')
    require(all(row.get('runID') == manifest['runID'] and type(row.get('pid')) is int and row.get('pid') == receipt['appPID'] and
                row.get('bundleID') == 'dev.iosvoipsdk.example' and row.get('profile') == 'ios-27.0' for row in rows),
            name + ': mixed runtime journal identity')
    require(one(rows, 'runtime.installed').get('version') == version, name + ': runtime version differs')
    provider = one(rows, 'provider.created').get('provider')
    require(isinstance(provider, str) and bool(provider) and
            not any(row['event'] == 'diagnostic.multipleProviders' for row in rows), name + ': manager ownership differs')
    require(all(row.get('provider') == provider for row in rows if row['event'] == 'transaction.delivered'),
            name + ': action went to a different provider')
    return rows


def projected(rows, conversation):
    snapshots = [row for row in rows if row['event'] == 'sdk.snapshot']
    require(snapshots and all(type(row.get('revision')) is int and row['revision'] >= 0 for row in snapshots) and
            all(a['revision'] < b['revision'] for a, b in zip(snapshots, snapshots[1:])), 'invalid client snapshot revisions')
    for row in snapshots:
        calls = row.get('conversations')
        require(isinstance(calls, list) and len(calls) <= 1, 'SDK projected a duplicate conversation')
        for call in calls:
            require(call.get('id') == conversation and call.get('direction') == 'incoming' and
                    call.get('status') in ('ringing', 'connecting', 'connected', 'held', 'ending', 'ended') and
                    all(type(call.get(key)) is bool for key in ('isMuted', 'isVideo', 'hasConnectedAt')),
                    'invalid or unbound projected conversation')
    require(snapshots[-1]['conversations'] == [], 'final client state is not empty')
    return snapshots


def case_conformance(rows, engine, case, simulator_os, deadlines, source_root=ROOT):
    launch = one(rows, 'launch')
    require(launch.get('mode') == 'sdk-m1' and launch.get('case') == case and launch.get('traceVersion') == 2,
            case + ': wrong example mode')
    require([row['event'] for row in rows[:2]] == ['app.entry', 'launch'], case + ': startup markers missing')
    require(all(type(row.get('sequence')) is int for row in rows) and
            [row.get('sequence') for row in rows] == list(range(1, len(rows) + 1)) and
            all(type(row.get('wallTimeMS')) is int and row['wallTimeMS'] > 0 for row in rows),
            case + ': invalid process sequence or wall clock')
    require(one(rows, 'sdk.activation').get('active') is True and
            one(rows, 'sdk.managerCreated').get('owner') == 'VoIPApplication.start', case + ': SDK client unavailable')
    def unexpected_error(row):
        expected_rejection = (case == 'unhandled-expiry' and row['event'] == 'm1.coldJoinRequestResult' and
                              row.get('accepted') is False)
        return row.get('error') or (row.get('errorType') and not expected_rejection) or row['event'] in ('sdk.error', 'sdk.timeout')
    require(one(rows, 'sdk.result').get('success') is True and not any(unexpected_error(row) for row in rows),
            case + ': journey failed')
    assertions = [row for row in rows if row['event'] == 'm1.assertion']
    require([row.get('label') for row in assertions] == list(ASSERTIONS[case]) and
            all(row.get('passed') is True for row in assertions), case + ': assertion inventory/outcome differs')
    identities = {row.get('conversationID') for row in assertions if row.get('conversationID') is not None}
    require(len(identities) == 1, case + ': ambiguous assertion conversation')
    conversation = identities.pop()
    require(isinstance(conversation, str) and str(uuid.UUID(conversation)).upper() == conversation.upper(),
            case + ': invalid conversation UUID')
    require(all(row.get('conversationID') in (None, conversation) for row in rows), case + ': mixed conversation identity')
    require(all(row.get('conversationID') == conversation for row in rows if row['event'] in
                ('m1.handler', 'm1.cancelled', 'm1.coldPending', 'm1.coldJoinRequested', 'm1.expiryObserved', 'sdk.state')),
            case + ': missing callback conversation identity')
    snapshots = projected(rows, conversation)
    subscriptions = one(rows, 'm1.subscriptionsStarting')
    require(rows.index(one(rows, 'm1.jsReady')) < rows.index(subscriptions) and
            all(rows.index(subscriptions) < rows.index(row) for row in rows if row['event'].startswith('m1.hook')),
            case + ': hook observation predates the subscription checkpoint')
    injected = one(rows, 'm1.pushInjected')
    require(injected.get('mustReport') is True and injected.get('label') == ('primary' if case == 'journey' else 'cold'),
            case + ': wrong synthetic push policy')
    require(push_report_boundaries(engine, require_settlement_before_return=True) == 1,
            case + ': required callback boundary proof differs')
    received = one(engine, 'push.received')
    completed = one(engine, 'push.completed')
    returned = one(engine, 'push.callbackReturned')
    incoming = one(engine, 'report.incoming')
    reported = one(engine, 'report.completed')
    push_id = injected.get('pushID')
    require(isinstance(push_id, str) and str(uuid.UUID(push_id)).upper() == push_id.upper(), 'invalid synthetic push ID')
    require(all(row.get('pushID') == push_id for row in (received, completed, returned, incoming, reported)),
            case + ': incoming report is not correlated to the injected PushKit delivery')
    modern = tuple(int(part) for part in simulator_os.split('.')[:2]) >= (26, 4)
    require(received.get('api') == completed.get('api') == returned.get('api') == ('metadata' if modern else 'legacy') and
            received.get('mustReport') is True, case + ': wrong PushKit callback or policy')
    require(incoming.get('callUUID') == reported.get('callUUID') == conversation and reported.get('error') == 0,
            case + ': incoming report failed or targeted another conversation')
    require([engine.index(row) for row in (received, incoming, reported, completed)] ==
            sorted(engine.index(row) for row in (received, incoming, reported, completed)),
            case + ': PushKit completion preceded incoming reporting')
    tokens = [row for row in rows if row['event'] == 'm1.hookToken']
    require(tokens and all(type(row.get('available')) is bool and
            row.get('tokenType') == ('apns-voip' if row['available'] else None) for row in tokens),
            case + ': missing or invalid redacted token hook observation')
    require(not any(row['event'] == 'm1.event' and row.get('name') == 'providerReset' for row in rows),
            case + ': provider reset during journey')
    for row in rows:
        require(not any(key in row for key in ('token', 'value', 'payload', 'caller')), case + ': private payload/token in trace')
    hooks = [row for row in rows if row['event'] == 'm1.hookConversations']
    require(hooks and hooks[-1].get('count') == 0 and all(type(row.get('count')) is int and row['count'] in (0, 1) and
            row.get('conversationID') == (conversation if row['count'] == 1 else None) for row in hooks),
            case + ': missing or duplicate hook state')
    handlers = [row for row in rows if row['event'] == 'm1.handler']
    attached = [row for row in rows if row['event'] == 'm1.handlerAttached']
    for row in handlers:
        remaining = timestamp_ms(row.get('deadline')) - row['wallTimeMS']
        kind = {'join': 'JoinConversationAction', 'start': 'StartConversationAction', 'end': 'EndConversationAction',
                'hold': 'PauseConversationAction', 'mute': 'MuteConversationAction', 'tones': 'PlayToneAction'}.get(row.get('kind'))
        # Cold actions may be delivered late. Their effective application deadline
        # remains authoritative; JS must not receive an extension at attachment.
        require(kind in deadlines and 0 < remaining <= deadlines[kind][1] * 1000 and row.get('origin') == 'app',
                case + ': invalid handler deadline/origin')
    transactions = [row for row in engine if row['event'] == 'transaction.delivered']
    for row in transactions:
        require(isinstance(row.get('actionIDs'), list) and len(row['actionIDs']) == len(row.get('kinds', [])) == 1,
                case + ': unexpected compound transaction')
    actions = [(row['actionIDs'][0], row['kinds'][0].split('.')[-1]) for row in transactions]
    require(len({identity for identity, _ in actions}) == len(actions), case + ': duplicate provider action identity')
    settled = [row for row in engine if row['event'] == 'action.settled']
    require(len({row.get('actionID') for row in settled}) == len(settled) and
            all(row.get('actionID') in {identity for identity, _ in actions} for row in settled), case + ': unbound action settlement')
    changes = [row for row in engine if row['event'] == 'call.changed']
    require(changes and all(row.get('uuid') == conversation and row.get('outgoing') is False and
                all(type(row.get(key)) is bool for key in ('connected', 'held', 'ended')) for row in changes) and
            changes[-1].get('ended') is True, case + ': runtime call projection differs')
    if case in ('journey', 'cold-launch'):
        join_handler = one(rows, 'm1.handler', kind='join')
        joined = one(rows, 'm1.assertion', label='joined' if case == 'journey' else 'cold-redelivered')
        backend = one(rows, 'm1.backendConnectedRequested')
        reported_connected = one(rows, 'm1.assertion', label='connected-report')
        require(backend.get('conversationID') == conversation and
                rows.index(joined) < rows.index(backend) < rows.index(reported_connected),
                case + ': backend report must follow signaling acceptance')
        before_joined = [row for row in snapshots if
                         rows.index(join_handler) < rows.index(row) < rows.index(joined) and row['conversations']]
        require(before_joined and before_joined[-1]['conversations'][0].get('status') == 'connecting' and
                before_joined[-1]['conversations'][0].get('pending') is None,
                case + ': signaling acceptance lacks a settled connecting snapshot')
        require(all(call.get('hasConnectedAt') is False and call.get('status') not in ('connected', 'held')
                    for row in snapshots if rows.index(row) < rows.index(backend) for call in row['conversations']),
                case + ': signaling acceptance fabricated transport connection')
        connected = [row for row in snapshots if any(call.get('status') == 'connected' for call in row['conversations'])]
        require(connected and rows.index(backend) < rows.index(connected[0]) < rows.index(reported_connected) and
                connected[0]['conversations'][0].get('pending') is None and
                all(call.get('hasConnectedAt') is True for row in connected for call in row['conversations']),
                case + ': connected projection lacks the explicit backend report')
    if case == 'journey':
        require([row.get('kind') for row in handlers] == ['join', 'hold', 'hold', 'end'] and
                all(type(row.get('held')) is bool for row in handlers if row.get('kind') == 'hold') and
                [row.get('held') for row in handlers if row.get('kind') == 'hold'] == [True, False],
                'journey: handler action order or hold values differ')
        require(len(attached) == 1 and attached[0].get('attached') is True and rows.index(attached[0]) < rows.index(handlers[0]),
                'journey: handler was not attached before delivery')
        require([kind for _, kind in actions] == ['CXAnswerCallAction', 'CXSetHeldCallAction', 'CXSetHeldCallAction', 'CXEndCallAction'] and
                len(settled) == 4 and all(row.get('fulfilled') is True for row in settled), 'journey: provider actions failed/differed')
        ringing = one(rows, 'm1.assertion', label='push-ringing')
        survived = one(rows, 'm1.assertion', label='ring-survives')
        require(survived['t_ms'] - ringing['t_ms'] >= 950, 'journey: ring survival interval missing')
        require(any(call.get('hasConnectedAt') is True for row in snapshots for call in row['conversations']) and
                any(row.get('status') == 'held' for row in hooks), 'journey: connected report or held hook projection missing')
    else:
        pending = one(rows, 'm1.coldPending')
        require(pending.get('handlerAttached') is False and pending.get('conversationID') == conversation and
                type(pending.get('remainingMS')) in (int, float),
                case + ': missing native pending deadline')
        check_deadline(dict(kind='JoinConversationAction', timeoutIn=pending['remainingMS'] / 1000 + 3), deadlines)
        original_deadline = timestamp_ms(pending.get('deadline'))
        require(abs(original_deadline - pending['wallTimeMS'] - pending['remainingMS']) <= 5,
                case + ': pending absolute deadline and remaining interval differ')
        marker = one(engine, 'm1.coldPendingClock')
        require(marker.get('conversationID') == conversation and marker.get('actionID') == pending.get('actionID') and
                type(pending.get('clockBeforeMS')) is int and
                0 <= pending['wallTimeMS'] - pending['clockBeforeMS'] <= 25,
                case + ': unbound or imprecise pending journal clock')
        # The one actual native answer binds the runtime deadline separately
        # from the LCK pending UUID. This allowance is shared with the dedicated
        # native contract; device sampling bands do not prove the safety margin.
        native_answer = one([row for row in transactions if row['kinds'][0].split('.')[-1] == 'CXAnswerCallAction'],
                            'transaction.delivered')
        advertised = one(engine, 'action.deadline', actionID=native_answer['actionIDs'][0])
        native_settlement = one(settled, 'action.settled', actionID=native_answer['actionIDs'][0])
        platform_deadline = advertised.get('deadlineMS')
        require(isinstance(native_answer['actionIDs'][0], str) and native_answer['actionIDs'][0] and
                isinstance(native_answer.get('provider'), str) and native_answer['provider'] and
                advertised.get('provider') == native_answer['provider'] and
                advertised.get('apiKind') == 'livecommunicationkit' and type(platform_deadline) is int and
                advertised.get('deadlineSeconds') == 30 and advertised.get('expirySeconds') == join_expiry_seconds(source_root) and
                2500 <= platform_deadline - original_deadline <= 3500 and
                engine.index(native_answer) < engine.index(advertised) < engine.index(marker) < engine.index(native_settlement),
                case + ': effective deadline lacks the bound native LCK safety margin')
        require(isinstance(pending.get('actionID'), str) and
                any(call.get('pending', {}).get('id') == pending['actionID'] and
                    call['pending'].get('kind') == 'join' and call['pending'].get('deadline') == pending['deadline'] and
                    call['pending'].get('origin') == 'app' for row in snapshots for call in row['conversations']),
                case + ': native pending action is not bound to the client snapshot')
        requested = one(rows, 'm1.coldJoinRequested')
        require(rows.index(injected) < rows.index(requested) < rows.index(pending), case + ': cold action submission order differs')
        require(any(row.get('pending') == 'join' and rows.index(row) < rows.index(one(rows, 'm1.assertion', label='cold-hook-pending'))
                    for row in hooks), case + ': hook missed cold pending action')
        require(rows.index(injected) < rows.index(pending) < rows.index(one(rows, 'm1.jsReady')) < rows.index(subscriptions),
                case + ': native pending action did not exist before JS state hydration')
        if case == 'cold-launch':
            require(len(attached) == 1 and attached[0].get('attached') is True and rows.index(pending) < rows.index(attached[0]) and
                    [row.get('kind') for row in handlers] == ['join', 'end'] and
                    [kind for _, kind in actions] == ['CXAnswerCallAction', 'CXEndCallAction'] and
                    len(settled) == 2 and all(row.get('fulfilled') is True for row in settled),
                    'cold-launch: pending action not redelivered and completed')
            # Both the native fixture and Expo relay preserve milliseconds.
            difference = original_deadline - timestamp_ms(handlers[0].get('deadline'))
            require(abs(difference) <= 1, 'cold-launch: handler attachment changed the original deadline')
        else:
            require(not attached and not handlers, 'unhandled-expiry: a handler was attached')
            require(actions and actions[0][1] == 'CXAnswerCallAction' and
                    all(kind == 'CXEndCallAction' for _, kind in actions[1:]), 'unhandled-expiry: unexpected provider action')
            answer = one(settled, 'action.settled', actionID=actions[0][0])
            require(answer.get('fulfilled') is False and not any(row.get('connected') is True for row in changes),
                    'unhandled-expiry: default fail accepted the join')
            require(engine.index(transactions[0]) < engine.index(marker) < engine.index(answer),
                    'unhandled-expiry: pending clock is not between native join and settlement')
            # Journal and app t_ms have different epochs. The synchronous marker
            # brackets their offset within 25 ms; keep the existing 8 s liveness
            # budget around the actual pending effective deadline.
            relative = answer['t_ms'] - marker['t_ms']
            require(pending['clockBeforeMS'] + relative >= original_deadline - 25 and
                    pending['wallTimeMS'] + relative <= original_deadline + 8_025,
                    'unhandled-expiry: native settlement did not follow the actual pending deadline')
            observed = one(rows, 'm1.expiryObserved')
            elapsed = observed['t_ms'] - pending['t_ms']
            require(pending['remainingMS'] - 100 <= elapsed <= pending['remainingMS'] + 8_000,
                    'unhandled-expiry: expiration did not follow the actual pending deadline')
            require(not any(call.get('status') in ('connected', 'held') for row in snapshots for call in row['conversations']),
                    'unhandled-expiry: SDK connected an unhandled call')
    return dict(success=True, case=case, conversationID=conversation, pushID=push_id,
                assertions=len(assertions), handlerActions=len(handlers), providerActions=len(actions))


def validate(root, source_root=ROOT):
    baseline = m0.validate(root, source_root)
    manifest = json.loads((root / 'manifest.json').read_text())
    directory = root / 'm1'
    names = {'sdk-m1-' + case for case in CASES}
    require({path.stem.removesuffix('.receipt') for path in directory.glob('*.receipt.json')} == names,
            'missing or unexpected M1 scenario receipt')
    require({path.name for path in directory.glob('*.runtime.jsonl')} == {name + '.runtime.jsonl' for name in names},
            'missing or unexpected M1 runtime journal')
    environment = json.loads((root / 'environment.json').read_text())
    version = (source_root / 'VERSION').read_text().strip()
    deadlines, references = deadline_oracles(source_root)
    results = []
    for case in CASES:
        name = 'sdk-m1-' + case
        rows, receipt = m0.bound_rows(directory, name, manifest, 'dev.iosvoipsdk.example')
        require(receipt.get('appEntryObserved') is True, case + ': app entry missing')
        engine = read_journal(directory, name, manifest, receipt, version)
        results.append(case_conformance(rows, engine, case, environment['simulatorOS'], deadlines, source_root))
    return dict(success=True, scenario='sdk-m1', cases=results, m0=baseline,
                manifestSHA256=m0.digest(root / 'manifest.json'), deadlineBands=deadlines,
                deadlineReferenceSHA256=references)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.root)
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.SubprocessError) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
