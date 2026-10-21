#!/usr/bin/env python3
"""Tamper with a fresh provider capture to guard the comparator itself."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
from conformance import providers, EvidenceError

source = Path(sys.argv[1])
checks = []
for mutation in ('none', 'action-identity', 'deadline', 'timeout-identity', 'audio-order'):
    with tempfile.TemporaryDirectory(prefix='cksim-conformance-check-') as temporary:
        directory = Path(temporary)
        for suffix in ('log', 'engine.jsonl', 'receipt.json'):
            shutil.copyfile(source / f'providers-single.{suffix}', directory / f'providers-single.{suffix}')
        path = directory / 'providers-single.log'
        rows = []
        for line in path.read_text().splitlines():
            if 'PROBE ' in line: rows.append(json.loads(line.split('PROBE ', 1)[1]))
        for row in rows:
            if mutation == 'action-identity':
                if row['event'] == 'tap.perform': row['action'] = 'FAKE' + row['action'][4:]
                if row['event'] == 'tap.execute': row['actions'] = ['FAKE' + i[4:] for i in row['actions']]
            if mutation == 'deadline' and row['event'] == 'tap.perform': row['timeoutIn'] = 0
            if mutation == 'timeout-identity' and row['event'] == 'tap.timedOut': row.update(action='NOACTION', p='WRONG')
            if mutation == 'audio-order':
                if row['event'] == 'tap.didActivate': row['event'] = 'tap.didDeactivate'
                elif row['event'] == 'tap.didDeactivate': row['event'] = 'tap.didActivate'
        path.write_text(''.join('PROBE ' + json.dumps(r) + '\n' for r in rows))
        receipt_path = directory / 'providers-single.receipt.json'
        receipt = json.loads(receipt_path.read_text())
        receipt['traceSHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        receipt_path.write_text(json.dumps(receipt))
        try:
            providers(directory, 'single')
            assert mutation == 'none', f'{mutation}: comparator accepted tampering'
        except EvidenceError:
            assert mutation != 'none', 'positive capture rejected'
        checks.append(mutation)
print(json.dumps(dict(success=True, checks=checks), indent=2))
