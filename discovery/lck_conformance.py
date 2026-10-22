#!/usr/bin/env python3
"""Compare bounded LCK journeys with the committed iPhone evidence."""
from pathlib import Path
import argparse
import collections
import json
from conformance import bound_capture
from device_oracles import check_deadline, deadline_bands
from summarize import build_identity, EvidenceError, load, one, require, run_environment

ROOT = Path(__file__).resolve().parent.parent
CASES = ('basic', 'cx-after', 'lck-after', 'two-managers')
PROVIDER_APIS = {'basic': ['livecommunicationkit'], 'cx-after': ['livecommunicationkit', 'callkit'],
                 'lck-after': ['callkit', 'livecommunicationkit'], 'two-managers': ['livecommunicationkit', 'livecommunicationkit']}


def provider_apis(engine, case):
    created = [row['provider'] for row in engine if row['event'] == 'provider.created']
    require(len(created) == len(set(created)) == len(PROVIDER_APIS[case]), 'LCK provider inventory differs')
    observed = {}
    for row in engine:
        if row['event'] != 'provider.apiKind': continue
        require(row['provider'] in created and type(row['delegatePresent']) is bool, 'unbound provider API classification')
        require(row['apiKind'] in ('callkit', 'livecommunicationkit'), 'unknown provider API classification')
        if not row['delegatePresent']: continue
        require(row['provider'] not in observed or observed[row['provider']] == row['apiKind'], 'provider API classification changed')
        observed[row['provider']] = row['apiKind']
    require([observed.get(identity) for identity in created] == PROVIDER_APIS[case], 'provider framework API classification differs')
    return [observed[identity] for identity in created]


def roles(rows):
    """Bind UUIDs to requested outgoing journeys and successful incoming reports."""
    mapping = {}
    def bind(identity, role):
        require(identity not in mapping or mapping[identity] == role, 'conflicting conversation role')
        require(role not in mapping.values() or mapping.get(identity) == role, 'ambiguous conversation role')
        mapping[identity] = role
    for row in rows:
        if row['event'] == 'lck.reported' and row['result'] == 'ok':
            bind(row['conversation'], row['label'])
        if row['event'] == 'lck.request' and row['kind'] == 'StartConversationAction':
            role = row['label'].removesuffix('-start')
            delivered = [action for action in rows if action['event'] == 'lck.perform' and action['action'] == row['action']]
            require(len(delivered) <= 1, 'duplicate start action')
            if delivered:
                bind(delivered[0]['conversation'], role)
            else:
                # The measured CX tap has no action/call UUID fields. Its unique
                # outgoing snapshot is the available conversation identity bound.
                snapshot = one(rows, 'lck.snapshot', label=role + '-outgoing')
                require(len(snapshot['conversations']) == len(snapshot['observer']) == 1 and
                        snapshot['conversations'][0]['uuid'] == snapshot['observer'][0]['uuid'] and
                        snapshot['observer'][0]['outgoing'] is True, 'ambiguous CX-owned outgoing conversation')
                bind(snapshot['conversations'][0]['uuid'], role)
    return mapping


def action_stream(rows, mapping):
    requests = [row for row in rows if row['event'] == 'lck.request']
    by_id = {row['action']: row for row in requests}
    require(requests and len(by_id) == len(requests) and
            len({row['label'] for row in requests}) == len(requests), 'missing or duplicate LCK request identity')
    performed = [row for row in rows if row['event'] == 'lck.perform']
    require(len({row['action'] for row in performed}) == len(performed), 'duplicate LCK action delivery')
    result = []
    for row in rows:
        if row['event'] == 'lck.cx.perform':
            # The measured CX logger exposes only receiver and kind.
            result.append((row['event'], row['p'], row['kind']))
        if row['event'] != 'lck.perform': continue
        require(row['conversation'] in mapping, 'unbound LCK conversation')
        role = mapping[row['conversation']]
        requested = by_id.get(row['action'])
        if requested:
            tag = requested['label'].rsplit('-', 1)[0]
            require(role in (tag, tag + '-incoming') and requested['kind'] == row['kind'],
                    'LCK request/delivery target or kind differs')
            origin = requested['label']
        else:
            origin = 'system'
        result.append((row['event'], row['p'], row['kind'], role, origin, row['state'],
                       tuple((key, row[key]) for key in ('muted', 'paused') if key in row)))
    return result


def projection(rows, mapping):
    def role(identity):
        require(identity in mapping, 'unbound projected conversation')
        return mapping[identity]
    def observer(call):
        flags = ('outgoing', 'connected', 'held', 'ended')
        require(all(type(call[key]) is bool for key in flags), 'invalid observer flags')
        return (role(call['uuid']), *(call[key] for key in flags))
    states = collections.defaultdict(list)
    snapshots, observed, audio = [], [], []
    latest_request = None
    for row in rows:
        if row['event'] == 'lck.request': latest_request = row['label']
        if row['event'] == 'lck.conversationChanged': states[row['p']].append((role(row['uuid']), row['state']))
        if row['event'] == 'observer.callChanged': observed.append(observer(row))
        if row['event'] in ('lck.didActivate', 'lck.didDeactivate'):
            audio.append((row['event'], row['p'], latest_request))
        if row['event'] == 'lck.snapshot':
            require(type(row['pending']) is int, 'invalid pending action count')
            conversations = sorted((role(call['uuid']), call['state']) for call in row['conversations'])
            snapshots.append((row['label'], row['pending'], conversations, sorted(observer(call) for call in row['observer'])))
    return dict(managerStates=dict(states), observerStates=observed, snapshots=snapshots, audio=audio)


def compare(rows, reference, deadlines):
    require(one(rows, 'lck.start')['scenario'] == one(reference, 'lck.start')['scenario'], 'LCK scenario differs')
    snapshots = [row for row in reference if row['event'] == 'lck.snapshot']
    require(snapshots, 'missing device snapshots')
    final_label = snapshots[-1]['label']
    actual_final = one(rows, 'lck.snapshot', label=final_label)
    expected_final = one(reference, 'lck.snapshot', label=final_label)
    # The measured source invalidates its managers/providers immediately after
    # this final journey snapshot. R3 teardown callbacks are outside this scope.
    actual = rows[:rows.index(actual_final) + 1]
    expected = reference[:reference.index(expected_final) + 1]
    lifecycle = ('lck.didBegin', 'lck.didReset', 'lck.cx.didBegin', 'lck.cx.didReset', 'done')
    require(all(row['event'] in lifecycle for row in rows[len(actual):]),
            'non-lifecycle event after final LCK journey snapshot')
    actual_roles, expected_roles = roles(actual), roles(expected)
    require(action_stream(actual, actual_roles) == action_stream(expected, expected_roles),
            'ordered LCK/provider action receivers or values differ')
    def creations(source):
        return [(row['event'], row.get('p')) for row in source
                if row['event'] in ('lck.managerCreated', 'lck.cxProviderCreated')]
    require(creations(actual) == creations(expected), 'manager/provider creation order differs')
    for event, keys in (('lck.request', ('label', 'kind')),
                        ('lck.requestCompleted', ('label', 'result')),
                        ('lck.reported', ('label', 'result', 'attempt')),
                        ('lck.reported.connected', ('p',)), ('lck.reportedEnded', ('label',))):
        require([tuple(row[key] for key in keys) for row in actual if row['event'] == event] ==
                [tuple(row[key] for key in keys) for row in expected if row['event'] == event],
                f'{event}: ordered outcomes differ')
    callbacks = ('lck.perform', 'lck.cx.perform', 'lck.conversationChanged', 'lck.timedOut',
                 'lck.didActivate', 'lck.didDeactivate', 'observer.callChanged')
    for row in actual:
        if row['event'] in callbacks: require(row.get('main') is True, 'LCK/observer callback not main')
        if row['event'] == 'lck.perform': check_deadline(row, deadlines)
    require([(row['p'], row['kind']) for row in actual if row['event'] == 'lck.timedOut'] ==
            [(row['p'], row['kind']) for row in expected if row['event'] == 'lck.timedOut'], 'LCK timeout inventory differs')
    actual_projection, expected_projection = projection(actual, actual_roles), projection(expected, expected_roles)
    for key in expected_projection:
        require(actual_projection[key] == expected_projection[key], f'LCK {key} differs from device')
    require(actual_final['conversations'] == actual_final['observer'] == [] and actual_final['pending'] == 0,
            'final LCK state not empty')
    incoming_order = {}
    for report in (row for row in expected if row['event'] == 'lck.reported' and row['result'] == 'ok'):
        label = report['label']
        actual_report = one(actual, 'lck.reported', label=label, result='ok')
        callbacks = [row for row in expected if row['event'] == 'lck.conversationChanged' and
                     row['uuid'] == report['conversation'] and row['state'] == 'idle']
        require(callbacks, 'device incoming report has no idle state')
        ordered = [row for row in callbacks if expected.index(row) < expected.index(report)]
        for callback in ordered:
            identity = next(identity for identity, role in actual_roles.items() if role == label)
            changed = one(actual, 'lck.conversationChanged', p=callback['p'], uuid=identity, state='idle')
            require(actual.index(changed) < actual.index(actual_report), 'incoming idle callback did not precede report return')
        incoming_order[label] = 'idle before report return' if ordered else 'device logging order ambiguous; state projection checked'
    return dict(success=True, actions=len(action_stream(actual, actual_roles)), snapshots=len(snapshots),
                scope='journey parity through ' + final_label,
                lifecycle='R3 teardown callbacks deferred; no full raw-trace parity claim',
                incomingOrdering=incoming_order,
                afterJourneyEvents=dict(collections.Counter(row['event'] for row in rows[len(actual):])))


def validate(directory, case):
    require(case in CASES, 'unknown LCK scenario')
    name = 'lck-' + case
    rows, engine = bound_capture(directory, name)
    launch = one(rows, 'launch')
    receipt = json.loads((directory / (name + '.receipt.json')).read_text())
    # Equality alone cannot bind an identity when both sides omit the field.
    # Match the fresh-capture requirements used by the main shipping gate.
    require(launch.get('traceVersion') == 2, 'live LCK run requires traceVersion 2')
    require(type(launch.get('pid')) is int and launch['pid'] > 0, 'missing LCK process identity')
    require(launch.get('bundleID') == 'dev.callkitsim.probe', 'LCK bundle identity differs')
    for field in ('runID', 'simulatorID'):
        require(isinstance(launch.get(field), str) and bool(launch[field]), f'missing LCK {field}')
    require(receipt.get('scenario') == name and receipt.get('launchExitCode') in (0, -15, 143),
            'invalid LCK launcher receipt')
    manifest = build_identity(directory, rows)
    require(launch['mode'] == 'lck', 'capture is not LCK mode')
    one(engine, 'runtime.installed')
    api_kinds = provider_apis(engine, case)
    require(any(row['event'] == 'transaction.delivered' for row in engine), 'missing LCK provider-layer execution')
    require(all(left['t_ms'] <= right['t_ms'] for left, right in zip(engine, engine[1:])), 'LCK journal time mismatch')
    reference_directory = ROOT / 'docs/research/callkit-simulator-probe/livecommunicationkit'
    sources = {name: load(reference_directory, '2026-10-21-iphone13-ios27-lck-' + name) for name in CASES}
    deadlines = deadline_bands([row for source in sources.values() for row in source if row['event'] == 'lck.perform'])
    result = compare(rows, sources[case], deadlines)
    result.update(reference='2026-10-21-iphone13-ios27-lck-' + case,
                  environment=run_environment(directory, manifest), runtimeVersion=manifest['runtimeVersion'],
                  deadlineBands=deadlines, actualOS=one(rows, 'lck.start')['os'], referenceOS=one(sources[case], 'lck.start')['os'],
                  journalBinding='process/build bound; LCK-to-CX action UUID mapping unmeasured',
                  cxTapLimit='measured CX callbacks expose only receiver/kind; tone/pause handlers absent')
    result['providerAPIs'] = api_kinds
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--case', choices=CASES)
    args = parser.parse_args()
    results = {}
    for case in (args.case,) if args.case else CASES:
        try: results[case] = validate(args.directory, case)
        except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
            results[case] = dict(success=False, error=str(error))
    print(json.dumps(results, indent=2))
    return 0 if all(result['success'] for result in results.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
