#!/usr/bin/env python3
"""Materialize tampered shipping captures and call the production validators.

Input must be a completed capture from the current runtime. Mutations deliberately
recompute receipt hashes: rejection must come from the semantic assertion being
tested, rather than a stale checksum. These derived fixtures are negative tests,
not additional runtime measurements.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

import generations_conformance
import semantics_conformance
import summarize
from summarize import EvidenceError, load, one, require, shipping


def write_capture(directory, name, rows, engine):
    trace = directory / f'{name}.log'
    journal = directory / f'{name}.engine.jsonl'
    trace.write_text(''.join('PROBE ' + json.dumps(r, sort_keys=True) + '\n' for r in rows))
    journal.write_text(''.join(json.dumps(r, sort_keys=True) + '\n' for r in engine))
    receipt_path = directory / f'{name}.receipt.json'
    receipt = json.loads(receipt_path.read_text())
    receipt.update(traceSHA256=hashlib.sha256(trace.read_bytes()).hexdigest(),
                   engineSHA256=hashlib.sha256(journal.read_bytes()).hexdigest())
    receipt_path.write_text(json.dumps(receipt))


def shipping_controls(source):
    baseline = summarize.validate(source)
    require(baseline['success'], f'shipping baseline rejected: {baseline}')
    require(all(shipping(load(source, name)) for name in ('runtime', 'push')),
            'positive fixture must enter both shipping branches')
    for case in ('answer-rules', 'failures'):
        semantics_conformance.validate(source, case)
    generations_conformance.validate(source)
    checks = ['shipping-positive', 'semantics-positive', 'generations-positive']

    def check(label, name, mutate, expected, validator=None):
        with tempfile.TemporaryDirectory(prefix='cksim-shipping-control-') as temporary:
            directory = Path(temporary)
            # Copy capture metadata, never build products or diagnostic logs.
            for path in source.iterdir():
                if path.is_file() and path.suffix in ('.json', '.txt'):
                    shutil.copyfile(path, directory / path.name)
            for scenario in ('genuine', 'runtime', 'push', name):
                for suffix in ('log', 'jsonl', 'receipt.json', 'engine.jsonl'):
                    path = source / f'{scenario}.{suffix}'
                    if path.exists():
                        shutil.copyfile(path, directory / path.name)
            (directory / 'runtime-dist').symlink_to((source / 'runtime-dist').resolve(), target_is_directory=True)
            rows = load(directory, name)
            engine = [json.loads(line) for line in (directory / f'{name}.engine.jsonl').read_text().splitlines()]
            mutate(rows, engine)
            # Normalize the trace representation while preserving event order.
            jsonl = directory / f'{name}.jsonl'
            if jsonl.exists():
                jsonl.unlink()
            write_capture(directory, name, rows, engine)
            if validator:
                try:
                    validator(directory)
                except EvidenceError as error:
                    rejection = str(error)
                else:
                    raise EvidenceError(f'{label}: accepted tampered capture')
            else:
                result = summarize.validate(directory)
                require(not result['success'], f'{label}: accepted tampered shipping capture')
                require(all(result['scenarios'][other]['success'] for other in summarize.SCENARIOS if other != name),
                        f'{label}: unrelated scenario rejected: {result}')
                rejection = result['scenarios'][name].get('error', 'missing rejection')
            require(expected in rejection, f'{label}: wrong rejection: {rejection}')
            checks.append(label)

    def unmute(rows):
        return one(rows, 'provider.perform', kind='CXSetMutedCallAction', muted=False)

    def no_prior_mute(rows, engine):
        for row in rows:
            if row['event'] == 'provider.perform' and row.get('muted') is True:
                row['muted'] = None

    def no_prior_end(rows, engine):
        call = unmute(rows)['call']
        for row in rows:
            if row['event'] == 'observer.callChanged' and row.get('uuid') == call and row.get('ended') is True:
                row['uuid'] = 'WRONGCALL'

    def bad_unmute_budget(rows, engine):
        action = unmute(rows)
        one(rows, 'provider.timedOut', id=action['id'])['t_ms'] = action['t_ms'] + 4900
        rows.sort(key=lambda r: r['t_ms'])

    def missing_echo(rows, engine):
        own = one(rows, 'request.begin', label='mute-a')['actionIDs'][0]
        echo = next(r for r in rows if r['event'] == 'provider.perform' and
                    r.get('muted') is True and r['id'] != own)
        identity = echo['id']
        rows[:] = [r for r in rows if not (r.get('id') == identity or
                   r['event'] == 'provider.executeTransaction' and r.get('actionIDs') == [identity])]

    def wrong_echo_value(rows, engine):
        own = one(rows, 'request.begin', label='mute-a')['actionIDs'][0]
        next(r for r in rows if r['event'] == 'provider.perform' and
             r.get('muted') is True and r['id'] != own)['muted'] = None

    check('post-end-unmute-without-mute', 'runtime', no_prior_mute, 'post-end unmute has no earlier mute')
    check('post-end-unmute-before-end', 'runtime', no_prior_end, 'post-end unmute precedes call end')
    check('post-end-unmute-budget', 'runtime', bad_unmute_budget, 'post-end unmute timeout budget')
    check('post-end-unmute-wrong-timeout', 'runtime',
          lambda rows, engine: one(rows, 'provider.timedOut').update(id='WRONG-ID'), 'got 0')
    check('shipping-missing-mute-echo', 'runtime', missing_echo, 'missing mute echoes')
    check('shipping-wrong-mute-echo-value', 'runtime', wrong_echo_value, 'missing mute echoes')

    def delivered(engine):
        return next(r for r in engine if r['event'] == 'transaction.delivered')

    def wrong_submitted_identity(rows, engine):
        request = one(rows, 'request.begin', label='answer-a')
        one(engine, 'request.accepted', transactionID=request['transactionID'])['actionIDs'] = ['WRONG-ID']

    def duplicate_transaction(rows, engine):
        transactions = [r for r in engine if r['event'] == 'transaction.delivered']
        transactions[1]['transactionID'] = transactions[0]['transactionID']

    def duplicate_action(rows, engine):
        transactions = [r for r in engine if r['event'] == 'transaction.delivered']
        next(r for r in transactions if r['requestID'] == 'system')['actionIDs'] = transactions[0]['actionIDs'][:]

    for name in ('runtime', 'push'):
        check(f'{name}-journal-sequence', name, lambda rows, engine: engine[0].update(sequence=0),
              'engine journal sequence mismatch')
        check(f'{name}-journal-process', name, lambda rows, engine: engine[0].update(pid=0), 'engine process mismatch')
        check(f'{name}-journal-profile', name, lambda rows, engine: engine[0].update(profile='wrong'), 'engine profile mismatch')
        check(f'{name}-journal-action-kind', name,
              lambda rows, engine: delivered(engine).update(kinds=['CXUnknownCallAction']), 'engine/probe action inventory mismatch')
        check(f'{name}-journal-transaction-identity', name,
              lambda rows, engine: next(r for r in rows if r['event'] == 'provider.executeTransaction').update(transactionID='WRONG-ID'),
              'provider transaction identity mismatch')
    check('shipping-duplicate-delivered-transaction', 'runtime', duplicate_transaction, 'duplicate delivered transaction identity')
    check('shipping-submitted-action-identity', 'runtime', wrong_submitted_identity, 'submitted action identity mismatch')
    check('shipping-reused-request-transaction', 'runtime',
          lambda rows, engine: delivered(engine).update(requestID=delivered(engine)['transactionID']),
          'provider reused requested transaction identity')
    check('shipping-unvalidated-delivery', 'runtime',
          lambda rows, engine: delivered(engine).update(requestID='WRONG-ID'), 'unvalidated actions delivered')
    check('shipping-duplicate-delivered-action', 'runtime', duplicate_action, 'duplicate delivered action identity')
    check('shipping-group-target', 'runtime', lambda rows, engine: one(engine, 'call.grouped').update(group='WRONG-ID'),
          'runtime group membership mismatch')

    for scenario in ('answer-rules', 'failures'):
        name = 'semantics-' + scenario
        validator = lambda directory, scenario=scenario: semantics_conformance.validate(directory, scenario)
        check(name + '-controller-result', name,
              lambda rows, engine: next(r for r in rows if r['event'] == 'request.completed').update(result='wrong'),
              'controller result sequence differs', validator)
        check(name + '-action-identity', name,
              lambda rows, engine: next(r for r in engine if r['event'] == 'transaction.delivered' and
                                       r['origin'] == 'application').update(actionIDs=['WRONG-ID']),
              'action identity changed', validator)
    check('semantics-failed-answer-state', 'semantics-failures',
          lambda rows, engine: one(rows, 'observer.snapshot', label='after-answer-fail').update(calls=[{}]),
          'failed answer survived', lambda directory: semantics_conformance.validate(directory, 'failures'))
    check('semantics-failed-mute-state', 'semantics-failures',
          lambda rows, engine: one(rows, 'observer.snapshot', label='after-mute-fail').update(calls=[]),
          'mute failure destroyed call', lambda directory: semantics_conformance.validate(directory, 'failures'))

    def duplicate_check(rows, engine):
        checks = [r for r in rows if r['event'] == 'generation.check']
        checks[1]['name'] = checks[0]['name']

    check('generations-missing-boundary', 'generations',
          lambda rows, engine: rows.remove(next(r for r in rows if r['event'] == 'generation.check')),
          'missing lifecycle boundary', generations_conformance.validate)
    check('generations-false-result', 'generations',
          lambda rows, engine: next(r for r in rows if r['event'] == 'generation.check').update(success=False),
          'lifecycle regression', generations_conformance.validate)
    check('generations-duplicate-boundary', 'generations', duplicate_check,
          'missing lifecycle boundary', generations_conformance.validate)
    check('generations-stale-unmute', 'generations',
          lambda rows, engine: delivered(engine).update(origin='postEndUnmute'),
          'stale unmute produced', generations_conformance.validate)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path, help='completed current-runtime discovery output')
    args = parser.parse_args()
    directory = args.capture.resolve()
    checks = shipping_controls(directory)
    manifest = directory / 'manifest.json'
    traces = {name: hashlib.sha256((directory / f'{name}.log').read_bytes()).hexdigest()
              for name in ('runtime', 'push', 'semantics-answer-rules', 'semantics-failures', 'generations')}
    print(json.dumps(dict(success=True, fixtureKind='derived negative controls',
                          sourceManifestSHA256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                          sourceTraceSHA256=traces, checks=checks), indent=2))


if __name__ == '__main__':
    main()
