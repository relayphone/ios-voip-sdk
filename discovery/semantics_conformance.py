#!/usr/bin/env python3
"""Replay the characterized action-failure and controller-answer rules."""
import json
from pathlib import Path
import sys
from conformance import bound_capture, ROOT
from summarize import load, one, require, EvidenceError


def validate(directory, scenario):
    rows, engine = bound_capture(directory, 'semantics-' + scenario)
    reference_name = '2026-10-20-iphone13-ios27-' + ('answer-rules' if scenario == 'answer-rules' else 'failures')
    reference = load(ROOT / 'docs/research/callkit-simulator-probe', reference_name)
    if scenario == 'failures':
        # Earlier waiting attempts were filtered by Focus. They are evidence of
        # filtering, not an oracle for successful call-waiting behavior.
        start = next(i for i, r in enumerate(reference) if r['event'] == 'step' and r['name'] == 'answer-fails')
        reference = reference[start:]
    def outcomes(source):
        return [(r['label'], r['result']) for r in source if r['event'] == 'request.completed']
    require(outcomes(rows) == outcomes(reference), 'controller result sequence differs')
    require(all(r['result'] == 'ok' for r in rows if r['event'] == 'report.incomingCompleted'), 'incoming report failed')
    # Every app action keeps its identity through a fresh delivered transaction.
    requests = {r['transactionID']: r for r in rows if r['event'] == 'request.begin'}
    for r in engine:
        if r['event'] == 'transaction.delivered' and r['origin'] == 'application':
            request = requests.get(r['requestID'])
            require(request is not None and request['actionIDs'] == [i[:8] for i in r['actionIDs']], 'action identity changed')
            require(r['transactionID'] != r['requestID'], 'transaction identity reused')
    for r in rows:
        if r['event'] in ('provider.executeTransaction', 'provider.perform', 'provider.timedOut', 'observer.callChanged',
                          'provider.didActivateAudio', 'provider.didDeactivateAudio', 'report.incomingCompleted'):
            require(r.get('main') is True, 'nil queue callback not main')
    if scenario == 'failures':
        require(one(rows, 'observer.snapshot', label='after-answer-fail')['calls'] == [], 'failed answer survived')
        state = one(rows, 'observer.snapshot', label='after-mute-fail')
        require(len(state['calls']) == 1 and state['calls'][0]['connected'], 'mute failure destroyed call')
        require(one(rows, 'observer.snapshot', label='after-end-deadline')['calls'] == [], 'unfulfilled end survived deadline')
        timeouts = [r for r in rows if r['event'] == 'provider.timedOut']
        require(len(timeouts) == 2, 'end timeout inventory differs')
        for timeout in timeouts:
            action = one(rows, 'provider.perform', id=timeout['id'], kind=timeout['kind'])
            require(timeout['kind'] == 'CXEndCallAction' and 5000 <= timeout['t_ms'] - action['t_ms'] <= 5900, 'end timeout identity/budget')
    else:
        require(not any(r['event'] == 'provider.timedOut' for r in rows), 'unexpected answer-rules timeout')
        require(not any(r['event'] == 'provider.perform' and r['kind'] == 'CXAnswerCallAction' and
                        r['call'] in (one(rows, 'step', name='hold-then-answer')['b'], one(rows, 'step', name='end-and-accept')['d']) for r in rows), 'rejected waiting answer delivered')
        # Explicit multi-action end remains one ordered provider transaction.
        request = one(rows, 'request.begin', label='end-both')
        delivered = [r for r in engine if r['event'] == 'transaction.delivered' and r.get('requestID') == request['transactionID']]
        require(len(delivered) == 1 and delivered[0]['kinds'] == ['CXEndCallAction', 'CXEndCallAction'], 'end transaction split/reordered')
        remaining = one(rows, 'observer.snapshot', label='after-start-fail')['calls']
        c = one(rows, 'step', name='end-and-accept')['c']
        require(len(remaining) == 1 and remaining[0]['uuid'] == c and remaining[0]['connected'], 'failed outgoing call changed remaining calls')
    return dict(success=True, reference=reference_name, assertions='controller outcomes, action identity, timeout and observer state')


def main():
    result = {}
    for case in ('answer-rules', 'failures'):
        try: result[case] = validate(Path(sys.argv[1]), case)
        except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
            result[case] = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    return 0 if all(r['success'] for r in result.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
