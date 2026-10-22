#!/usr/bin/env python3
"""Synthetic audio lifecycle positives/tampers; never claims native delivery."""
import unittest

from sdk_m2_audio_lifecycle import validate_lifecycle
from summarize import EvidenceError

CALL = 'E715ACF2-A7C1-4D74-8BD9-EAFA47693255'


def lifecycle_engine():
    rows = [dict(event='report.incoming', callUUID=CALL),
            dict(event='call.changed', uuid=CALL, outgoing=False, connected=False, held=False, ended=False)]
    kinds = ['CXAnswerCallAction', 'CXSetHeldCallAction', 'CXSetHeldCallAction', 'CXEndCallAction']
    for index, kind in enumerate(kinds):
        action = '00000000-0000-0000-0000-' + str(index + 1).zfill(12)
        rows += [dict(event='transaction.delivered', kinds=[kind], actionIDs=[action]),
                 dict(event='action.settled', actionID=action, fulfilled=True),
                 dict(event='call.changed', uuid=CALL, outgoing=False, connected=True,
                      held=index == 1, ended=index == 3),
                 dict(event='audio.' + ('activated' if index % 2 == 0 else 'deactivated'))]
    return rows


def lifecycle_rows(path):
    """Raw synthetic case events; caller adds launch, identity and sequence fields."""
    modern = path == 'modern'
    rows = [dict(event='lifecycle.path', path=path,
                 evidence='native-session-lifecycle' if modern else 'native-synthetic-legacy-wiring'),
            dict(event='lifecycle.adapterAuthorization', authorized=False, phase='initial')]
    def add(event, **fields):
        rows.append(dict(event='lifecycle.' + event, **fields))
    def pair(phase, kind, before, after):
        fields = dict(kind=kind, phase=phase, hasSource=modern and kind == 'inactive',
            source=1 if modern and kind == 'inactive' else 0,
            hasInterruptionReason=not modern and kind == 'inactive', interruptionReason=0,
            shouldResume=kind == 'recommended')
        names = dict(active='AVAudioSessionDidBecomeActiveNotification',
            inactive='AVAudioSessionDidBecomeInactiveNotification', recommended='AVAudioSessionResumptionRecommendationNotification')
        add('observed', **fields, observerMain=True,
            notificationName=names[kind] if modern else 'AVAudioSessionInterruptionNotification',
            contextClass='PrivateDeactivationContextSubclass' if modern and kind == 'inactive' else '')
        if kind == 'inactive': add('adapterAuthorization', authorized=False, phase=phase)
        add('consumed', **fields, authorizedBefore=before, authorizedAfter=after)
    def delegate(phase, active, count):
        add('adapterAuthorization', authorized=active, phase=phase)
        add('lckDelegate', active=active, count=count, phase=phase)
    add('handler', kind='join', phase='answer')
    if modern: pair('answer', 'active', False, False)
    delegate('answer', True, 1)
    if not modern:
        add('syntheticPost', kind='inactive', phase='legacy-began')
        pair('legacy-began', 'inactive', True, False)
        add('syntheticPost', kind='recommended', phase='legacy-ended')
        pair('legacy-ended', 'recommended', False, False)
    add('handler', kind='hold', phase='hold')
    if modern: pair('hold', 'inactive', True, False)
    delegate('hold', False, 1)
    add('handler', kind='hold', phase='resume')
    delegate('resume', True, 2)
    if modern: pair('resume', 'active', True, True)
    add('handler', kind='end', phase='end')
    delegate('end', False, 2)
    if modern:
        pair('end', 'inactive', False, False)
        add('noConversations', count=0, phase='end')
        add('fixtureSessionRequest', active=True, phase='fixture-app-activation')
        pair('fixture-app-activation', 'active', False, False)
        add('fixtureSessionRequest', active=False, phase='fixture-app-deactivation')
        pair('fixture-app-deactivation', 'inactive', False, False)
    count = 6 if modern else 2
    add('completed', authorized=False, activations=2, deactivations=2, observedCount=count, consumedCount=count,
        phase='fixture-app-deactivation' if modern else 'end')
    return rows


class LifecycleControls(unittest.TestCase):
    def validate(self, rows, path='modern', engine=None):
        return validate_lifecycle(rows, lifecycle_engine() if engine is None else engine, path)

    def reject(self, change, path='modern'):
        rows, engine = lifecycle_rows(path), lifecycle_engine()
        change(rows, engine)
        with self.assertRaises(EvidenceError): self.validate(rows, path, engine)

    @staticmethod
    def row(rows, event, phase=None):
        return next(row for row in rows if row['event'] == 'lifecycle.' + event and
                    (phase is None or row.get('phase') == phase))

    def test_positive_both_paths_and_explicit_scope(self):
        for path, count in [('modern', 6), ('legacy', 2)]:
            result = self.validate(lifecycle_rows(path), path)
            self.assertEqual(result['observedCount'], count)
            self.assertFalse(result['systemInterruptionMeasured'])

    def test_lck_and_notification_order_are_independent(self):
        rows = lifecycle_rows('modern')
        # Put the real answer callback before notification delivery. Active
        # retains its previous authorization rather than creating a new one.
        callback = self.row(rows, 'lckDelegate', 'answer')
        authorization = next(row for row in rows if row['event'] == 'lifecycle.adapterAuthorization' and row.get('authorized') is True)
        rows.remove(callback); rows.remove(authorization)
        at = rows.index(self.row(rows, 'observed', 'answer'))
        rows[at:at] = [authorization, callback]
        self.row(rows, 'consumed', 'answer').update(authorizedBefore=True, authorizedAfter=True)
        self.assertTrue(self.validate(rows)['success'])

    def test_modern_recommendation_remains_advisory(self):
        rows = lifecycle_rows('modern')
        fields = dict(kind='recommended', phase='fixture-app-activation', hasSource=False, source=0,
                      hasInterruptionReason=False, interruptionReason=0, shouldResume=True)
        observed = dict(event='lifecycle.observed', **fields, observerMain=True,
            notificationName='AVAudioSessionResumptionRecommendationNotification',
            contextClass='PrivateResumptionContextSubclass')
        consumed = dict(event='lifecycle.consumed', **fields, authorizedBefore=False, authorizedAfter=False)
        at = rows.index(self.row(rows, 'fixtureSessionRequest', 'fixture-app-deactivation'))
        rows[at:at] = [observed, consumed]
        self.row(rows, 'completed').update(observedCount=7, consumedCount=7)
        self.assertTrue(self.validate(rows)['success'])
        consumed['authorizedAfter'] = True
        with self.assertRaises(EvidenceError): self.validate(rows)

    def test_missing_observation_even_rebound_counts_is_rejected(self):
        def change(rows, engine):
            rows.remove(self.row(rows, 'observed', 'hold')); rows.remove(self.row(rows, 'consumed', 'hold'))
            self.row(rows, 'completed').update(observedCount=5, consumedCount=5)
        self.reject(change)

    def test_scalar_mapping_main_and_boolean_coercions_are_rejected(self):
        changes = [('source', 0), ('hasSource', 1), ('hasInterruptionReason', 0), ('interruptionReason', False),
                   ('shouldResume', 0), ('observerMain', 1), ('notificationName', 'AVAudioSessionInterruptionNotification')]
        for key, value in changes:
            with self.subTest(key=key):
                self.reject(lambda rows, engine: self.row(rows, 'observed', 'hold').update({key: value}))
        self.reject(lambda rows, engine: self.row(rows, 'consumed', 'answer').update(authorizedBefore=0))

    def test_wrong_context_or_rebound_system_source_is_rejected(self):
        self.reject(lambda rows, engine: self.row(rows, 'observed', 'hold').update(contextClass=''))
        def change(rows, engine):
            for event in ('observed', 'consumed'):
                self.row(rows, event, 'hold').update(source=0, hasInterruptionReason=True, interruptionReason=1)
        self.reject(change)

    def test_advisory_or_fixture_authorization_gain_is_rejected(self):
        self.reject(lambda rows, engine: self.row(rows, 'consumed', 'answer').update(authorizedAfter=True))
        self.reject(lambda rows, engine: self.row(rows, 'consumed', 'fixture-app-activation').update(
            authorizedBefore=True, authorizedAfter=True))
        self.reject(lambda rows, engine: self.row(rows, 'consumed', 'legacy-ended').update(authorizedAfter=True), 'legacy')

    def test_fixture_scope_and_path_relabeling_are_rejected(self):
        self.reject(lambda rows, engine: self.row(rows, 'noConversations').update(count=1))
        self.reject(lambda rows, engine: self.row(rows, 'fixtureSessionRequest').update(active=False))
        self.reject(lambda rows, engine: self.row(rows, 'path').update(evidence='native-system-interruption'))
        with self.assertRaises(EvidenceError): self.validate(lifecycle_rows('legacy'), 'modern')

    def test_delegates_authorization_counts_and_late_events_are_rejected(self):
        self.reject(lambda rows, engine: self.row(rows, 'lckDelegate', 'hold').update(count=True))
        self.reject(lambda rows, engine: self.row(rows, 'completed').update(observedCount=True))
        self.reject(lambda rows, engine: rows.append(dict(event='lifecycle.adapterAuthorization', authorized=True, phase='end')))
        self.reject(lambda rows, engine: self.row(rows, 'adapterAuthorization').update(authorized=True))

    def test_inactive_must_revoke_adapter_before_consumption(self):
        def change(rows, engine):
            raw = self.row(rows, 'observed', 'hold')
            decoded = self.row(rows, 'consumed', 'hold')
            authorization = next(row for row in rows[rows.index(raw):rows.index(decoded)]
                                 if row['event'] == 'lifecycle.adapterAuthorization')
            rows.remove(authorization)
        self.reject(change)

    def test_engine_transactions_hold_values_and_audio_inventory_are_rejected(self):
        def wrong_hold(rows, engine):
            for row in engine:
                if row['event'] == 'call.changed' and row['held'] is True: row['held'] = False
        self.reject(wrong_hold)
        self.reject(lambda rows, engine: next(row for row in engine if row['event'] == 'transaction.delivered').update(kinds=['CXStartCallAction']))
        self.reject(lambda rows, engine: next(row for row in engine if row['event'] == 'action.settled').update(fulfilled=1))
        self.reject(lambda rows, engine: engine.remove(next(row for row in engine if row['event'] == 'audio.deactivated')))
        self.reject(lambda rows, engine: next(row for row in engine if row['event'] == 'call.changed').update(uuid='other-call'))

    def test_legacy_synthetic_and_reason_are_required(self):
        self.reject(lambda rows, engine: rows.remove(self.row(rows, 'syntheticPost', 'legacy-ended')), 'legacy')
        def wrong_reason(rows, engine):
            for event in ('observed', 'consumed'):
                self.row(rows, event, 'legacy-began').update(hasInterruptionReason=False)
        self.reject(wrong_reason, 'legacy')


if __name__ == '__main__':
    unittest.main()
