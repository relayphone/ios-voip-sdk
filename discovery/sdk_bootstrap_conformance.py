#!/usr/bin/env python3
"""Validate source bootstrap captures and their process-bound launcher receipts."""
import hashlib
import json
from pathlib import Path
import sys

from summarize import EvidenceError, load, one, require


def validate(directory):
    results = {}
    for case in ('healthy', 'profile', 'push-after-install'):
        name = 'bootstrap-' + case
        rows = load(directory, name)
        receipt = json.loads((directory / f'{name}.receipt.json').read_text())
        launch, done = one(rows, 'launch'), one(rows, 'done')
        require(receipt.get('schemaVersion') == 2 and receipt.get('success') is True and
                receipt.get('completed') is True and receipt.get('terminateExitCode') == 0, 'incomplete bootstrap receipt')
        path = next(p for p in (directory / f'{name}.log', directory / f'{name}.jsonl') if p.exists())
        require(receipt.get('traceSHA256') == hashlib.sha256(path.read_bytes()).hexdigest(), 'bootstrap trace hash mismatch')
        for key in ('runID', 'simulatorID', 'bundleID'):
            require(bool(launch.get(key)) and receipt.get(key) == launch[key], 'bootstrap ' + key + ' mismatch')
        require(all(row.get('main') is True and all(row.get(key) == launch.get(key)
                    for key in ('runID', 'simulatorID', 'bundleID', 'pid')) for row in rows), 'mixed bootstrap process evidence')
        require(all(a['t_ms'] <= b['t_ms'] for a,b in zip(rows,rows[1:])), 'non-monotonic bootstrap trace')
        require(receipt.get('appPID') == receipt.get('launcherAppPID') == launch.get('pid'), 'bootstrap PID mismatch')
        require(launch.get('mode') == case and launch.get('injected') is False, 'bootstrap requires a plain source-linked process')
        expected = ['explicit-activation-required'] + (['activation-succeeds', 'successful-runtime-active', 'activation-idempotent']
                   if case == 'healthy' else ['activation-refuses', 'refused-runtime-inactive',
                   'all-root-concrete-action-push-imps-restored', 'refusal-idempotent'])
        checks = [row for row in rows if row['event'] == 'bootstrap.check']
        require([row.get('label') for row in checks] == expected and all(row.get('passed') is True for row in checks),
                'bootstrap activation or rollback checks failed')
        require(rows[-1] is done and done.get('success') is True and done.get('checks') == len(expected) and
                done.get('snapshots', 0) >= 60, 'incomplete bootstrap snapshot inventory')
        results[case] = dict(success=True, checks=len(checks), effectiveMethods=done['snapshots'])
    return dict(success=True, cases=results)


if __name__ == '__main__':
    try:
        result = validate(Path(sys.argv[1]))
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['success'] else 1)
