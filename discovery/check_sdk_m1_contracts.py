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


def reindex(engine, reset_clock=False):
    # Keep the outer journal valid when a semantic tamper removes/reorders rows.
    for index, row in enumerate(engine):
        row['sequence'] = index + 1
        if reset_clock:
            row['t_ms'] = index
            if 'wallTimeMS' in row: row['wallTimeMS'] = WALL + index


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
        if case == 'duplicate-wrapper': rows[-1]['entryPoint'] = 'VoIPApplication.start'
        if case == 'guard':
            for phase, count, identity in [('extra-cx', 1, 'provider-2'), ('extra-lck', 2, 'manager-2')]:
                add('contract.creationBegin', phase=phase)
                add('contract.warning', phase=phase, count=count, message=gate.WARNING)
                add('contract.creationEnd', phase=phase, warnings=count, identity=identity)
        elif case == 'duplicate-wrapper':
            payload_hash = 'd' * 64
            add('contract.duplicateSnapshot', revision=0, conversations=[])
            for ordinal, source in ((1, 'foreground'), (2, 'pushKit')):
                fields = dict(ordinal=ordinal, source=source, payloadSHA256=payload_hash)
                add('contract.duplicateReportRequested', **fields)
                if ordinal == 1:
                    add('contract.duplicateSnapshot', revision=1,
                        conversations=[dict(id=CALL, status='ringing', hasConnectedAt=False)])
                add('contract.duplicateReportResult', **fields, accepted=True, conversationID=CALL,
                    conversations=[dict(id=CALL, status='ringing', hasConnectedAt=False, hasPending=False)])
            add('contract.duplicateEndRequested', conversationID=CALL)
            add('contract.duplicateEndCommandResult', conversationID=CALL, accepted=True)
            add('contract.duplicateSnapshot', revision=2, conversations=[dict(id=CALL, status='ending',
                hasConnectedAt=False, pending=dict(id=ACTION, kind='end', origin='app'))])
            add('contract.duplicateEndHandler', conversationID=CALL, actionID=ACTION, origin='app')
            add('contract.duplicateSnapshot', revision=3, conversations=[dict(id=CALL, status='ended', hasConnectedAt=False)])
            add('contract.duplicateSnapshot', revision=4, conversations=[])
            add('contract.duplicateObservation', conversationID=CALL, empty=True)
        else:
            pending = dict(id=ACTION, kind='join', origin='app', deadlineMS=WALL + 28_500)
            def snapshot(status=None, pending=None, at=None, connected=False):
                calls = [] if status is None else [dict(id=CALL, status=status, hasConnectedAt=connected)]
                if pending: calls[0]['pending'] = pending
                add('contract.snapshot', at=at, revision=len([r for r in rows if r['event'] == 'contract.snapshot']), conversations=calls)
            snapshot()
            add('contract.incoming', conversationID=CALL)
            snapshot('ringing', pending=pending)
            sample = add('contract.pending', conversationID=CALL, actionID=ACTION, kind='join', origin='app',
                         deadlineMS=WALL + 28_500, remainingMS=0, handlerAttached=False, clockBeforeMS=WALL + clock + 1)
            sample['remainingMS'] = sample['deadlineMS'] - sample['wallTimeMS']
            add('contract.joinResult', accepted=True)
            snapshot('connecting', at=28_501)
            add('contract.joinSettled', joined=True, conversationID=CALL)
            add('contract.backendConnectedRequested', conversationID=CALL)
            snapshot('connected', connected=True)
            add('contract.backendConnected', conversationID=CALL)
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
        elif case == 'duplicate-wrapper':
            runtime('provider.apiKind', provider='provider-1', apiKind='livecommunicationkit', delegatePresent=True)
            for ordinal, source in ((1, 'foreground'), (2, 'pushKit')):
                fields = dict(ordinal=ordinal, source=source, payloadSHA256=payload_hash)
                runtime('contract.duplicateReportBoundary', **fields, stage='requested')
                runtime('report.incoming', callUUID=CALL, pushID='')
                if ordinal == 1: runtime('call.changed', uuid=CALL, outgoing=False, connected=False, ended=False)
                runtime('report.completed', callUUID=CALL, pushID='', error=0 if ordinal == 1 else 2)
                runtime('contract.duplicateReportBoundary', **fields, stage='returned', callUUID=CALL)
            runtime('contract.duplicateEndBoundary', stage='requested', callUUID=CALL)
            runtime('contract.duplicateEndBoundary', stage='command-returned', callUUID=CALL)
            runtime('transaction.delivered', origin='application', provider='provider-1', kinds=['CXEndCallAction'], actionIDs=['native-cx-end'])
            runtime('action.settled', actionID='native-cx-end', fulfilled=True)
            runtime('call.changed', uuid=CALL, outgoing=False, connected=False, ended=True)
            runtime('contract.duplicateEndBoundary', stage='observed-complete', callUUID=CALL, empty=True)
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
    def test_duplicate_command_return_is_not_settlement(self):
        def returned_later(rows, engine):
            result = next(r for r in rows if r['event'] == 'contract.duplicateEndCommandResult')
            rows.remove(result); rows.insert(rows.index(next(r for r in rows if r['event'] == 'contract.duplicateObservation')), result)
            marker = next(r for r in engine if r['event'] == 'contract.duplicateEndBoundary' and r['stage'] == 'command-returned')
            engine.remove(marker); engine.insert(-1, marker)
            reindex(rows, reset_clock=True); reindex(engine, reset_clock=True)
        # The default fixture returns before perform, as measured on device.
        # A slower request completion is valid too; neither return proves settlement.
        self.check('duplicate-wrapper', returned_later, succeeds=True)

    def test_duplicate_report_identity_and_result(self):
        self.check('duplicate-wrapper', lambda rows, engine:
            next(r for r in rows if r['event'] == 'contract.owner').update(entryPoint='ConversationClient.shared'))
        for event, field, value in (
                ('contract.duplicateReportRequested', 'source', 'foreground-only'),
                ('contract.duplicateReportRequested', 'ordinal', True),
                ('contract.duplicateReportRequested', 'payloadSHA256', 'e' * 64),
                ('contract.duplicateReportResult', 'conversationID', 'other-call'),
                ('contract.duplicateReportResult', 'accepted', False)):
            with self.subTest(event=event, field=field):
                self.check('duplicate-wrapper', lambda rows, engine:
                    [r for r in rows if r['event'] == event][-1].update({field: value}))
        for field, value in (('hasConnectedAt', True), ('hasConnectedAt', 0), ('hasPending', True), ('hasPending', 0)):
            with self.subTest(field=field, value=value):
                self.check('duplicate-wrapper', lambda rows, engine:
                    next(r for r in rows if r['event'] == 'contract.duplicateReportResult')['conversations'][0].update({field: value}))
        self.check('duplicate-wrapper', lambda rows, engine:
            next(r for r in rows if r['event'] == 'contract.duplicateReportResult')['conversations'].append(
                dict(id='other-call', status='ringing', hasConnectedAt=False, hasPending=False)))

    def test_duplicate_native_report_pairing(self):
        for event, field, value in (('report.completed', 'error', 0), ('report.completed', 'error', True),
                                   ('report.completed', 'callUUID', 'other-call'), ('report.incoming', 'callUUID', 'other-call'),
                                   ('contract.duplicateReportBoundary', 'payloadSHA256', 'e' * 64)):
            with self.subTest(event=event, field=field, value=value):
                self.check('duplicate-wrapper', lambda rows, engine:
                    [r for r in engine if r['event'] == event][-1].update({field: value}))
        def missing(rows, engine):
            for event in ('report.incoming', 'report.completed'):
                engine.remove([r for r in engine if r['event'] == event][-1])
            reindex(engine)
        self.check('duplicate-wrapper', missing)
        def extra(rows, engine):
            index = next(i for i, r in enumerate(engine) if r['event'] == 'report.incoming')
            engine.insert(index, dict(engine[index])); reindex(engine)
        self.check('duplicate-wrapper', extra)
        def escaped(rows, engine):
            marker = [r for r in engine if r['event'] == 'contract.duplicateReportBoundary'][2]
            engine.remove(marker)
            engine.insert(engine.index([r for r in engine if r['event'] == 'report.incoming'][1]) + 1, marker)
            reindex(engine, reset_clock=True)
        self.check('duplicate-wrapper', escaped)

    def test_duplicate_real_end_and_cleanup(self):
        for event, field, value in (('contract.duplicateEndHandler', 'origin', 'system'),
                                   ('contract.duplicateEndHandler', 'actionID', 'wrong-action'),
                                   ('contract.duplicateEndCommandResult', 'accepted', False),
                                   ('contract.duplicateObservation', 'empty', False)):
            with self.subTest(event=event, field=field):
                self.check('duplicate-wrapper', lambda rows, engine:
                    next(r for r in rows if r['event'] == event).update({field: value}))
        for event, field, value in (('transaction.delivered', 'origin', 'app'),
                                   ('transaction.delivered', 'kinds', ['CXAnswerCallAction']),
                                   ('transaction.delivered', 'actionIDs', ['wrong-action']),
                                   ('action.settled', 'fulfilled', False),
                                   ('provider.apiKind', 'apiKind', 'callkit')):
            with self.subTest(event=event, field=field):
                self.check('duplicate-wrapper', lambda rows, engine:
                    next(r for r in engine if r['event'] == event).update({field: value}))
        self.check('duplicate-wrapper', lambda rows, engine:
            [r for r in engine if r['event'] == 'call.changed'][-1].update(ended=False))
        self.check('duplicate-wrapper', lambda rows, engine:
            [r for r in engine if r['event'] == 'contract.duplicateEndBoundary'][-1].update(empty=False))
        self.check('duplicate-wrapper', lambda rows, engine:
            [r for r in rows if r['event'] == 'contract.duplicateSnapshot'][-1].update(
                conversations=[dict(id=CALL, status='ended', hasConnectedAt=False)]))
        def shortcut(rows, engine):
            engine.insert(-1, dict(engine[-1], event='report.ended', callUUID=CALL)); reindex(engine)
        self.check('duplicate-wrapper', shortcut)

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
            row = next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and r['conversations'][0]['status'] == 'connecting')
            row['wallTimeMS'] = WALL + 1000
        self.check('unhandled-accept', early)
        self.check('unhandled-accept', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and 'pending' in r['conversations'][0])['conversations'][0]['pending'].update(id='different-action'))

    def test_native_settlement(self):
        self.check('unhandled-accept', lambda rows, engine: next(r for r in engine if r['event'] == 'action.settled').update(fulfilled=False))
        self.check('unhandled-accept', lambda rows, engine: next(r for r in engine if r['event'] == 'call.changed').update(connected=False))
        self.check('unhandled-accept', lambda rows, engine: next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and r['conversations'][0]['status'] == 'connected')['conversations'][0].update(hasConnectedAt=False))

    def test_signaling_does_not_fabricate_connected(self):
        self.check('unhandled-accept', lambda rows, engine:
            next(r for r in rows if r['event'] == 'contract.snapshot' and r['conversations'] and
                 r['conversations'][0]['status'] == 'connecting')['conversations'][0].update(status='connected'))
        self.check('unhandled-accept', lambda rows, engine:
            next(r for r in rows if r['event'] == 'contract.backendConnectedRequested').update(conversationID='other'))
        self.check('unhandled-accept', lambda rows, engine:
            next(r for r in rows if r['event'] == 'contract.joinSettled').update(joined=False))

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
