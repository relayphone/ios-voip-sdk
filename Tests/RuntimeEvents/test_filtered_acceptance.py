#!/usr/bin/env python3
"""Keep the native filtered acceptance sensitive to real callback evidence."""
import copy
import unittest

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

    def test_observes_actual_nserror_callback(self):
        self.assertEqual(self.check(self.evidence())['code'], 3)

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


if __name__ == '__main__':
    unittest.main()
