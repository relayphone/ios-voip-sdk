#!/usr/bin/env python3
"""Synthetic positive/tamper controls; these do not claim native M1 acceptance."""
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_sdk_m0 as m0_controls
import sdk_m1_conformance as gate

CONVERSATION = 'E715ACF2-A7C1-4D74-8BD9-EAFA47693255'
PUSH = '62D7BDE8-FA14-40CD-A7E1-AF9D7E512B79'
PENDING = '9BB7DFDA-423D-4FA8-9202-055C5750FD55'
WALL = 1792627200000


def iso(milliseconds):
    return datetime.fromtimestamp(milliseconds / 1000, timezone.utc).isoformat()


def fixture_case(root, case, pid):
    rows = []
    revision = 0
    clock = 0

    def add(event, fields=None, at=None):
        nonlocal clock
        clock = max(clock + 1, clock + 1 if at is None else at)
        rows.append(dict(event=event, t_ms=clock, wallTimeMS=WALL + clock, main=True,
            pid=pid, runID='run-1', simulatorID='sim-1', bundleID='dev.iosvoipsdk.example', **(fields or {})))

    def snapshot(status=None, *, pending=False, connected=False):
        nonlocal revision
        calls = [] if status is None else [dict(id=CONVERSATION, direction='incoming', status=status,
            isMuted=False, isVideo=False, hasConnectedAt=connected)]
        if pending:
            calls[0]['pending'] = dict(id=PENDING, kind='join', deadline=iso(WALL + 28_500), origin='app')
        add('sdk.snapshot', dict(revision=revision, conversations=calls))
        revision += 1

    def hook(status=None, pending=None, connected=False):
        add('m1.hookConversations', dict(count=0 if status is None else 1,
            conversationID=None if status is None else CONVERSATION, status=status,
            pending=pending, hasConnectedAt=connected))

    def assertion(label, *, at=None):
        add('m1.assertion', dict(label=label, passed=True,
            conversationID=None if label == 'token-hook-observed' else CONVERSATION), at)

    def handler(kind, *, deadline=None, **fields):
        add('m1.handler', dict(kind=kind, conversationID=CONVERSATION, origin='app',
            deadline=iso(WALL + clock + 30_000) if deadline is None else deadline, **fields))

    add('app.entry')
    add('launch', dict(traceVersion=2, mode='sdk-m1', case=case))
    add('sdk.activation', dict(active=True))
    add('sdk.managerCreated', dict(owner='VoIPApplication.start'))
    snapshot()
    if case == 'journey':
        add('m1.jsReady')
        add('m1.subscriptionsStarting')
        add('m1.handlerAttached', dict(attached=True))
    add('m1.pushInjected', dict(pushID=PUSH, mustReport=True, label='primary' if case == 'journey' else 'cold'))
    snapshot('ringing')
    if case == 'journey':
        hook('ringing')
        assertion('push-ringing')
        assertion('ring-survives', at=clock + 1000)
        for label in ('dedup-event', 'dedup-server', 'dedup-single-conversation'):
            assertion(label)
        handler('join')
        snapshot('connected')
        assertion('joined')
        snapshot('connected', connected=True)
        hook('connected', connected=True)
        assertion('connected-report')
        handler('hold', held=True)
        snapshot('held', connected=True)
        hook('held', connected=True)
        assertion('held')
        handler('hold', held=False)
        snapshot('connected', connected=True)
        hook('connected', connected=True)
        assertion('resumed')
    else:
        add('m1.coldJoinRequested', dict(conversationID=CONVERSATION))
        snapshot('connecting', pending=True)
        add('m1.coldPending', dict(conversationID=CONVERSATION, actionID=PENDING,
            deadline=iso(WALL + 28_500), remainingMS=28_500 - clock - 1, handlerAttached=False,
            clockBeforeMS=WALL + clock + 1))
        add('m1.jsReady')
        add('m1.subscriptionsStarting')
        hook('connecting', pending='join')
        assertion('cold-snapshot-pending')
        assertion('cold-hook-pending')
        if case == 'cold-launch':
            clock = 5_000
            add('m1.handlerAttached', dict(attached=True))
            handler('join', deadline=iso(WALL + 28_500))
            snapshot('connected', connected=True)
            assertion('cold-redelivered')
        else:
            assertion('platform-deadline-visible')
    if case != 'unhandled-expiry':
        handler('end')
    else:
        clock = 30_300
    snapshot('ended')
    snapshot()
    hook()
    if case == 'unhandled-expiry':
        add('m1.expiryObserved', dict(conversationID=CONVERSATION, count=0))
        assertion('unhandled-expired-empty')
    else:
        assertion('ended-empty')
    add('m1.hookToken', dict(available=False, tokenType=None))
    assertion('token-hook-observed')
    add('sdk.result', dict(success=True))
    add('done')
    name = 'sdk-m1-' + case
    m0_controls.write_trace(root, name, rows)
    receipt_path = root / (name + '.receipt.json')
    receipt = json.loads(receipt_path.read_text())
    receipt.update(appPID=pid, launcherAppPID=pid)
    m0_controls.write_json(receipt_path, receipt)

    journal = []

    def runtime(event, at=None, **fields):
        elapsed = max(journal[-1]['t_ms'] + 1 if journal else 0, at or 0)
        journal.append(dict(event=event, sequence=len(journal) + 1, t_ms=elapsed,
            runID='run-1', pid=pid, bundleID='dev.iosvoipsdk.example', profile='ios-27.0', **fields))

    def call(**fields):
        runtime('call.changed', uuid=CONVERSATION, outgoing=False, connected=fields.pop('connected', False),
                ended=fields.pop('ended', False), held=fields.pop('held', False), **fields)

    runtime('runtime.installed', version=(gate.ROOT / 'VERSION').read_text().strip())
    runtime('provider.created', provider='synthetic-provider')
    runtime('push.received', pushID=PUSH, api='metadata', mustReport=True)
    runtime('report.incoming', pushID=PUSH, callUUID=CONVERSATION)
    call()
    runtime('report.completed', pushID=PUSH, callUUID=CONVERSATION, error=0)
    runtime('push.callbackReturned', pushID=PUSH, api='metadata', mustReport=True, reportEntered=True)
    runtime('push.completed', pushID=PUSH, api='metadata', mustReport=True, reportEntered=True)
    kinds = ['CXAnswerCallAction'] + (['CXSetHeldCallAction', 'CXSetHeldCallAction'] if case == 'journey' else [])
    if case != 'unhandled-expiry': kinds.append('CXEndCallAction')
    for index, kind in enumerate(kinds):
        runtime('transaction.delivered', provider='synthetic-provider', actionIDs=['action-' + str(index)], kinds=[kind])
        if case != 'journey' and index == 0:
            runtime('action.deadline', actionID='action-' + str(index), provider='synthetic-provider',
                    apiKind='livecommunicationkit', deadlineMS=WALL + 30_000, deadlineSeconds=30, expirySeconds=30)
            pending = next(row for row in rows if row['event'] == 'm1.coldPending')
            runtime('m1.coldPendingClock', at=pending['t_ms'], conversationID=CONVERSATION, actionID=PENDING)
        runtime('action.settled', at=30_000 if case == 'unhandled-expiry' else 5020 if case == 'cold-launch' else None,
                actionID='action-' + str(index), fulfilled=case != 'unhandled-expiry')
        if kind == 'CXAnswerCallAction' and case != 'unhandled-expiry': call(connected=True)
        if kind == 'CXSetHeldCallAction': call(connected=True, held=index == 1)
    call(ended=True)
    write_journal(root, name, journal)


def write_journal(root, name, rows):
    for sequence, row in enumerate(rows, 1):
        row['sequence'] = sequence
    path = root / (name + '.runtime.jsonl')
    path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
    m0_controls.change_json(root, name + '.receipt.json', lambda receipt: receipt.update(journalSHA256=gate.m0.digest(path)))


def mutate_rows(root, case, edit):
    name = 'sdk-m1-' + case
    rows = gate.m0.load(root, name)
    edit(rows)
    receipt = json.loads((root / (name + '.receipt.json')).read_text())
    m0_controls.write_trace(root, name, rows)
    # Preserve fresh process and journal bindings while recomputing the trace hash.
    m0_controls.change_json(root, name + '.receipt.json', lambda value: value.update(
        appPID=receipt['appPID'], launcherAppPID=receipt['appPID'], journalSHA256=receipt['journalSHA256']))


def mutate_journal(root, case, edit):
    name = 'sdk-m1-' + case
    path = root / (name + '.runtime.jsonl')
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    edit(rows)
    write_journal(root, name, rows)


def restore_public_platform_deadline(rows):
    public = iso(WALL + 30_000)
    for row in rows:
        if row['event'] == 'm1.coldPending':
            row.update(deadline=public, remainingMS=WALL + 30_000 - row['wallTimeMS'])
        if row['event'] == 'sdk.snapshot':
            for call in row['conversations']:
                if call.get('pending', {}).get('id') == PENDING: call['pending']['deadline'] = public
        if row['event'] == 'm1.handler' and row.get('kind') == 'join': row['deadline'] = public


class Controls(unittest.TestCase):
    def check(self, edit=None, succeeds=False):
        with tempfile.TemporaryDirectory(prefix='ios-voip-sdk-m1-controls-') as temporary:
            root = Path(temporary)
            m0_controls.fixture(root)
            (root / 'm1').mkdir()
            for index, case in enumerate(gate.CASES):
                fixture_case(root / 'm1', case, 123 + index)
            if edit: edit(root)
            with patch.object(gate.m0, 'source_identity', return_value=m0_controls.IDENTITY), \
                 patch.object(gate.m0, 'symbol_names', return_value=m0_controls.SYMBOLS), \
                 patch.object(gate.m0.subprocess, 'run', side_effect=AssertionError('native command forbidden')), \
                 patch.object(gate.m0.subprocess, 'check_output', side_effect=AssertionError('native command forbidden')):
                if edit is None or succeeds:
                    self.assertTrue(gate.validate(root)['success'])
                else:
                    with self.assertRaises((gate.EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration)):
                        gate.validate(root)

    def test_positive_all_cases(self):
        self.check()

    def test_base_build_bytes_and_receipts_remain_required(self):
        self.check(lambda root: (root / 'binaries/example').write_bytes(b'tampered'))
        self.check(lambda root: (root / 'sdk-m0.receipt.json').unlink())

    def test_case_and_journal_inventory(self):
        self.check(lambda root: (root / 'm1/sdk-m1-cold-launch.receipt.json').unlink())
        self.check(lambda root: (root / 'm1/sdk-m1-journey.runtime.jsonl').write_text(''))
        self.check(lambda root: (root / 'm1/extra.receipt.json').write_text('{}'))
        self.check(lambda root: m0_controls.change_json(root / 'm1', 'sdk-m1-journey.receipt.json',
            lambda receipt: receipt.pop('journalSHA256')))

    def test_journal_identity_and_push_correlation(self):
        for field, value in (('pid', 900), ('runID', 'other'), ('bundleID', 'other'), ('profile', 'other')):
            with self.subTest(field=field):
                self.check(lambda root, field=field, value=value: mutate_journal(root / 'm1', 'journey',
                    lambda rows: rows[0].update({field: value})))
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'report.incoming').update(pushID='')))
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'report.completed').update(error=2)))

    def test_required_callback_boundaries_are_hash_bound(self):
        for event in ('push.callbackReturned', 'push.completed'):
            self.check(lambda root, event=event: mutate_journal(root / 'm1', 'journey', lambda rows:
                rows.remove(next(row for row in rows if row['event'] == event))))
            for field, value in (('pushID', 'other-push'), ('reportEntered', False), ('reportEntered', 1),
                                 ('mustReport', False), ('mustReport', 1), ('api', 'legacy')):
                with self.subTest(event=event, field=field, value=value):
                    self.check(lambda root, event=event, field=field, value=value: mutate_journal(root / 'm1', 'journey',
                        lambda rows: next(row for row in rows if row['event'] == event).update({field:value})))
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', lambda rows:
            rows.append(dict(next(row for row in rows if row['event'] == 'push.callbackReturned'),
                             t_ms=rows[-1]['t_ms']+1))))
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', lambda rows:
            rows.append(dict(rows[-1], event='diagnostic.pushReportingViolation', severity='error',
                             reason='required-report-missing-at-callback-return', t_ms=rows[-1]['t_ms']+1))))

    def test_shipping_entry_rule_preserves_callkit_async_completion(self):
        engine=[dict(event=event,pushID=PUSH,api='metadata',mustReport=True,reportEntered=True) for event in
                ('push.received','report.incoming','push.callbackReturned','report.completed','push.completed')]
        for row in engine:
            if row['event'].startswith('report.'): row['callUUID']=CONVERSATION
        self.assertEqual(gate.push_report_boundaries(engine),1)
        with self.assertRaises(gate.EvidenceError):
            gate.push_report_boundaries(engine,require_settlement_before_return=True)

    def test_shared_shipping_report_settlement_call_identity(self):
        def fixture():
            return [dict(event=event,pushID=PUSH,api='metadata',mustReport=True,reportEntered=True,
                         callUUID=CONVERSATION) for event in
                    ('push.received','report.incoming','report.completed','push.callbackReturned','push.completed')]
        self.assertEqual(gate.push_report_boundaries(fixture()),1)
        for field in ('report.incoming','report.completed'):
            for identifier in ('', 'not-a-uuid', PENDING):
                engine=fixture()
                next(row for row in engine if row['event']==field)['callUUID']=identifier
                with self.subTest(event=field,identifier=identifier), self.assertRaises(gate.EvidenceError):
                    gate.push_report_boundaries(engine)
        for event in ('report.incoming','report.completed'):
            engine=fixture()
            engine.insert(3,dict(next(row for row in engine if row['event']==event)))
            with self.subTest(duplicate=event), self.assertRaises(gate.EvidenceError):
                gate.push_report_boundaries(engine)
        engine=fixture(); engine[1],engine[2]=engine[2],engine[1]
        with self.assertRaises(gate.EvidenceError): gate.push_report_boundaries(engine)
        for event in ('report.incoming','report.completed'):
            engine=fixture(); engine.append(dict(event=event,pushID='unknown',callUUID=CONVERSATION))
            with self.subTest(orphan=event), self.assertRaises(gate.EvidenceError):
                gate.push_report_boundaries(engine)
        engine=fixture()
        engine.extend(dict(event=event,pushID='',callUUID=PENDING) for event in ('report.incoming','report.completed'))
        self.assertEqual(gate.push_report_boundaries(engine),1, 'ordinary non-push reports remain valid')

    def test_callback_entry_cannot_be_forged_by_a_late_report(self):
        def defer_report(rows):
            returned=next(row for row in rows if row['event']=='push.callbackReturned')
            rows.remove(returned)
            rows.insert(next(i for i,row in enumerate(rows) if row['event']=='report.incoming'),returned)
            for index,row in enumerate(rows): row['t_ms']=index
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', defer_report))
        def completion_first(rows):
            returned=next(row for row in rows if row['event']=='push.callbackReturned')
            rows.remove(returned)
            rows.insert(next(i for i,row in enumerate(rows) if row['event']=='push.completed')+1,returned)
            for index,row in enumerate(rows): row['t_ms']=index
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', completion_first), succeeds=True)

    def test_provider_ownership_and_settlements(self):
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'transaction.delivered').update(provider='other')))
        self.check(lambda root: mutate_journal(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'action.settled').update(fulfilled=False)))
        self.check(lambda root: mutate_journal(root / 'm1', 'unhandled-expiry', lambda rows:
            next(row for row in rows if row['event'] == 'action.settled').update(fulfilled=True)))

    def test_assertions_hooks_and_privacy(self):
        self.check(lambda root: mutate_rows(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'm1.assertion').update(passed=False)))
        self.check(lambda root: mutate_rows(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'm1.hookConversations' and row.get('status') == 'held').update(status='connected')))
        self.check(lambda root: mutate_rows(root / 'm1', 'journey', lambda rows: rows[0].update(value='synthetic-token')))
        self.check(lambda root: mutate_rows(root / 'm1', 'journey', lambda rows:
            next(row for row in rows if row['event'] == 'sdk.snapshot' and row['conversations'])['conversations'].append(
                dict(id='duplicate'))))

    def test_cold_pending_and_deadline_policy(self):
        self.check(lambda root: mutate_rows(root / 'm1', 'cold-launch', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPending').update(handlerAttached=True)))
        self.check(lambda root: mutate_rows(root / 'm1', 'cold-launch', lambda rows:
            next(row for row in rows if row['event'] == 'm1.handler').update(deadline=iso(WALL + 60_000))))
        self.check(lambda root: mutate_rows(root / 'm1', 'unhandled-expiry', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPending').update(remainingMS=1)))
        self.check(lambda root: mutate_rows(root / 'm1', 'unhandled-expiry', lambda rows:
            next(row for row in rows if row['event'] == 'm1.hookConversations' and row.get('pending') == 'join').update(pending=None)))
        self.check(lambda root: mutate_rows(root / 'm1', 'cold-launch', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPending').update(actionID='different')))
        self.check(lambda root: mutate_rows(root / 'm1', 'unhandled-expiry', lambda rows:
            [row.update(t_ms=row['t_ms'] - 30_000) for row in rows if row['t_ms'] > 30_000]))
        self.check(lambda root: mutate_rows(root / 'm1', 'cold-launch', lambda rows:
            next(row for row in rows if row['event'] == 'm1.handler').update(deadline=iso(WALL + 35_000))))
        self.check(lambda root: mutate_rows(root / 'm1', 'cold-launch', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPending').update(remainingMS=29_000)))
        self.check(lambda root: mutate_rows(root / 'm1', 'cold-launch', lambda rows:
            next(row for row in rows if row['event'] == 'm1.handler').update(deadline=iso(WALL + 29_000))))

    def test_expected_expiry_rejection_and_cold_hydration(self):
        def rejection(root):
            def edit(rows):
                index = next(index for index, row in enumerate(rows) if row['event'] == 'm1.expiryObserved')
                row = dict(rows[index], event='m1.coldJoinRequestResult', accepted=False,
                           errorType='SyntheticExpectedRejection')
                rows.insert(index, row)
            mutate_rows(root / 'm1', 'unhandled-expiry', edit)
        self.check(rejection, succeeds=True)
        def late_pending(root):
            def edit(rows):
                pending = next(row for row in rows if row['event'] == 'm1.coldPending')
                rows.remove(pending)
                index = next(index for index, row in enumerate(rows) if row['event'] == 'm1.subscriptionsStarting')
                rows.insert(index + 1, pending)
                for index, row in enumerate(rows): row['t_ms'] = index
            mutate_rows(root / 'm1', 'cold-launch', edit)
        self.check(late_pending)

    def test_cold_effective_deadline_requires_native_margin(self):
        for case in ('cold-launch', 'unhandled-expiry'):
            with self.subTest(case=case):
                self.check(lambda root, case=case: mutate_rows(root / 'm1', case, restore_public_platform_deadline))

    def test_cold_native_deadline_binding(self):
        for case in ('cold-launch', 'unhandled-expiry'):
            def missing(rows): rows.remove(next(row for row in rows if row['event'] == 'action.deadline'))
            def duplicate(rows):
                index = next(i for i, row in enumerate(rows) if row['event'] == 'action.deadline')
                rows.insert(index + 1, dict(rows[index]))
            def late(rows):
                deadline = next(row for row in rows if row['event'] == 'action.deadline'); rows.remove(deadline)
                index = next(i for i, row in enumerate(rows) if row['event'] == 'm1.coldPendingClock')
                deadline['t_ms'] = rows[index]['t_ms']; rows.insert(index + 1, deadline)
            for name, edit in (('missing', missing), ('duplicate', duplicate), ('after-pending-clock', late)):
                with self.subTest(case=case, mutation=name):
                    self.check(lambda root, case=case, edit=edit: mutate_journal(root / 'm1', case, edit))
            for field, value in (('actionID', PENDING), ('provider', 'different-provider'), ('apiKind', 'callkit'),
                                 ('deadlineMS', WALL + 28_500), ('deadlineSeconds', 60), ('expirySeconds', 60)):
                with self.subTest(case=case, field=field):
                    self.check(lambda root, case=case, field=field, value=value: mutate_journal(root / 'm1', case,
                        lambda rows: next(row for row in rows if row['event'] == 'action.deadline').update({field: value})))

    def test_native_expiry_deadline_clock_binding(self):
        def timing(rows, at):
            index = next(i for i, row in enumerate(rows) if row['event'] == 'action.settled')
            rows[index]['t_ms'] = at
            for row in rows[index + 1:]: row['t_ms'] = max(row['t_ms'], at + 1)
        for at in (1000, 40_000):
            with self.subTest(at=at):
                self.check(lambda root, at=at: mutate_journal(root / 'm1', 'unhandled-expiry',
                    lambda rows: timing(rows, at)))
        self.check(lambda root: mutate_journal(root / 'm1', 'unhandled-expiry', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPendingClock').update(actionID='different-native-action')))
        self.check(lambda root: mutate_journal(root / 'm1', 'unhandled-expiry', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPendingClock').update(conversationID='different-conversation')))
        self.check(lambda root: mutate_rows(root / 'm1', 'unhandled-expiry', lambda rows:
            next(row for row in rows if row['event'] == 'm1.coldPending').update(clockBeforeMS=WALL - 1000)))


if __name__ == '__main__':
    unittest.main(verbosity=2)
