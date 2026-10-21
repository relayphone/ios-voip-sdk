#!/usr/bin/env python3
"""Offline regression controls for device-derived acceptance expectations."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from conformance import ROOT, providers
from device_oracles import check_deadline, deadline_bands, d5_compositions, check_d5_composition
from summarize import EvidenceError, load


def write_provider_capture(directory, rows):
    """Bind a synthetic replay of the inv device trace; this is not a new run."""
    rows = copy.deepcopy(rows)
    identity = dict(runID='oracle-control', simulatorID='synthetic',
                    bundleID='dev.callkitsim.probe', pid=123)
    rows.insert(0, dict(event='launch', t_ms=0, **identity))
    revival = next(i for i, r in enumerate(rows)
                   if r['event'] == 'tap.didBegin' and r['t_ms'] > 60_000)
    rows.insert(revival, dict(event='revival.requested', t_ms=rows[revival]['t_ms']))
    for request in [r for r in rows if r['event'] == 'request']:
        route = next(r for r in rows[rows.index(request):]
                     if r['event'] == 'route' and r['label'] == request['label'])
        callback = dict(event='request.callback', label=request['label'],
                        result=route['result'], t_ms=route['t_ms'])
        rows.insert(rows.index(route), callback)
    engine = []
    for row in rows:
        if row['event'] == 'request':
            route = next(r for r in rows[rows.index(row):]
                         if r['event'] == 'route' and r['label'] == row['label'])
            engine.append(dict(event='request.accepted', transactionID=row['tx'],
                               actionIDs=[row['action']], error=0 if route['result'] == 'ok' else 2))
        elif row['event'] == 'tap.execute':
            request = next(r for r in rows if r['event'] == 'request' and r['action'] == row['actions'][0])
            engine.append(dict(event='transaction.delivered', transactionID=row['tx'],
                               requestID=request['tx'], actionIDs=row['actions'],
                               kinds=[request['kind']], origin='application'))
    engine.extend(dict(event='provider.invalidated') for _ in range(3))
    for index, row in enumerate(engine, 1):
        row.update(sequence=index, profile='ios-27.0', **identity)
    name = 'providers-inv'
    trace = directory / f'{name}.log'
    trace.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
    journal = directory / f'{name}.engine.jsonl'
    journal.write_text(''.join(json.dumps(row) + '\n' for row in engine))
    receipt = dict(schemaVersion=2, success=True, completed=True, terminateExitCode=0,
                   lastProbeEvent='done', appPID=123, launcherAppPID=123,
                   traceSHA256=hashlib.sha256(trace.read_bytes()).hexdigest(),
                   engineSHA256=hashlib.sha256(journal.read_bytes()).hexdigest(), **identity)
    (directory / f'{name}.receipt.json').write_text(json.dumps(receipt))


class OracleChecks(unittest.TestCase):
    def test_deadline_follows_device_reference(self):
        rows = load(ROOT / 'docs/research/callkit-simulator-probe/provider-routing',
                    '2026-10-21-iphone13-ios27-providers-inv')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_provider_capture(directory, rows)
            reference = directory / 'docs/research/callkit-simulator-probe/provider-routing'
            shutil.copytree(ROOT / 'docs/research/callkit-simulator-probe/provider-routing', reference)
            for path in reference.glob('*.jsonl'):
                changed = [json.loads(line) for line in path.read_text().splitlines()]
                for row in changed:
                    if row['event'] == 'tap.perform' and row['kind'] == 'CXEndCallAction':
                        row['timeoutIn'] = 9
                path.write_text(''.join(json.dumps(row) + '\n' for row in changed))
            # Select an alternate evidence directory at the filesystem boundary.
            with patch('conformance.ROOT', directory):
                with self.assertRaisesRegex(EvidenceError, 'deadline differs from device'):
                    providers(directory, 'inv')

    def test_deadline_pool_covers_late_device_delivery(self):
        rows = []
        for path in (ROOT / 'docs/research/callkit-simulator-probe/provider-routing').glob('*.jsonl'):
            rows.extend(json.loads(line) for line in path.read_text().splitlines())
        bands = deadline_bands(rows)
        self.assertEqual(bands['CXAnswerCallAction'], (58, 60.1))
        check_deadline(dict(kind='CXAnswerCallAction', timeoutIn=60), bands)

    def test_deadline_reference_rejects_missing_invalid_and_ambiguous_samples(self):
        measured = dict(event='tap.perform', kind='CXEndCallAction', timeoutIn=5)
        for source in ([], [dict(measured, timeoutIn=None)], [dict(measured, timeoutIn=float('nan'))],
                       [measured, dict(measured, timeoutIn=60)]):
            with self.subTest(source=source), self.assertRaises(EvidenceError):
                deadline_bands(source)
        with self.assertRaisesRegex(EvidenceError, 'missing device deadline'):
            check_deadline(dict(kind='CXAnswerCallAction', timeoutIn=60), deadline_bands([measured]))

    def test_missing_deadline_reference_fails_closed(self):
        rows = load(ROOT / 'docs/research/callkit-simulator-probe/provider-routing',
                    '2026-10-21-iphone13-ios27-providers-inv')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_provider_capture(directory, rows)
            reference = directory / 'docs/research/callkit-simulator-probe/provider-routing'
            shutil.copytree(ROOT / 'docs/research/callkit-simulator-probe/provider-routing', reference)
            (reference / '2026-10-21-iphone13-ios27-providers-ba.jsonl').unlink()
            with patch('conformance.ROOT', directory):
                with self.assertRaisesRegex(EvidenceError, 'require exactly one fresh'):
                    providers(directory, 'inv')

    def test_d5_compositions_from_successful_device_ui(self):
        rows = load(ROOT / 'docs/research/callkit-simulator-probe/device-system-ui',
                    '2026-10-20-iphone13-ui10-app')
        self.assertEqual(d5_compositions(rows), {
            'hold-and-accept': [dict(kind='CXSetHeldCallAction', role='active', onHold=True),
                                dict(kind='CXAnswerCallAction', role='waiting')],
            'end-and-accept': [dict(kind='CXEndCallAction', role='active'),
                               dict(kind='CXAnswerCallAction', role='waiting')],
            'decline': [dict(kind='CXEndCallAction', role='waiting')],
        })

    def test_d5_rejects_changed_order_target_hold_and_device_expectation(self):
        reference = load(ROOT / 'docs/research/callkit-simulator-probe/device-system-ui',
                         '2026-10-20-iphone13-ui10-app')
        expected = d5_compositions(reference)['hold-and-accept']
        action_ids = ['DD8AEE42-0000', 'ADDE2BA1-0000']
        roles = {'D73090BB': 'active', '451D1E2A': 'waiting'}
        engine = [dict(event='transaction.delivered', actionIDs=action_ids,
                       kinds=['CXSetHeldCallAction', 'CXAnswerCallAction'])]
        probe = [dict(event='provider.perform', id='DD8AEE42', call='D73090BB',
                      kind='CXSetHeldCallAction', onHold=True),
                 dict(event='provider.perform', id='ADDE2BA1', call='451D1E2A', kind='CXAnswerCallAction')]
        check_d5_composition('hold-and-accept', expected, action_ids, roles, engine, probe)
        for mutation in ('order', 'target', 'held', 'transaction', 'device-expectation'):
            changed_engine, changed_probe, changed_expected = copy.deepcopy((engine, probe, expected))
            if mutation == 'order': changed_probe.reverse()
            if mutation == 'target': changed_probe[0]['call'] = '451D1E2A'
            if mutation == 'held': changed_probe[0]['onHold'] = False
            if mutation == 'transaction': changed_engine[0]['actionIDs'] = action_ids[:1]
            if mutation == 'device-expectation':
                changed_reference = copy.deepcopy(reference)
                next(row for row in changed_reference if row.get('id') == 'DD8AEE42')['onHold'] = False
                changed_expected = d5_compositions(changed_reference)['hold-and-accept']
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                check_d5_composition('hold-and-accept', changed_expected, action_ids,
                                     roles, changed_engine, changed_probe)

    def test_d5_rejects_missing_or_ambiguous_reference(self):
        rows = load(ROOT / 'docs/research/callkit-simulator-probe/device-system-ui',
                    '2026-10-20-iphone13-ui10-app')
        snapshot = next(row for row in rows if row['event'] == 'observer.snapshot' and row['label'] == 'after-decline')
        for changed in ([], [row for row in rows if row is not snapshot],
                        rows + [snapshot], [row for row in rows if row['event'] != 'observer.callChanged'],
                        [row for row in rows if row['event'] != 'provider.executeTransaction']):
            with self.subTest(rows=len(changed)), self.assertRaises(EvidenceError):
                d5_compositions(changed)

    def test_d5_rejects_failed_device_ui_attempt(self):
        rows = load(ROOT / 'docs/research/callkit-simulator-probe/device-system-ui',
                    '2026-10-20-iphone13-ui7-app')
        with self.assertRaisesRegex(EvidenceError, 'unsuccessful device outcome'):
            d5_compositions(rows)

    def test_inv_cleanup_preserves_submitted_order_not_observer_iteration(self):
        rows = load(ROOT / 'docs/research/callkit-simulator-probe/provider-routing',
                    '2026-10-21-iphone13-ios27-providers-inv')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_provider_capture(directory, rows)
            self.assertTrue(providers(directory, 'inv')['success'])
            # Rebind a replay with the two complete cleanup transactions swapped.
            # Their internal execute/perform ordering and action identities stay valid.
            starts = [i for i, r in enumerate(rows)
                      if r['event'] == 'request' and r['label'] == 'cleanup']
            stop = next(i for i in range(starts[1], len(rows)) if rows[i]['event'] == 'tap.didReset')
            first, second = rows[starts[0]:starts[1]], rows[starts[1]:stop]
            swapped = copy.deepcopy(second + first)
            for row, timestamp in zip(swapped, [r['t_ms'] for r in first + second]):
                row['t_ms'] = timestamp
            rows[starts[0]:stop] = swapped
            write_provider_capture(directory, rows)
            self.assertTrue(providers(directory, 'inv')['success'])
            left, right = [row for row in rows if row['event'] == 'tap.perform']
            left['call'], right['call'] = right['call'], left['call']
            write_provider_capture(directory, rows)
            with self.assertRaisesRegex(EvidenceError, 'delivered request target/kind differs'):
                providers(directory, 'inv')
            left['call'], right['call'] = right['call'], left['call']
            # Reordering only deliveries against their own submitted request
            # sequence must still fail, even though the call inventory matches.
            left['action'], right['action'] = right['action'], left['action']
            left['call'], right['call'] = right['call'], left['call']
            write_provider_capture(directory, rows)
            with self.assertRaisesRegex(EvidenceError, 'action order/routing differs'):
                providers(directory, 'inv')


if __name__ == '__main__':
    unittest.main()
