#!/usr/bin/env python3
"""Offline device replay controls; synthetic replays are not native LCK runs."""
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from device_oracles import deadline_bands
from lck_conformance import CASES, ROOT, compare, validate
from summarize import EvidenceError, load


def references():
    directory = ROOT / 'docs/research/callkit-simulator-probe/livecommunicationkit'
    return {case: load(directory, '2026-10-21-iphone13-ios27-lck-' + case) for case in CASES}


def write_capture(directory, case, source):
    """Bind a synthetic device replay; no native simulator execution is implied."""
    identity = dict(runID='synthetic-lck-replay', simulatorID='synthetic', bundleID='dev.callkitsim.probe', pid=1234)
    package = directory / 'runtime-dist'
    (package / 'profiles').mkdir(parents=True, exist_ok=True)
    runtime, profile = package / 'CKSimRuntime.dylib', package / 'profiles/ios-27.0.json'
    runtime.write_bytes(b'synthetic LCK control runtime')
    profile.write_bytes(b'synthetic LCK control profile')
    manifest = dict(schemaVersion=1, profileID='ios-27.0', runID=identity['runID'], simulatorID=identity['simulatorID'],
                    probeSHA256=hashlib.sha256(b'synthetic LCK control probe').hexdigest(),
                    runtimeSHA256=hashlib.sha256(runtime.read_bytes()).hexdigest(),
                    profileSHA256=hashlib.sha256(profile.read_bytes()).hexdigest())
    (directory / 'manifest.json').write_text(json.dumps(manifest))
    rows = [dict(event='launch', t_ms=0, main=True, mode='lck', injected=True, traceVersion=2, **identity),
            dict(event='runtime.identity', t_ms=0, main=True, version='0.1.0',
                 **{key: manifest[key] for key in ('probeSHA256', 'runtimeSHA256', 'profileSHA256')}), *copy.deepcopy(source)]
    name = 'lck-' + case
    path = directory / (name + '.log')
    path.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
    engine = [dict(event='runtime.installed'), dict(event='transaction.delivered', transactionID='synthetic-delivery',
              actionIDs=['synthetic-action'], kinds=['CXStartCallAction'], origin='system', requestID='system')]
    for index, row in enumerate(engine, 1): row.update(sequence=index, t_ms=index, profile='ios-27.0', **identity)
    journal = directory / (name + '.engine.jsonl')
    journal.write_text(''.join(json.dumps(row) + '\n' for row in engine))
    receipt = dict(schemaVersion=2, success=True, completed=True, terminateExitCode=0, lastProbeEvent='done',
                   appPID=1234, launcherAppPID=1234, traceSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   engineSHA256=hashlib.sha256(journal.read_bytes()).hexdigest(), **identity)
    (directory / (name + '.receipt.json')).write_text(json.dumps(receipt))


class LCKChecks(unittest.TestCase):
    def setUp(self):
        self.sources = references()
        self.bands = deadline_bands([row for rows in self.sources.values()
                                    for row in rows if row['event'] == 'lck.perform'])

    def test_device_replays_and_changed_action_receiver(self):
        for case, reference in self.sources.items():
            with self.subTest(case=case):
                self.assertTrue(compare(copy.deepcopy(reference), reference, self.bands)['success'])
                changed = copy.deepcopy(reference)
                next(row for row in changed if row['event'] in ('lck.perform', 'lck.cx.perform'))['p'] = 'WRONG'
                with self.assertRaises(EvidenceError):
                    compare(changed, reference, self.bands)

    def test_fresh_uuids_preserve_semantic_journeys(self):
        mapping = {}
        def renamed(value):
            if isinstance(value, dict): return {key: renamed(item) for key, item in value.items()}
            if isinstance(value, list): return [renamed(item) for item in value]
            if isinstance(value, str) and re.fullmatch('[A-F0-9]{8}', value):
                if value not in mapping: mapping[value] = f'{len(mapping) + 1:08X}'
                return mapping[value]
            return value
        for case, reference in self.sources.items():
            with self.subTest(case=case):
                self.assertTrue(compare(renamed(reference), reference, self.bands)['success'])

    def test_deadlines_queues_states_snapshots_audio_and_outcomes_reject_tampering(self):
        reference = self.sources['basic']
        mutations = {
            'deadline': lambda rows: next(row for row in rows if row['event'] == 'lck.perform').update(timeoutIn=5),
            'queue': lambda rows: next(row for row in rows if row['event'] == 'lck.perform').update(main=False),
            'conversation-state': lambda rows: next(row for row in rows if row['event'] == 'lck.conversationChanged').update(state='left'),
            'observer-state': lambda rows: next(row for row in rows if row['event'] == 'observer.callChanged').update(outgoing=False),
            'snapshot-state': lambda rows: next(row for row in rows if row['event'] == 'lck.snapshot')['conversations'][0].update(state='idle'),
            'snapshot-pending': lambda rows: next(row for row in rows if row['event'] == 'lck.snapshot').update(pending=1),
            'final-state': lambda rows: [row for row in rows if row['event'] == 'lck.snapshot'][-1]['conversations'].append(dict(uuid='21569324', state='idle')),
            'audio-owner': lambda rows: next(row for row in rows if row['event'] == 'lck.didActivate').update(p='WRONG'),
            'request-result': lambda rows: next(row for row in rows if row['event'] == 'lck.requestCompleted').update(result='failed'),
            'report-result': lambda rows: next(row for row in rows if row['event'] == 'lck.reported').update(result='failed'),
            'missing-connected-report': lambda rows: rows.remove(next(row for row in rows if row['event'] == 'lck.reported.connected')),
            'missing-remote-end-report': lambda rows: rows.remove(next(row for row in rows if row['event'] == 'lck.reportedEnded')),
        }
        for label, mutation in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(reference)
                mutation(changed)
                with self.assertRaises(EvidenceError):
                    compare(changed, reference, self.bands)

    def test_bound_capture_requires_receipts_and_loaded_image_identity(self):
        for case, source in self.sources.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                write_capture(directory, case, source)
                self.assertTrue(validate(directory, case)['success'])
                path = directory / ('lck-' + case + '.log')
                rows = [json.loads(line.split('PROBE ', 1)[1]) for line in path.read_text().splitlines()]
                next(row for row in rows if row['event'] == 'runtime.identity')['runtimeSHA256'] = '0' * 64
                path.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
                receipt_path = directory / ('lck-' + case + '.receipt.json')
                receipt = json.loads(receipt_path.read_text())
                receipt['traceSHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
                receipt_path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(EvidenceError, 'loaded runtimeSHA256 differs'):
                    validate(directory, case)

    def test_echo_action_values_identity_and_target_are_checked(self):
        reference = self.sources['basic']
        for mutation in ('echo', 'muted', 'paused', 'target', 'request-id', 'action-order', 'action-state'):
            with self.subTest(mutation=mutation):
                rows = copy.deepcopy(reference)
                actions = [row for row in rows if row['event'] == 'lck.perform']
                if mutation == 'echo': rows.remove(actions[4])
                if mutation == 'muted': actions[3]['muted'] = False
                if mutation == 'paused': actions[6]['paused'] = False
                if mutation == 'target': actions[2]['conversation'] = actions[0]['conversation']
                if mutation == 'request-id': next(row for row in rows if row['event'] == 'lck.request')['action'] = 'BAD-ID'
                if mutation == 'action-state': actions[0]['state'] = 'complete'
                if mutation == 'action-order':
                    left, right = rows.index(actions[3]), rows.index(actions[4])
                    rows[left], rows[right] = rows[right], rows[left]
                with self.assertRaises(EvidenceError): compare(rows, reference, self.bands)

    def test_incoming_report_order_and_audio_journey_binding(self):
        reference = self.sources['basic']
        rows = copy.deepcopy(reference)
        report = next(row for row in rows if row['event'] == 'lck.reported' and row['label'] == 'in-incoming')
        idle = next(row for row in rows if row['event'] == 'lck.conversationChanged' and row['uuid'] == report['conversation'])
        rows.remove(idle)
        rows.insert(rows.index(report) + 1, idle)
        with self.assertRaisesRegex(EvidenceError, 'did not precede report return'):
            compare(rows, reference, self.bands)
        rows = copy.deepcopy(reference)
        audio = next(row for row in rows if row['event'] == 'lck.didActivate')
        rows.remove(audio)
        rows.insert(1, audio)
        with self.assertRaisesRegex(EvidenceError, 'audio differs'):
            compare(rows, reference, self.bands)

    def test_two_manager_state_interleaving_is_not_a_contract(self):
        reference = self.sources['two-managers']
        rows = copy.deepcopy(reference)
        for index in range(len(rows) - 1):
            left, right = rows[index:index + 2]
            if left['event'] == right['event'] == 'lck.conversationChanged' and left['p'] == 'L1' and right['p'] == 'L2':
                rows[index], rows[index + 1] = right, left
        self.assertTrue(compare(rows, reference, self.bands)['success'])

    def test_r3_teardown_is_explicitly_outside_journey_scope(self):
        reference = self.sources['basic']
        rows = copy.deepcopy(reference)
        rows.insert(-1, dict(event='lck.didReset', p='L', main=True, t_ms=16000))
        result = compare(rows, reference, self.bands)
        self.assertTrue(result['success'])
        self.assertIn('R3 teardown callbacks deferred', result['lifecycle'])
        self.assertEqual(result['afterJourneyEvents']['lck.didReset'], 1)

    def test_missing_empty_and_unbound_capture_evidence_fails(self):
        for mutation in ('missing-receipt', 'empty-journal', 'journal-pid', 'trace-hash', 'incomplete-receipt'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                write_capture(directory, 'basic', self.sources['basic'])
                receipt_path = directory / 'lck-basic.receipt.json'
                receipt = json.loads(receipt_path.read_text())
                journal = directory / 'lck-basic.engine.jsonl'
                if mutation == 'missing-receipt': receipt_path.unlink()
                if mutation == 'empty-journal': journal.write_text('')
                if mutation == 'journal-pid':
                    rows = [json.loads(line) for line in journal.read_text().splitlines()]
                    rows[0]['pid'] = 9999
                    journal.write_text(''.join(json.dumps(row) + '\n' for row in rows))
                    receipt['engineSHA256'] = hashlib.sha256(journal.read_bytes()).hexdigest()
                if mutation == 'trace-hash': receipt['traceSHA256'] = '0' * 64
                if mutation == 'incomplete-receipt': receipt['completed'] = False
                if mutation != 'missing-receipt': receipt_path.write_text(json.dumps(receipt))
                with self.assertRaises((EvidenceError, OSError)): validate(directory, 'basic')

    def test_missing_or_ambiguous_device_reference_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_capture(directory, 'basic', self.sources['basic'])
            with patch('lck_conformance.ROOT', directory):
                with self.assertRaises(EvidenceError): validate(directory, 'basic')
        reference = self.sources['basic']
        with self.assertRaises(EvidenceError): compare(copy.deepcopy(reference), [], self.bands)
        duplicate = copy.deepcopy(reference)
        duplicate.insert(-1, copy.deepcopy(next(row for row in reference if row['event'] == 'lck.snapshot')))
        with self.assertRaises(EvidenceError): compare(duplicate, reference, self.bands)

    def test_cli_selected_case_and_missing_default_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_capture(directory, 'basic', self.sources['basic'])
            command = [sys.executable, str(ROOT / 'discovery/lck_conformance.py'), str(directory)]
            selected = subprocess.run([*command, '--case', 'basic'], capture_output=True, text=True, timeout=30)
            self.assertEqual(selected.returncode, 0, selected.stdout + selected.stderr)
            self.assertEqual(set(json.loads(selected.stdout)), {'basic'})
            missing = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(missing.returncode, 0)
            result = json.loads(missing.stdout)
            self.assertTrue(result['basic']['success'])
            self.assertFalse(result['cx-after']['success'])

    def test_lck_deadline_expectations_follow_device_samples(self):
        reference = self.sources['basic']
        changed = copy.deepcopy(reference)
        for row in changed:
            if row['event'] == 'lck.perform': row['timeoutIn'] = 40
        bands = deadline_bands(changed)
        with self.assertRaisesRegex(EvidenceError, 'deadline differs from device'):
            compare(copy.deepcopy(reference), reference, bands)


if __name__ == '__main__':
    unittest.main()
