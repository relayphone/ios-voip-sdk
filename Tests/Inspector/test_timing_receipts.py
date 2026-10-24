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


class MuteTransactionReceiptTests(unittest.TestCase):
    def setUp(self):
        self.identity = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture')
        existing = TimingReceiptTests()
        existing.setUp()
        self.references = existing.readouts
        for reference in self.references:
            for key in ('actualMS', 'startSequence', 'endSequence'):
                reference.pop(key, None)

    def event(self, sequence, time, name, **fields):
        return dict(self.identity, sequence=sequence, t_ms=time, event=name, **fields)

    def native_rows(self):
        def transaction(sequence, time, identifier, action, origin):
            return self.event(sequence, time, 'transaction.delivered', transactionID=identifier, provider='p1',
                              origin=origin, actionIDs=[action], callUUIDs=['c1'],
                              kinds=['CXSetMutedCallAction'], parameters=[dict(muted=True)])
        def action(sequence, time, name, identifier, action_id, origin, **fields):
            return self.event(sequence, time, name, transactionID=identifier, provider='p1', apiKind='callkit',
                              origin=origin, kind='mute', callUUID='c1', actionID=action_id, **fields)
        return [transaction(1, 0, 't1', 'm1', 'application'),
                action(2, 100, 'action.settled', 't1', 'm1', 'application', fulfilled=True),
                transaction(3, 114, 't2', 'e1', 'muteEcho'),
                action(4, 115, 'action.deadline', 't2', 'e1', 'muteEcho')]

    def verify(self, rows, start=2, end=4, milliseconds=15):
        references = copy.deepcopy(self.references)
        references[2].update(actualMS=milliseconds, startSequence=start, endSequence=end)
        receipt = dict(cursor=rows[-1]['sequence'], timeline=rows, timingReferences=references)
        RUNNER['verify_timing_reference_journal'](receipt, rows, required=('muteEcho',))

    def test_native_mute_value_is_resolved_from_transaction_parameters(self):
        self.verify(self.native_rows())

    def test_selected_action_index_controls_the_value(self):
        rows = self.native_rows()
        rows[0].update(actionIDs=['other', 'm1'], callUUIDs=['other-call', 'c1'],
                       kinds=['CXSetMutedCallAction', 'CXSetMutedCallAction'],
                       parameters=[dict(muted=False), dict(muted=True)])
        self.verify(rows)

    def test_legacy_direct_values_without_transactions_are_preserved(self):
        native = self.native_rows()
        rows = [dict(native[1], sequence=1, muted=True), dict(native[3], sequence=2, muted=True)]
        self.verify(rows, start=1, end=2)

    def test_invalid_transaction_metadata_cannot_claim_a_measured_mute(self):
        mutations = [dict(provider='other'), dict(origin='system'), dict(runID='other'),
                     dict(transactionID='other'), dict(actionIDs=['other']), dict(callUUIDs=['other']),
                     dict(kinds=['CXSetHeldCallAction']), dict(parameters=[dict(muted='true')]),
                     dict(parameters=[None]), dict(parameters=[]), dict(callUUIDs=[]), dict(kinds=[]),
                     dict(actionIDs=[]), dict(t_ms=101), dict(t_ms=float('nan')),
                     dict(actionIDs=['m1', 'm1'], callUUIDs=['c1', 'c1'],
                          kinds=['CXSetMutedCallAction'] * 2, parameters=[dict(muted=True)] * 2)]
        for mutation in mutations:
            rows = self.native_rows()
            rows[0].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                self.verify(rows)

    def test_missing_or_duplicate_transactions_are_ambiguous(self):
        rows = self.native_rows()
        rows[0]['event'] = 'other.event'
        with self.assertRaises(AssertionError):
            self.verify(rows)
        rows = self.native_rows()
        rows.append(dict(rows[0], sequence=5, t_ms=120))
        with self.assertRaises(AssertionError):
            self.verify(rows)

    def test_later_transaction_cannot_define_an_earlier_action(self):
        native = self.native_rows()
        rows = [dict(native[1], sequence=1), dict(native[0], sequence=2), native[2], native[3]]
        with self.assertRaises(AssertionError):
            self.verify(rows, start=1)

    def test_existing_invalid_transaction_blocks_legacy_direct_fallback(self):
        for mutation in (dict(provider='other'), dict(parameters=[])):
            rows = self.native_rows()
            rows[1]['muted'] = rows[3]['muted'] = True
            rows[0].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                self.verify(rows)

    def test_direct_value_must_agree_with_transaction_parameters(self):
        rows = self.native_rows()
        rows[1]['muted'] = False
        with self.assertRaises(AssertionError):
            self.verify(rows)
        rows[1]['muted'] = rows[3]['muted'] = True
        self.verify(rows)

    def test_unknown_older_fulfillment_or_echo_is_not_ignored(self):
        for echo in (False, True):
            older = self.event(1, 50, 'action.deadline' if echo else 'action.settled', kind='mute',
                               origin='muteEcho' if echo else 'application', fulfilled=True,
                               provider='p1', apiKind='callkit', callUUID='c1', actionID='older', transactionID='older-tx')
            rows = [older] + [dict(row, sequence=row['sequence'] + 1) for row in self.native_rows()]
            with self.subTest(echo=echo), self.assertRaises(AssertionError):
                self.verify(rows, start=3, end=5)
        rows[0]['muted'] = False
        self.verify(rows, start=3, end=5)

    def test_older_unconsumed_native_fulfillment_keeps_echo_ambiguous(self):
        native = self.native_rows()
        older_tx = dict(native[0], sequence=1, actionIDs=['older'], transactionID='older-tx')
        older = dict(native[1], sequence=2, t_ms=90, actionID='older', transactionID='older-tx')
        rows = [older_tx, older] + [dict(row, sequence=row['sequence'] + 2) for row in native]
        with self.assertRaises(AssertionError):
            self.verify(rows, start=4, end=6)

    def test_fully_consumed_older_native_echo_allows_a_new_pair(self):
        rows = self.native_rows()
        subsequent = copy.deepcopy(self.native_rows())
        for row in subsequent:
            row['sequence'] += 4
            row['t_ms'] += 1000
            row['transactionID'] += '-next'
            if 'actionID' in row: row['actionID'] += '-next'
            if 'actionIDs' in row: row['actionIDs'] = [value + '-next' for value in row['actionIDs']]
        self.verify(rows + subsequent, start=6, end=8)

    def test_candidate_echo_cannot_reuse_an_already_observed_action_id(self):
        rows = self.native_rows()
        rows += [dict(rows[0], sequence=5, t_ms=120, transactionID='t3', actionIDs=['m2']),
                 dict(rows[1], sequence=6, t_ms=125, transactionID='t3', actionID='m2'),
                 dict(rows[3], sequence=7, t_ms=130)]
        with self.assertRaises(AssertionError):
            self.verify(rows, start=6, end=7, milliseconds=5)

    def test_latest_fulfillment_cannot_reuse_an_already_settled_action_id(self):
        rows = self.native_rows()
        rows += [dict(rows[1], sequence=5, t_ms=125),
                 dict(rows[2], sequence=6, t_ms=129, transactionID='t3', actionIDs=['e2']),
                 dict(rows[3], sequence=7, t_ms=130, transactionID='t3', actionID='e2')]
        with self.assertRaises(AssertionError):
            self.verify(rows, start=5, end=7, milliseconds=5)

    def test_changed_value_cannot_hide_a_reused_echo_id(self):
        rows = self.native_rows()
        rows += [dict(rows[0], sequence=5, t_ms=120, transactionID='t3', actionIDs=['m2'], parameters=[dict(muted=False)]),
                 dict(rows[1], sequence=6, t_ms=125, transactionID='t3', actionID='m2'),
                 dict(rows[2], sequence=7, t_ms=139, transactionID='t4', parameters=[dict(muted=False)]),
                 dict(rows[3], sequence=8, t_ms=140, transactionID='t4')]
        with self.assertRaises(AssertionError):
            self.verify(rows, start=6, end=8)

    def test_historical_cross_value_echo_reuse_cannot_discharge_a_new_obligation(self):
        native = self.native_rows()
        for earlier_call, earlier_provider, earlier_api in [('c1', 'p1', 'callkit'), ('c2', 'p1', 'callkit'),
                                                          ('c1', 'p2', 'livecommunicationkit')]:
            rows = [dict(native[2], sequence=1, t_ms=0, transactionID='early-e1', parameters=[dict(muted=False)],
                         provider=earlier_provider, callUUIDs=[earlier_call]),
                    dict(native[3], sequence=2, t_ms=10, transactionID='early-e1',
                         provider=earlier_provider, callUUID=earlier_call, apiKind=earlier_api),
                    dict(native[0], sequence=3, t_ms=20), dict(native[1], sequence=4, t_ms=30),
                    dict(native[2], sequence=5, t_ms=40, transactionID='reused-e1'),
                    dict(native[3], sequence=6, t_ms=50, transactionID='reused-e1'),
                    dict(native[0], sequence=7, t_ms=60, transactionID='t3', actionIDs=['m2']),
                    dict(native[1], sequence=8, t_ms=70, transactionID='t3', actionID='m2'),
                    dict(native[2], sequence=9, t_ms=84, transactionID='t4', actionIDs=['e2']),
                    dict(native[3], sequence=10, t_ms=85, transactionID='t4', actionID='e2')]
            with self.subTest(call=earlier_call, provider=earlier_provider), self.assertRaises(AssertionError):
                self.verify(rows, start=8, end=10)

    def test_same_value_historical_duplicate_does_not_block_a_later_isolated_pair(self):
        rows = self.native_rows()
        rows.append(dict(rows[3], sequence=5, t_ms=116))
        subsequent = copy.deepcopy(self.native_rows())
        for row in subsequent:
            row['sequence'] += 5
            row['t_ms'] += 1000
            row['transactionID'] += '-next'
            if 'actionID' in row: row['actionID'] += '-next'
            if 'actionIDs' in row: row['actionIDs'] = [value + '-next' for value in row['actionIDs']]
        self.verify(rows + subsequent, start=7, end=9)


if __name__ == '__main__':
    unittest.main()
