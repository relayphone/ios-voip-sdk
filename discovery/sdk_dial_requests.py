#!/usr/bin/env python3
"""Qualify direct simulator ingress; device default-app selection stays unmeasured."""
import argparse
import hashlib
import json
from pathlib import Path

import sdk_m0_conformance as m0
from sdk_installed_paths import installed_bundle
from sdk_m1_conformance import read_journal
from summarize import one, require

NAME = 'sdk-m3-direct'
BUNDLE = 'dev.iosvoipsdk.example'
URL_METHOD = 'UIApplicationDelegate.application(open:options:)'
INTENT_METHOD = 'VoIPSystemEntryPoints.handle(intent:)'


def qualify(rows, engine):
    launch = one(rows, 'launch')
    require([r['event'] for r in rows[:2]] == ['app.entry', 'launch'] and
            launch.get('mode') == 'sdk-m3' and launch.get('case') == 'direct' and launch.get('traceVersion') == 2,
            'wrong direct-delivery launch')
    require([r.get('sequence') for r in rows] == list(range(1, len(rows) + 1)) and
            one(rows, 'sdk.result').get('success') is True and rows[-1] is one(rows, 'done') and
            not any(r.get('error') or r.get('errorType') for r in rows), 'incomplete direct-delivery sequence')
    require(one(rows, 'sdk.activation').get('active') is True and
            one(rows, 'sdk.managerCreated').get('owner') == 'VoIPApplication.start', 'missing SDK owner')
    snapshots = [r for r in rows if r['event'] == 'sdk.snapshot']
    require(snapshots and all(r.get('conversations') == [] for r in snapshots), 'dial request created a conversation')
    direct = [r for r in rows if r['event'].startswith('m3.')]
    require([r['event'] for r in direct] == ['m3.ready', 'm3.delivery', 'm3.returned', 'm3.dialRequest',
            'm3.delivery', 'm3.returned', 'm3.dialRequest'], 'missing, duplicate or reordered public delivery')
    for offset, kind, handle, video, method in [(1, 'url', '+15555550142', False, URL_METHOD),
                                               (4, 'intent', '+15555550143', True, INTENT_METHOD)]:
        delivery, returned, observed = direct[offset:offset + 3]
        require(delivery.get('kind') == returned.get('kind') == kind and delivery.get('method') == method and
                returned.get('handled') is True and observed.get('handleSHA256') == hashlib.sha256(handle.encode()).hexdigest() and
                observed.get('video') is video and type(observed.get('conversationCount')) is int and
                observed['conversationCount'] == 0, 'public destination, capability or delivery differs')
    require(not any(r['event'].startswith(('report.', 'action.', 'transaction.')) for r in engine),
            'direct dial requests must leave calling to the host app')
    return dict(success=True, delivery='direct-url-and-intent', publicDialRequests=2)


def record(root, run_id, simulator):
    directory = root / 'm3'
    app, image = installed_bundle(directory, NAME, dict(runID=run_id, simulatorID=simulator), BUNDLE)
    javascript = app / 'main.jsbundle'
    require(javascript.is_file() and javascript.resolve(strict=True).parent == app, 'JavaScript escapes installed app')
    (directory / 'installed.json').write_text(json.dumps(dict(example=m0.digest(image), javascript=m0.digest(javascript))) + '\n')
    receipt = directory / (NAME + '.receipt.json')
    row = json.loads(receipt.read_text())
    row['journalSHA256'] = m0.digest(directory / (NAME + '.runtime.jsonl'))
    receipt.write_text(json.dumps(row, indent=2) + '\n')


def validate(root):
    # The original M0 gate binds source, installed/build bytes, device exclusion
    # and owned cleanup before the additional ingress evidence can qualify.
    m0.validate(root)
    manifest = json.loads((root / 'manifest.json').read_text())
    directory = root / 'm3'
    rows, receipt = m0.bound_rows(directory, NAME, manifest, BUNDLE)
    installed = json.loads((directory / 'installed.json').read_text())
    require(installed == {key: manifest['installedBinarySHA256'][key] for key in ('example', 'javascript')},
            'direct-delivery installed bytes differ from qualified build')
    version = (m0.ROOT / 'VERSION').read_text().strip()
    engine = read_journal(directory, NAME, manifest, receipt, version)
    return qualify(rows, engine)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('record', 'validate'))
    parser.add_argument('root', type=Path)
    parser.add_argument('--run-id')
    parser.add_argument('--simulator')
    args = parser.parse_args()
    if args.mode == 'record': record(args.root, args.run_id, args.simulator)
    else: print(json.dumps(validate(args.root), indent=2))
