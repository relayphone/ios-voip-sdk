#!/usr/bin/env python3
"""Compare fresh engine executions with the measured provider-routing inputs."""
import collections
import hashlib
import json
from pathlib import Path
import sys
from summarize import EvidenceError, load, one, require

ROOT = Path(__file__).resolve().parent.parent
CASES = ('single', 'ab', 'ba', 'handles', 'late', 'drop', 'inv', 'recreate')


def bound_capture(directory, name):
    rows = load(directory, name)
    receipt = json.loads((directory / f'{name}.receipt.json').read_text())
    launch = one(rows, 'launch')
    require(receipt.get('schemaVersion') == 2 and receipt.get('success') is True and
            receipt.get('completed') is True and receipt.get('terminateExitCode') == 0 and
            receipt.get('lastProbeEvent') == 'done', 'incomplete scenario receipt')
    for key in ('runID', 'simulatorID', 'bundleID'):
        require(receipt.get(key) == launch.get(key), f'{key} mismatch')
    require(receipt.get('appPID') == receipt.get('launcherAppPID') == launch.get('pid'), 'launcher PID mismatch')
    require(receipt.get('traceSHA256') == hashlib.sha256((directory / f'{name}.log').read_bytes()).hexdigest(), 'trace hash mismatch')
    engine = [json.loads(line) for line in (directory / f'{name}.engine.jsonl').read_text().splitlines()]
    require(receipt.get('engineSHA256') == hashlib.sha256((directory / f'{name}.engine.jsonl').read_bytes()).hexdigest(), 'engine hash mismatch')
    require(engine and [r['sequence'] for r in engine] == list(range(1, len(engine) + 1)), 'journal sequence mismatch')
    for row in engine:
        require(all(row.get(key) == launch.get(key) for key in ('runID', 'pid', 'bundleID')), 'journal identity mismatch')
        require(row.get('profile') == 'ios-27.0', 'journal profile mismatch')
    require(rows[-1]['event'] == 'done', 'missing terminal done')
    require(all(a['t_ms'] <= b['t_ms'] for a, b in zip(rows, rows[1:])), 'non-monotonic trace')
    return rows, engine


def roles(rows):
    mapping = {}
    for row in rows:
        if row['event'] == 'request' and row['kind'] == 'CXStartCallAction':
            mapping[row['call']] = row['label'].removesuffix('-start')
        if row['event'] == 'report.incoming' and row['result'] == 'ok':
            mapping[row['call']] = row['label']
    return mapping


def providers(directory, case):
    rows, engine = bound_capture(directory, 'providers-' + case)
    reference = load(ROOT / 'docs/research/callkit-simulator-probe/provider-routing', '2026-10-21-iphone13-ios27-providers-' + case)
    actual_roles, expected_roles = roles(rows), roles(reference)
    def routed(source, mapping):
        return collections.Counter((r['label'], r['kind'], mapping.get(r['call'], r['call']), r['result'], tuple(r['receivers']))
                                   for r in source if r['event'] == 'route')
    require(routed(rows, actual_roles) == routed(reference, expected_roles), f'{case}: routing differs from device')
    actual = [r for r in rows if r['event'] == 'tap.perform']
    expected = [r for r in reference if r['event'] == 'tap.perform']
    require(len(actual) == len(expected), f'{case}: action count differs: {len(actual)} != {len(expected)}')
    def signature(r, mapping):
        return (r['p'], r['kind'], mapping.get(r['call'], r['call']))
    # inv cleanup contains two otherwise identical end requests; compare that
    # unordered cleanup by semantic call role. All other boundaries are ordered.
    if case == 'inv':
        require(collections.Counter(signature(r, actual_roles) for r in actual) ==
                collections.Counter(signature(r, expected_roles) for r in expected), 'invalidated provider cleanup differs')
    else:
        for a, b in zip(actual, expected):
            require(signature(a, actual_roles) == signature(b, expected_roles), f'{case}: action order/routing differs')
            if 'muted' in b: require(a.get('muted') == b['muted'], 'mute value differs')
    executions = [r for r in rows if r['event'] == 'tap.execute']
    require(len(executions) == len(actual), 'execution inventory differs')
    require(len({r['action'] for r in actual}) == len(actual), 'duplicate action delivery')
    require(len({r['tx'] for r in executions}) == len(executions), 'duplicate delivered transaction')
    requested = {r['action']: r for r in rows if r['event'] == 'request'}
    accepted = {r['transactionID'][:8]: r for r in engine if r['event'] == 'request.accepted'}
    delivered = {r['transactionID'][:8]: r for r in engine if r['event'] == 'transaction.delivered'}
    journal_actions = {identity[:8]: r for r in delivered.values() for identity in r['actionIDs']}
    for request in requested.values():
        submitted = accepted.get(request['tx'])
        require(submitted is not None and [i[:8] for i in submitted['actionIDs']] == [request['action']], 'request/journal identity mismatch')
        route = next(r for r in rows[rows.index(request):] if r['event'] == 'route' and r['label'] == request['label'])
        if route['result'] == 'ok' and route['receivers']:
            require(sum(r['action'] == request['action'] for r in actual) == 1, 'requested action UUID not preserved')
    for transaction in delivered.values():
        if transaction['origin'] == 'application':
            submitted = accepted.get(transaction['requestID'][:8])
            require(submitted is not None and submitted['error'] == 0 and transaction['actionIDs'] == submitted['actionIDs'], 'unvalidated delivery or changed action UUID')
    for a, execution in zip(actual, executions):
        require(execution['actions'] == [a['action']] and execution['p'] == a['p'], 'execution/action mismatch')
        require(rows.index(execution) < rows.index(a), 'execute must precede perform')
        require(a.get('main') is False and a.get('onQueue') == a['p'], 'configured delegate queue mismatch')
        require(a.get('sameProvider') is (not (case == 'drop' and a['p'] == 'B')), 'provider object identity mismatch')
        transaction = delivered.get(execution['tx'])
        require(transaction is not None and [i[:8] for i in transaction['actionIDs']] == execution['actions'], 'execute/journal identity mismatch')
        if a['action'] in requested:
            require(requested[a['action']]['tx'] != execution['tx'], 'request transaction UUID reused')
        else:
            origin = journal_actions.get(a['action'], {}).get('origin')
            require(origin in ('muteEcho', 'postEndUnmute') and a['kind'] == 'CXSetMutedCallAction', 'unclassified system action')
        deadline = a.get('timeoutIn', -1)
        low, high = (598, 600.1) if a['kind'] == 'CXStartCallAction' else ((58, 60.1) if a['kind'] == 'CXAnswerCallAction' else (3, 5.1))
        require(low <= deadline <= high, 'action deadline differs from profile')
    expected_timeouts = collections.Counter(r['kind'] for r in reference if r['event'] == 'tap.timedOut')
    require(collections.Counter(r['kind'] for r in rows if r['event'] == 'tap.timedOut') == expected_timeouts, 'unexpected timeout inventory')
    audio_events = ('tap.didActivate', 'tap.didDeactivate')
    require([(r['event'], r['p']) for r in rows if r['event'] in audio_events] ==
            [(r['event'], r['p']) for r in reference if r['event'] in audio_events], 'audio ownership/order differs')
    for row in rows:
        if row['event'] in audio_events:
            require(row.get('main') is False and row.get('sameProvider') is (case != 'drop'), 'audio provider/queue mismatch')
        if row['event'] == 'tap.timedOut':
            performed = next((a for a in actual if a['action'] == row['action']), None)
            require(performed is not None and performed['p'] == row['p'] and performed['kind'] == row['kind'], 'timeout action/provider mismatch')
            require(journal_actions.get(row['action'], {}).get('origin') == 'postEndUnmute', 'unexpected timeout origin')
            fulfillment = one(rows, 'tap.fulfilled', action=row['action'])
            require(rows.index(performed) < rows.index(fulfillment) < rows.index(row), 'post-end timeout fulfillment order')
            require(5000 <= row['t_ms'] - performed['t_ms'] <= 5900, 'post-end timeout budget')
    require(one(rows, 'observer.snapshot', label='final')['calls'] == [], 'final calls remain')
    for r in rows:
        if r['event'] == 'tap.fulfilled': require(r.get('complete') is False, 'action completion property drift')
    if case == 'inv':
        requests = [r for r in rows if r['event'] == 'request']
        for request in requests:
            route = next(r for r in rows[rows.index(request):] if r['event'] == 'route' and r['label'] == request['label'])
            if route['result'].endswith(':2'):
                require(10_000 <= route['t_ms'] - request['t_ms'] <= 12_000, 'unknown provider timing differs')
        revived = [r for r in rows if r['event'] == 'tap.didBegin' and r['p'] == 'B']
        require(len(revived) == 2, 'report did not revive invalidated newest provider')
    if case == 'late':
        require(not any(r['event'] == 'tap.didBegin' and r['p'] == 'B' for r in rows), 'late delegate replayed begin')
    return dict(success=True, actions=len(actual), referenceAssertions='routing, queues, identities, audio, deadlines', lifecycle='teardown callbacks uncharacterized')


def main():
    directory = Path(sys.argv[1])
    result = {}
    for case in CASES:
        try: result[case] = providers(directory, case)
        except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
            result[case] = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    return 0 if all(r['success'] for r in result.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
