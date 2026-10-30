#!/usr/bin/env python3
"""Keep the native filtered acceptance sensitive to real callback evidence."""
import copy
import json
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import filtered_acceptance as acceptance
from filtered_acceptance import assert_report_attempt


class FilteredAcceptanceTests(unittest.TestCase):
    def evidence(self):
        common = dict(callUUID='call-A', reportID='report-A', pushID='push-A', code=3,
                      domain='com.apple.CallKit.error.incomingcall', filterReason='do-not-disturb',
                      verification='verified', pid=42, runID='run-A', bundleID='fixture')
        return [dict(common, event='report.incoming', t_ms=10, latencyMS=0),
                dict(common, event='push.completed', t_ms=11, reportEntered=True),
                dict(common, event='push.callbackReturned', t_ms=12, reportEntered=True),
                dict(common, event='report.completed', t_ms=2080, latencyMS=2070, error=3),
                dict(common, event='fixture.reportCompleted', t_ms=2081, latencyMS=2071,
                     main=True, replyCount=1, handle='+12025550123')]

    def check(self, rows, **options):
        return assert_report_attempt(rows, call_uuid='call-A', push_id='push-A', reason='do-not-disturb',
                                     code=3, verification='verified', expected_delay_ms=2070, **options)

    def test_explicit_fault_is_distinct_from_a_natural_filter(self):
        rows = self.evidence()
        for row in rows:
            row.update(code=4, filterReason='none', verification='injected-fault')
        rows[3]['error'] = 4
        options = dict(call_uuid='call-A', push_id='push-A', reason='none', code=4,
                       verification='injected-fault', expected_delay_ms=2070)
        self.assertEqual(assert_report_attempt(rows, **options)['verification'], 'injected-fault')
        rows[0]['verification'] = 'unverified'
        with self.assertRaises(AssertionError):
            assert_report_attempt(rows, **options)

    def test_observes_actual_nserror_callback(self):
        self.assertEqual(self.check(self.evidence())['code'], 3)

    def test_delayed_callback_accepts_slow_scheduling_but_rejects_nonfinite_latency(self):
        rows = self.evidence()
        for row in rows[-2:]:
            row['t_ms'] += 900000
            row['latencyMS'] += 900000
        self.assertEqual(self.check(rows)['code'], 3)
        for invalid in (float('inf'), float('nan')):
            rows[-1]['latencyMS'] = invalid
            with self.assertRaises(AssertionError):
                self.check(rows)

    def test_report_completed_alone_does_not_prove_the_callback(self):
        with self.assertRaisesRegex(AssertionError, 'actual callback'):
            self.check(self.evidence()[:-1])

    def test_rejects_callback_identity_queue_repetition_and_timing_failures(self):
        for field, value in [('domain', 'wrong'), ('code', 0), ('main', False),
                             ('replyCount', 2), ('latencyMS', 50), ('handle', 'different')]:
            with self.subTest(field=field):
                rows = copy.deepcopy(self.evidence())
                rows[-1][field] = value
                with self.assertRaises(AssertionError):
                    self.check(rows)
        rows = self.evidence()
        rows.append(copy.deepcopy(rows[-1]))
        with self.assertRaisesRegex(AssertionError, 'actual callback'):
            self.check(rows)

    def test_rejects_phantom_calls_audio_or_missing_push_entry(self):
        for event in ['call.changed', 'audio.activated', 'action.delivered', 'diagnostic.pushReportExpired']:
            with self.subTest(event=event):
                rows = self.evidence() + [dict(event=event, uuid='call-A', callUUID='call-A')]
                with self.assertRaises(AssertionError):
                    self.check(rows)
        rows = self.evidence()
        rows[1]['reportEntered'] = False
        with self.assertRaises(AssertionError):
            self.check(rows)

    def test_expected_expiry_of_an_old_post_end_action_does_not_fail_a_filtered_report(self):
        old_action = dict(actionID='old-action', callUUID='old-call', origin='postEndUnmute', kind='mute')
        rows = self.evidence() + [dict(old_action, event='action.expired'),
                                  dict(old_action, event='action.timeout'),
                                  dict(event='audio.deactivated'),
                                  dict(event='audio.failed', activating=False)]
        self.assertEqual(self.check(rows, previous_actions={'old-action': 'old-call'})['code'], 3)

    def test_filtered_or_unknown_action_timeout_and_any_new_delivery_still_fail(self):
        prior = {'old-action': 'old-call'}
        cases = [dict(event='action.expired', actionID='old-action', callUUID='call-A'),
                 dict(event='action.timeout', actionID='old-action', callUUID='call-A'),
                 dict(event='action.timeout', actionID='new-action', callUUID='unknown-call'),
                 dict(event='action.deadline', actionID='old-action', callUUID='old-call'),
                 dict(event='action.delivered', actionID='new-action', callUUID='unknown-call'),
                 dict(event='transaction.delivered', actionIDs=['new-action'], callUUIDs=['unknown-call']),
                 dict(event='call.changed', uuid='unknown-call'),
                 dict(event='audio.activated'),
                 dict(event='audio.failed', activating=True),
                 dict(event='fault.audioSuppressed')]
        for row in cases:
            with self.subTest(row=row), self.assertRaises(AssertionError):
                self.check(self.evidence() + [row], previous_actions=prior)

    def test_report_ids_must_correlate_each_attempt(self):
        rows = self.evidence()
        rows[3]['reportID'] = 'another-report'
        with self.assertRaises(AssertionError):
            self.check(rows)

    def test_archived_late_mutation_does_not_prove_a_snapshot(self):
        # PR #89: the correct callback already happened before either mutation.
        entry = dict(event='report.incoming', sequence=145, t_ms=64617, reportID='report')
        rows = [entry,
                dict(event='report.completed', sequence=148, t_ms=66708, reportID='report'),
                dict(event='fixture.reportCompleted', sequence=149, t_ms=66708, callUUID='call'),
                dict(event='incomingFilter.configured', sequence=150, t_ms=67447, requestID='filter'),
                dict(event='faults.configured', sequence=151, t_ms=68256, requestID='fault')]
        with self.assertRaisesRegex(AssertionError, 'must precede'):
            acceptance.assert_snapshot_mutations(rows, call_uuid='call', entry=entry,
                                                  filter_request='filter', fault_request='fault')
        # Filter mutation alone is insufficient if fault clearing missed the window.
        rows[3]['sequence'] = 146
        with self.assertRaisesRegex(AssertionError, 'must precede'):
            acceptance.assert_snapshot_mutations(rows, call_uuid='call', entry=entry,
                                                  filter_request='filter', fault_request='fault')

    def test_snapshot_uses_shipping_mailbox_with_slow_control_delivery(self):
        """Two 1.4 s controls exceed the archived window without a simulator."""
        with tempfile.TemporaryDirectory() as work:
            device = '00000001-1111-4111-8111-111111111111'
            container = Path(work) / device / 'data/Containers/Data/Application/00000002-1111-4111-8111-111111111111'
            channel = container / 'Documents/.callkit-simulator'
            mailbox = channel / 'snapshot-run'
            for name in ('requests', 'responses'): (mailbox / name).mkdir(parents=True)
            session = dict(schemaVersion=1, runID='snapshot-run', pid=123, bundleID='fixture',
                           profile='ios-27.0', controlTransport='directory-watch-v1')
            (channel / 'session.json').write_text(json.dumps(session))
            cli = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))
            now, pending, journal, requests = [0.0], {}, [], []
            completion = [None]
            report_delay = [0]
            def append(event, **fields):
                journal.append(dict(event=event, sequence=len(journal)+1, t_ms=round(now[0]*1000), **fields))
            def advance(seconds):
                now[0] += seconds
                for path in (mailbox / 'requests').glob('*.json'):
                    pending.setdefault(path, now[0] + 1.4)
                    response_path = mailbox / 'responses' / path.name
                    if response_path.exists() or now[0] < pending[path]: continue
                    request = json.loads(path.read_text())
                    requests.append(request)
                    result = {}
                    if request['operation'] == 'faults':
                        code = request['faults']['incomingErrorCode']
                        report_delay[0] = request['faults']['reportCallbackDelayMS']
                        result = dict(incomingErrorCode=code)
                        append('faults.configured', requestID=request['id'], incomingErrorCode=code)
                    elif request['operation'] == 'push':
                        result = dict(scheduled=True, pushID=request['id'])
                        append('report.incoming', callUUID='call', pushID=request['id'], reportID='report')
                        completion[0] = now[0] + report_delay[0] / 1000 + 0.02
                    elif request['operation'] == 'incoming-filter':
                        result = dict(incomingFilter=dict(reason='restricted-sharing-mode', code=5, verification='unverified'))
                        append('incomingFilter.configured', requestID=request['id'])
                    response_path.write_text(json.dumps(dict(request, success=True, result=result)))
                if completion[0] is not None and now[0] >= completion[0]:
                    completion[0] = None
                    append('report.completed', reportID='report')
                    append('fixture.reportCompleted', callUUID='call')
            def wait(predicate):
                for _ in range(200):
                    value = predicate()
                    if value: return value
                    advance(0.05)
                self.fail('simulated mailbox readiness timed out')
            rpc = Mock(side_effect=AssertionError('Snapshot controls cannot invoke simctl'))
            with patch.object(acceptance.runpy, 'run_path', return_value=cli) as load:
                control = acceptance.snapshot_control(channel, session)
                with patch.dict(cli['control'].__globals__, simctl=rpc,
                                time=SimpleNamespace(monotonic=lambda: now[0], sleep=advance)):
                    cursor, push, entry, selected, changed = acceptance.mutate_pending_fault(
                        control=control, rows=lambda: journal, wait=wait, payload=Path(work)/'payload.json', call_uuid='call')
                    wait(lambda: any(r['event']=='fixture.reportCompleted' for r in journal))
                    acceptance.assert_snapshot_mutations(journal[cursor:], call_uuid='call', entry=entry,
                                                          filter_request=selected, fault_request=changed)
                    (channel / 'session.json').write_text(json.dumps(dict(session, pid=124)))
                    with self.assertRaisesRegex(RuntimeError, 'session changed'): control('status')
                load.assert_called_once()
            rpc.assert_not_called()
            self.assertEqual([r['operation'] for r in requests], ['faults', 'push', 'incoming-filter', 'faults'])
            self.assertEqual(requests[0]['faults']['reportCallbackDelayMS'], 5000)
            self.assertEqual(requests[-1]['faults'], dict(incomingErrorCode=0, reportCallbackDelayMS=1000))
            self.assertTrue(all(all(r[k]==session[k] for k in ('runID','pid','bundleID')) for r in requests))
            mutation = next(r for r in journal if r.get('requestID')==changed)
            self.assertGreater(mutation['t_ms']-entry['t_ms'], 2070)


if __name__ == '__main__':
    unittest.main()
