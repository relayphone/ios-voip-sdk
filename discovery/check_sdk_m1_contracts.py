#!/usr/bin/env python3
"""Focused positive/tamper fixtures, with no simulator or native process use."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import sdk_m1_contracts_conformance as gate

IDENTITY = dict(sourceCommit='a' * 40, sourceInputsSHA256='b' * 64, sourceDirty=False)
CALL = '61B0C5C2-78DD-48B8-9C56-0C6A6D53B78A'
ACTION = '03443A64-7BDD-4D77-B91B-048093F9AF04'
WALL = 1792627200000


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def fixture(build, capture):
    for name in gate.BUILD_FILES:
        path = build / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('synthetic fixture, never executable\n')
    for name in ('source-before.json', 'source-after.json'): write(build / name, IDENTITY)
    write(build / 'build-info.json', dict(schemaVersion=1, product='sdk-m1-contracts', configuration='Debug',
          **IDENTITY, files={name: gate.digest(build / name) for name in gate.BUILD_FILES}))
    for index, case in enumerate(gate.CASES):
        pid = 123 + index
        rows = []
        clock = 0
        def add(event, at=None, **fields):
            nonlocal clock
            clock = max(clock + 1, at or 0)
            row = dict(event=event, sequence=len(rows) + 1, t_ms=clock, wallTimeMS=WALL + clock,
                       runID='synthetic-run', simulatorID='synthetic-simulator', pid=pid,
                       bundleID=gate.BUNDLE, main=True, **fields)
            rows.append(row)
            return row
        add('app.entry')
        add('launch', traceVersion=2, mode='sdk-m1-contracts', case=case, runtimeInjectionPresent=False,
            executableSHA256=gate.digest(build / gate.BUILD_FILES[0]), simulatorOS='synthetic-iOS-27.0')
        add('contract.activation', active=True)
        if case == 'unhandled-accept': add('contract.configuration', policy='accept', handlerAttached=False)
        add('contract.owner', identity='client', sharedIdentity='client', warnings=0)
        if case == 'guard':
            for phase, count, identity in [('extra-cx', 1, 'provider-2'), ('extra-lck', 2, 'manager-2')]:
                add('contract.creationBegin', phase=phase)
                add('contract.warning', phase=phase, count=count, message=gate.WARNING)
                add('contract.creationEnd', phase=phase, warnings=count, identity=identity)
        else:
            pending = dict(id=ACTION, kind='join', origin='app', deadlineMS=WALL + 28_500)
            def snapshot(status=None, pending=None, at=None):
                calls = [] if status is None else [dict(id=CALL, status=status, hasConnectedAt=False)]
                if pending: calls[0]['pending'] = pending
                add('contract.snapshot', at=at, revision=len([r for r in rows if r['event'] == 'contract.snapshot']), conversations=calls)
            snapshot()
            add('contract.incoming', conversationID=CALL)
            snapshot('ringing', pending=pending)
            sample = add('contract.pending', conversationID=CALL, actionID=ACTION, kind='join', origin='app',
                         deadlineMS=WALL + 28_500, remainingMS=0, handlerAttached=False, clockBeforeMS=WALL + clock + 1)
            sample['remainingMS'] = sample['deadlineMS'] - sample['wallTimeMS']
            add('contract.joinResult', accepted=True)
            snapshot('connected', at=28_501)
            add('contract.observation', connected=True, conversationID=CALL)
            add('contract.endReportRequested', conversationID=CALL)
            snapshot()
            add('contract.reportEnded', conversationID=CALL)
        add('contract.result', success=True); add('done')
        engine = []
        def runtime(event, at=None, **fields):
            engine.append(dict(event=event, sequence=len(engine) + 1, t_ms=len(engine) if at is None else at,
                runID='synthetic-run', pid=pid, bundleID=gate.BUNDLE, profile='ios-27.0', **fields))
        runtime('runtime.installed', version=(gate.ROOT / 'VERSION').read_text().strip())
        for count in range(1, 4 if case == 'guard' else 2): runtime('provider.created', provider='provider-' + str(count))
        if case == 'unhandled-accept':
            runtime('transaction.delivered', kinds=['CXAnswerCallAction'], actionIDs=['native-cx-action'])
            runtime('action.deadline', actionID='native-cx-action', apiKind='livecommunicationkit',
                    deadlineMS=WALL + 30_000, deadlineSeconds=30, expirySeconds=30)
            runtime('contract.pendingClock', at=sample['t_ms'], actionID=ACTION)
            runtime('action.settled', at=28_500, actionID='native-cx-action', fulfilled=True)
            runtime('call.changed', at=28_501, uuid=CALL, connected=True, ended=False)
            runtime('report.ended', at=28_510, callUUID=CALL)
            runtime('call.changed', at=28_511, uuid=CALL, connected=True, ended=True)
        save(capture, case, rows, engine)


def save(capture, case, rows, engine):
    name = 'sdk-m1-contract-' + case
    log = capture / (name + '.log')
    log.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
    journal = capture / (name + '.runtime.jsonl')
    journal.write_text(''.join(json.dumps(row) + '\n' for row in engine))
    write(capture / (name + '.receipt.json'), dict(schemaVersion=2, scenario=name, bundleID=gate.BUNDLE,
        runID='synthetic-run', simulatorID='synthetic-simulator', completed=True, success=True,
        launcherPID=122, appPID=rows[0]['pid'], launcherAppPID=rows[0]['pid'], appEntryObserved=True, lastProbeEvent='done',
        launchExitCode=0, terminationMethod='console-launcher-signal', terminationSignal=15,
        terminationSignalDelivered=True, traceSHA256=gate.digest(log), journalSHA256=gate.digest(journal)))


class Controls(unittest.TestCase):
    def test_accept_cannot_race_the_platform_deadline(self):
        self.check('unhandled-accept', lambda rows, engine:
            next(row for row in engine if row['event'] == 'action.deadline').update(deadlineMS=WALL + 28_500))

    def check(self, case=None, edit=None, file_edit=None, succeeds=False, parent=None):
        with tempfile.TemporaryDirectory(prefix='sdk-m1-contract-controls-') as temporary:
            root = Path(temporary); build = root / 'build'; capture = root / 'capture'
            build.mkdir(); capture.mkdir(); fixture(build, capture)
            if case:
                name = 'sdk-m1-contract-' + case
                rows = gate.load(capture, name)
                engine = [json.loads(line) for line in (capture / (name + '.runtime.jsonl')).read_text().splitlines()]
                edit(rows, engine); save(capture, case, rows, engine)
            if file_edit: file_edit(build, capture)
            parent_path = None
            if parent is not None:
                parent_path = root / 'parent-manifest.json'
                write(parent_path, parent)
            with patch.object(gate, 'source_identity', return_value=IDENTITY):
                if succeeds: self.assertTrue(gate.validate(build, capture, parent_manifest=parent_path)['success'])
                else:
                    with self.assertRaises((gate.EvidenceError, OSError, ValueError, KeyError, TypeError)):
                        gate.validate(build, capture, parent_manifest=parent_path)

    def test_positive(self): self.check(succeeds=True)

    def test_parent_sdk_run_binding(self):
        parent = dict(runID='synthetic-run', simulatorID='synthetic-simulator', sourceCommit=IDENTITY['sourceCommit'])
        self.check(parent=parent, succeeds=True)
        for key in parent:
            with self.subTest(key=key):
                self.check(parent={**parent, key: 'different-' + key})

    def test_guard_warnings(self):
        for field, value in [('main', False), ('message', 'monitor disabled'), ('count', 0), ('phase', 'owned')]:
            with self.subTest(field=field):
                self.check('guard', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.warning').update({field: value}))
        self.check('guard', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.owner').update(warnings=1))
        self.check('guard', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.creationEnd').update(identity='wrong-provider'))

    def test_pending_deadline(self):
        self.check('unhandled-accept', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.pending').update(deadlineMS=WALL + 5000, remainingMS=4990))
        self.check('unhandled-accept', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.pending').update(handlerAttached=True))
        def early(rows, engine):
            row = next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and r['conversations'][0]['status'] == 'connected')
            row['wallTimeMS'] = WALL + 1000
        self.check('unhandled-accept', early)
        self.check('unhandled-accept', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and 'pending' in r['conversations'][0])['conversations'][0]['pending'].update(id='different-action'))

    def test_native_settlement(self):
        self.check('unhandled-accept', lambda rows, engine: next(r for r in engine if r['event'] == 'action.settled').update(fulfilled=False))
        self.check('unhandled-accept', lambda rows, engine: next(r for r in engine if r['event'] == 'call.changed').update(connected=False))
        self.check('unhandled-accept', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and r['conversations'][0]['status'] == 'connected')['conversations'][0].update(hasConnectedAt=True))

    def test_native_early_late_timing(self):
        def timing(rows, engine, settlement, connection):
            next(r for r in engine if r['event'] == 'action.settled')['t_ms'] = settlement
            next(r for r in engine if r['event'] == 'call.changed')['t_ms'] = connection
            for row in engine:
                if row['event'] == 'report.ended' or row.get('ended') is True:
                    row['t_ms'] = max(row['t_ms'], connection + 10)
        for settlement, connection in ((1000, 1001), (40_000, 40_001), (30_000, 40_000)):
            with self.subTest(settlement=settlement, connection=connection):
                self.check('unhandled-accept', lambda rows, engine: timing(rows, engine, settlement, connection))

    def test_build_and_receipt_binding(self):
        self.check(file_edit=lambda build, capture: (build / gate.BUILD_FILES[0]).write_text('tampered'))
        self.check(file_edit=lambda build, capture: (capture / 'sdk-m1-contract-guard.runtime.jsonl').write_text(''))
        for key, value in (('configuration', 'Release'), ('product', 'different'), ('schemaVersion', 0)):
            def metadata(build, capture, key=key, value=value):
                path = build / 'build-info.json'
                info = json.loads(path.read_text()); info[key] = value; write(path, info)
            self.check(file_edit=metadata)
        def rehashed_source_after(build, capture):
            write(build / 'source-after.json', {**IDENTITY, 'sourceInputsSHA256': 'c' * 64})
            path = build / 'build-info.json'
            info = json.loads(path.read_text())
            info['files']['source-after.json'] = gate.digest(build / 'source-after.json')
            write(path, info)
        self.check(file_edit=rehashed_source_after)
        def bad_pid(build, capture):
            path = capture / 'sdk-m1-contract-guard.receipt.json'
            receipt = json.loads(path.read_text()); receipt['launcherAppPID'] = 999; write(path, receipt)
        self.check(file_edit=bad_pid)


if __name__ == '__main__': unittest.main()
