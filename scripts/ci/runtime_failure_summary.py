#!/usr/bin/env python3
"""Summarize failed Runtime workflow phases without exposing command output."""
import json
import os
from pathlib import Path
import re
import sys

PHASES = (
    ('select', 'Select Xcode'),
    ('controls', 'Watcher and existing CLI controls'),
    ('build', 'Build simulator runtime and event fixture'),
    ('create', 'Create the single owned simulator'),
    ('watch', 'Consume the shared channel through watch'),
    ('lck', 'Verify genuine LCK report and explicit code-4 fault'),
    ('inspector', 'Follow an incoming call through the live SwiftUI inspector'),
    ('cleanup', 'Delete the owned simulator'),
)
LABEL = re.compile(r'^- `(infra:[A-Za-z0-9_.:-]{1,80})`: (.*)$')
TIMEOUT = re.compile(r'^- `measurement:simctl-timeout`: ([A-Za-z_]+)$')
OPERATIONS = frozenset(('create', 'boot', 'bootstatus', 'install', 'launch', 'terminate',
                        'io', 'shutdown', 'delete', 'list', 'privacy', 'spawn', 'get_app_container'))


def render(outcomes, receipts):
    lines = ['## Runtime failure summary', '']
    failed = False
    for key, title in PHASES:
        outcome = outcomes.get(key)
        if outcome not in ('failure', 'cancelled'):
            continue
        failed = True
        if outcome == 'cancelled':
            lines.append(f'- {title}: cancelled')
            continue
        labels, operations = [], []
        for line in receipts.get(key, '').splitlines():
            timeout = TIMEOUT.fullmatch(line)
            if timeout and timeout.group(1) in OPERATIONS and timeout.group(1) not in operations:
                operations.append(timeout.group(1))
            match = LABEL.fullmatch(line)
            if not match:
                continue
            label, detail = match.groups()
            if (detail.startswith(('scheduled', 'recovered')) or
                    (label == 'infra:inventory' and
                     detail.endswith('; scheduled one bounded re-attempt'))):
                continue
            if label not in labels:
                labels.append(label)
        reason = ', '.join('`' + label + '`' for label in labels)
        detail = 'observed infrastructure labels: ' + reason if reason else 'no infrastructure label recorded'
        if operations:
            detail += '; observed simctl timeouts: ' + ', '.join('`' + op + '`' for op in operations)
        lines.append(f'- {title}: {detail}')
    if not failed:
        lines.append('- No tracked Runtime phase failure or cancellation was recorded.')
    return '\n'.join(lines) + '\n'


def main():
    root = Path(os.environ['RUNNER_TEMP'])
    outcomes = json.loads(os.environ['RUNTIME_PHASE_OUTCOMES'])
    receipts = {}
    for key, _ in PHASES:
        try:
            receipts[key] = (root / ('runtime-phase-' + key + '.md')).read_text(errors='replace')
        except OSError:
            pass
    report = render(outcomes, receipts)
    (root / 'runtime-failure-summary.md').write_text(report)
    target = os.environ.get('GITHUB_STEP_SUMMARY')
    if target:
        with open(target, 'a') as stream:
            stream.write(report)
    sys.stdout.write(report)


if __name__ == '__main__':
    main()
