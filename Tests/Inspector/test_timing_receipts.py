"""The opt-in Inspector receipt must cite actual, matching runtime journal rows."""
import copy
from pathlib import Path
import runpy
import unittest


RUNNER = runpy.run_path(str(Path(__file__).with_name('run.py')))


class TimingReceiptTests(unittest.TestCase):
    def setUp(self):
        identity = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture')
        def event(sequence, time, name, **fields):
            return dict(identity, sequence=sequence, t_ms=time, event=name, **fields)
        self.rows = [event(1, 100, 'push.received', pushID='p1', mustReport=True),
                     event(2, 290, 'report.completed', pushID='p1', error=0),
                     event(3, 300, 'action.deadline', kind='answer', actionID='a1', callUUID='c1', apiKind='callkit'),
                     event(4, 425, 'action.settled', kind='answer', actionID='a1', callUUID='c1', apiKind='callkit', fulfilled=True),
                     event(5, 536, 'audio.activated')]
        source = 'docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md'
        device = 'LCK · iPhone 13 · iOS 27.0 · Oct 23, 2026'
        self.readouts = [
            dict(id='pushReport', actualMS=190, startSequence=1, endSequence=2, deviceValue='≈190 ms',
                 actualLabel='Simulator · push → report done', sourcePath=source, deviceProvenance=device),
            dict(id='answerAudio', actualMS=236, startSequence=3, endSequence=5, deviceValue='≈236 ms',
                 actualLabel='Simulator · CallKit answer delivered → audio.activated', sourcePath=source, deviceProvenance=device),
            dict(id='muteEcho', deviceValue='8–17 ms after fulfillment', sourcePath=source, deviceProvenance=device),
            dict(id='unreportedPush', deviceValue='≈4.4 s', sourcePath=source, deviceProvenance=device),
        ]
        self.receipt = dict(cursor=5, timeline=self.rows, timingReferences=self.readouts)

    def verify(self, receipt=None, rows=None, required=('pushReport', 'answerAudio')):
        RUNNER['verify_timing_reference_journal'](receipt or self.receipt, rows or self.rows, required=required)

    def test_two_available_actuals_are_verified_against_the_original_journal(self):
        self.verify()

    def test_missing_or_invented_actuals_do_not_pass_acceptance(self):
        for mutation in ('missing', 'value', 'source', 'pair', 'api_label'):
            receipt = copy.deepcopy(self.receipt)
            if mutation == 'missing':
                receipt['timingReferences'][0].pop('actualMS')
            elif mutation == 'value':
                receipt['timingReferences'][0]['actualMS'] = 191
            elif mutation == 'source':
                receipt['timingReferences'][0]['startSequence'] = 99
            elif mutation == 'pair':
                receipt['timingReferences'][0]['endSequence'] = 4
            else:
                receipt['timingReferences'][1]['actualLabel'] = 'Simulator · LCK join delivered → audio.activated'
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                self.verify(receipt)

    def test_cross_push_and_old_attempt_cannot_be_mislabeled_as_the_latest_actual(self):
        unrelated = copy.deepcopy(self.rows)
        unrelated[1]['pushID'] = 'other'
        with self.assertRaises(AssertionError):
            self.verify(rows=unrelated)
        receipt = copy.deepcopy(self.receipt)
        pending = dict(self.rows[0], sequence=6, t_ms=700, pushID='p2')
        receipt['timeline'].append(pending)
        receipt['cursor'] = 6
        with self.assertRaises(AssertionError):
            self.verify(receipt, self.rows + [pending])

    def test_device_values_retain_their_lck_device_provenance(self):
        receipt = copy.deepcopy(self.receipt)
        receipt['timingReferences'][0]['deviceProvenance'] = 'CallKit · Simulator'
        with self.assertRaises(AssertionError):
            self.verify(receipt)

    def test_failed_report_or_pending_answer_cannot_claim_a_reference_actual(self):
        for index, field, value in [(1, 'error', 3), (3, 'fulfilled', False)]:
            rows = copy.deepcopy(self.rows)
            rows[index][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(rows=rows)


if __name__ == '__main__':
    unittest.main()
