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

from device_oracles import deadline_bands, DEADLINE_ROUNDING_SECONDS
from lck_conformance import CASES, ROOT, PROVIDER_APIS, compare, provider_apis, validate
from summarize import EvidenceError, load


def references():
    directory = ROOT / 'docs/research/callkit-simulator-probe/livecommunicationkit'
    return {case: load(directory, '2026-10-21-iphone13-ios27-lck-' + case) for case in CASES}


def write_capture(directory, case, source, edit=None):
    """Bind a synthetic device replay; no native simulator execution is implied."""
    identity = dict(runID='synthetic-lck-replay', simulatorID='synthetic', bundleID='dev.callkitsim.probe', pid=1234)
    package = directory / 'runtime-dist'
    (package / 'profiles').mkdir(parents=True, exist_ok=True)
    runtime, profile = package / 'CKSimRuntime.dylib', package / 'profiles/ios-27.0.json'
    runtime.write_bytes(b'synthetic LCK control runtime')
    profile.write_bytes(b'synthetic LCK control profile')
    version = (ROOT / 'VERSION').read_text().strip()
    (package / 'build-info.json').write_text(json.dumps(dict(version=version)))
    runtime_id = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
    (directory / 'runtimes.json').write_text(json.dumps(dict(runtimes=[dict(
        identifier=runtime_id, platform='iOS', version='26.5', buildversion='23F77', isAvailable=True)])))
    (directory / 'compiler-version.txt').write_text('Xcode 26.3\nBuild version 17C100\n')
    manifest = dict(schemaVersion=1, runtimeVersion=version, profileID='ios-27.0', runID=identity['runID'], simulatorID=identity['simulatorID'],
                    simulatorRuntimeID=runtime_id, simulatorOSVersion='26.5', simulatorOSBuildVersion='23F77',
                    compilerXcodeVersion='26.3', compilerXcodeBuildVersion='17C100',
                    probeSHA256=hashlib.sha256(b'synthetic LCK control probe').hexdigest(),
                    runtimeSHA256=hashlib.sha256(runtime.read_bytes()).hexdigest(),
                    profileSHA256=hashlib.sha256(profile.read_bytes()).hexdigest())
    (directory / 'manifest.json').write_text(json.dumps(manifest))
    rows = [dict(event='launch', t_ms=0, main=True, mode='lck', injected=True, traceVersion=2, **identity),
            dict(event='runtime.identity', t_ms=0, main=True, version=version,
                 **{key: manifest[key] for key in ('probeSHA256', 'runtimeSHA256', 'profileSHA256')}), *copy.deepcopy(source)]
    # Synthetic execution metadata deliberately differs from the measured
    # iOS 27.0 behavior reference; this is not a native iOS 26.5 LCK run.
    next(row for row in rows if row['event'] == 'lck.start').update(os='26.5', build='23F77', simulator='synthetic')
    name = 'lck-' + case
    path = directory / (name + '.log')
    engine = [dict(event='runtime.installed'), dict(event='transaction.delivered', transactionID='synthetic-delivery',
              actionIDs=['synthetic-action'], kinds=['CXStartCallAction'], origin='system', requestID='system')]
    for index, api in enumerate(PROVIDER_APIS[case]):
        engine += [dict(event='provider.created', provider=f'synthetic-provider-{index}'),
                   dict(event='provider.apiKind', provider=f'synthetic-provider-{index}', apiKind=api, delegatePresent=True)]
    bands = deadline_bands([row for source in references().values() for row in source if row['event'] == 'lck.perform'])
    public_deadlines = {}
    for row in rows:
        if row['event'] not in ('lck.request', 'lck.perform'): continue
        sampled = 1_800_000_000_000 + row['t_ms']
        duration_ms = round((bands[row['kind']][1] - DEADLINE_ROUNDING_SECONDS) * 1000)
        deadline = public_deadlines.setdefault(row['action'], sampled + duration_ms)
        row.update(actionID=row['action'] + '-0000-4000-8000-000000000000', sampledAtMS=sampled,
                   deadlineMS=deadline, timeoutIn=round((deadline - sampled) / 1000, 1))
        if row['event'] == 'lck.perform':
            engine.append(dict(event='action.deadline', actionID=row['actionID'], apiKind='livecommunicationkit',
                               issuedAtMS=deadline - duration_ms, deadlineMS=deadline,
                               deadlineSeconds=duration_ms / 1000, expirySeconds=duration_ms / 1000))
    if edit: edit(rows, engine)
    path.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
    for index, row in enumerate(engine, 1): row.update(sequence=index, t_ms=index, profile='ios-27.0', **identity)
    journal = directory / (name + '.engine.jsonl')
    journal.write_text(''.join(json.dumps(row) + '\n' for row in engine))
    receipt = dict(schemaVersion=2, scenario=name, success=True, completed=True, launchExitCode=0, terminateExitCode=0, lastProbeEvent='done',
                   appPID=1234, launcherAppPID=1234, traceSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   engineSHA256=hashlib.sha256(journal.read_bytes()).hexdigest(), **identity)
    (directory / (name + '.receipt.json')).write_text(json.dumps(receipt))


class LCKChecks(unittest.TestCase):
    def setUp(self):
        self.sources = references()
        self.bands = deadline_bands([row for rows in self.sources.values()
                                    for row in rows if row['event'] == 'lck.perform'])

    def test_provider_api_classification_is_bound_and_not_class_name_inferred(self):
        rows = [dict(event='provider.created', provider='p'),
                dict(event='provider.apiKind', provider='p', apiKind='livecommunicationkit', delegatePresent=True)]
        self.assertEqual(provider_apis(rows, 'basic'), ['livecommunicationkit'])
        for mutation in ('missing', 'callkit', 'unbound', 'unknown', 'no-delegate', 'changed'):
            changed = copy.deepcopy(rows)
            if mutation == 'missing': changed.pop()
            if mutation == 'callkit': changed[-1]['apiKind'] = 'callkit'
            if mutation == 'unbound': changed[-1]['provider'] = 'other'
            if mutation == 'unknown': changed[-1]['apiKind'] = 'name-looks-like-LCK'
            if mutation == 'no-delegate': changed[-1]['delegatePresent'] = False
            if mutation == 'changed': changed.append(dict(event='provider.apiKind', provider='p', apiKind='callkit', delegatePresent=True))
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError): provider_apis(changed, 'basic')

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
                result = validate(directory, case)
                self.assertTrue(result['success'])
                self.assertEqual(result['environment']['simulatorOS']['version'], '26.5')
                self.assertEqual(result['environment']['behaviorProfileID'], 'ios-27.0')
                self.assertEqual(result['referenceOS'], '27.0')
                self.assertEqual(result['runtimeVersion'], (ROOT / 'VERSION').read_text().strip())
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

    def test_two_manager_missing_joined_state_still_fails(self):
        reference = self.sources['two-managers']
        for manager in ('L1', 'L2'):
            with self.subTest(manager=manager):
                rows = copy.deepcopy(reference)
                joined = next(row for row in rows if row['event'] == 'lck.conversationChanged' and
                              row['p'] == manager and row['state'] == 'joined')
                rows.remove(joined)
                with self.assertRaisesRegex(EvidenceError, 'managerStates differs'):
                    compare(rows, reference, self.bands)

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

    def test_consistently_deleted_identity_and_protocol_fields_fail(self):
        for field in ('pid', 'runID', 'simulatorID', 'bundleID', 'traceVersion', 'scenario', 'launch-status'):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                write_capture(directory, 'basic', self.sources['basic'])
                trace_path, engine_path = directory / 'lck-basic.log', directory / 'lck-basic.engine.jsonl'
                receipt_path, manifest_path = directory / 'lck-basic.receipt.json', directory / 'manifest.json'
                rows = [json.loads(line.split('PROBE ', 1)[1]) for line in trace_path.read_text().splitlines()]
                engine = [json.loads(line) for line in engine_path.read_text().splitlines()]
                receipt, manifest = json.loads(receipt_path.read_text()), json.loads(manifest_path.read_text())
                if field in ('pid', 'runID', 'simulatorID', 'bundleID'):
                    next(row for row in rows if row['event'] == 'launch').pop(field)
                    for row in engine: row.pop(field, None)
                    receipt.pop(field, None)
                    manifest.pop(field, None)
                    if field == 'pid':
                        receipt.pop('appPID')
                        receipt.pop('launcherAppPID')
                if field == 'traceVersion': next(row for row in rows if row['event'] == 'launch').pop(field)
                if field == 'scenario': receipt.pop(field)
                if field == 'launch-status': receipt['launchExitCode'] = 99
                trace_path.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
                engine_path.write_text(''.join(json.dumps(row) + '\n' for row in engine))
                receipt.update(traceSHA256=hashlib.sha256(trace_path.read_bytes()).hexdigest(),
                               engineSHA256=hashlib.sha256(engine_path.read_bytes()).hexdigest())
                receipt_path.write_text(json.dumps(receipt))
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaises(EvidenceError): validate(directory, 'basic')

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

    def native_deadline_capture(self, edit=None, case='two-managers'):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_capture(directory, case, self.sources[case], edit)
            return validate(directory, case)

    def test_native_delayed_callback_keeps_the_issuance_deadline(self):
        def delayed(rows, engine):
            row = next(r for r in rows if r['event'] == 'lck.perform' and r['kind'] == 'StartConversationAction')
            row['sampledAtMS'] += 3000
            row['timeoutIn'] -= 3
        self.assertTrue(self.native_deadline_capture(delayed)['success'])

    def test_native_request_and_callback_dates_need_not_be_identical(self):
        def measured_offset(rows, engine):
            request = next(r for r in rows if r['event'] == 'lck.request')
            callback = next(r for r in rows if r['event'] == 'lck.perform' and r['action'] == request['action'])
            issued = next(r for r in engine if r['event'] == 'action.deadline' and r['actionID'] == request['actionID'])
            # Native CI observed request -> issuance +14 ms, callback date +5 ms,
            # with the callback sampled another 18 ms after issuance.
            issued.update(issuedAtMS=request['sampledAtMS'] + 14, deadlineMS=request['deadlineMS'] + 14)
            callback.update(deadlineMS=issued['deadlineMS'] + 5,
                            sampledAtMS=issued['issuedAtMS'] + 18, timeoutIn=30.0)
        self.assertTrue(self.native_deadline_capture(measured_offset)['success'])

    def test_native_delayed_callback_cannot_reset_its_deadline(self):
        def reset(rows, engine):
            row = next(r for r in rows if r['event'] == 'lck.perform')
            row['sampledAtMS'] += 3000
            row['deadlineMS'] += 3000
        with self.assertRaisesRegex(EvidenceError, 'bound engine deadline'):
            self.native_deadline_capture(reset)

    def test_native_public_and_engine_deadlines_must_agree_at_trace_precision(self):
        for delta in (-1000, 1000):
            def move_engine(rows, engine, delta=delta):
                row = next(r for r in engine if r['event'] == 'action.deadline')
                row['issuedAtMS'] += delta
                row['deadlineMS'] += delta
            with self.subTest(delta=delta), self.assertRaises(EvidenceError):
                self.native_deadline_capture(move_engine)

    def test_native_absolute_sample_distinguishes_rounding_from_expiry(self):
        def nearly_expired(rows, engine):
            row = next(r for r in rows if r['event'] == 'lck.perform')
            row.update(sampledAtMS=row['deadlineMS'] - 40, timeoutIn=0.0)
        self.assertTrue(self.native_deadline_capture(nearly_expired)['success'])

    def test_native_remaining_sample_rejects_adjacent_or_unrounded_values(self):
        for delta in (-0.1, -0.09):
            def tamper(rows, engine, delta=delta):
                row = next(r for r in rows if r['event'] == 'lck.perform')
                row['timeoutIn'] += delta
            with self.subTest(delta=delta), self.assertRaises(EvidenceError):
                self.native_deadline_capture(tamper)

    def test_unsolicited_native_actions_keep_the_device_remaining_band(self):
        def delayed_system(rows, engine):
            requested = {r['action'] for r in rows if r['event'] == 'lck.request'}
            row = next(r for r in rows if r['event'] == 'lck.perform' and r['action'] not in requested)
            row['sampledAtMS'] += 3000
            row['timeoutIn'] -= 3
        with self.assertRaisesRegex(EvidenceError, 'deadline differs from device'):
            self.native_deadline_capture(delayed_system, case='basic')

    def test_native_deadlines_reject_missing_or_unbound_identity_and_anchors(self):
        def mutate(field, value, native=False, remove=False, request=False):
            def edit(rows, engine):
                row = next(r for r in (engine if native else rows)
                           if r['event'] == ('action.deadline' if native else 'lck.request' if request else 'lck.perform'))
                if remove: row.pop(field)
                else: row[field] = value
            return edit
        variants = [mutate(field, None, remove=True) for field in ('actionID', 'deadlineMS', 'sampledAtMS')]
        variants += [mutate(field, None, remove=True, request=True)
                     for field in ('actionID', 'deadlineMS', 'sampledAtMS', 'timeoutIn')]
        variants += [mutate('issuedAtMS', None, native=True, remove=True),
                     mutate('actionID', 'not-a-uuid'),
                     mutate('actionID', 'FFFFFFFF-0000-4000-8000-000000000000'),
                     mutate('actionID', '00000000-0000-4000-8000-000000000000', native=True),
                     mutate('apiKind', 'callkit', native=True),
                     mutate('deadlineMS', True), mutate('sampledAtMS', '1800000000000'),
                     mutate('issuedAtMS', False, native=True)]
        for index, edit in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(EvidenceError): self.native_deadline_capture(edit)
        def duplicate(rows, engine):
            engine.append(copy.deepcopy(next(r for r in engine if r['event'] == 'action.deadline')))
        with self.assertRaises(EvidenceError): self.native_deadline_capture(duplicate)
        def missing(rows, engine):
            engine.remove(next(r for r in engine if r['event'] == 'action.deadline'))
        with self.assertRaises(EvidenceError): self.native_deadline_capture(missing)
        def changed_request_identity(rows, engine):
            row = next(r for r in rows if r['event'] == 'lck.request')
            row['actionID'] = row['actionID'][:-1] + '1'
        with self.assertRaises(EvidenceError): self.native_deadline_capture(changed_request_identity)

    def test_native_deadlines_reject_duration_absolute_and_sample_tampering(self):
        for seconds in (5, 600):
            def wrong_duration(rows, engine, seconds=seconds):
                row = next(r for r in engine if r['event'] == 'action.deadline')
                row.update(issuedAtMS=row['deadlineMS'] - seconds * 1000,
                           deadlineSeconds=seconds, expirySeconds=seconds)
            with self.subTest(seconds=seconds), self.assertRaises(EvidenceError):
                self.native_deadline_capture(wrong_duration)
        for target, delta in (('public', 200), ('remaining', -1), ('before', -1), ('expired', 30_000)):
            def tamper(rows, engine, target=target, delta=delta):
                row = next(r for r in rows if r['event'] == 'lck.perform')
                if target == 'public': row['deadlineMS'] += delta
                elif target == 'remaining': row['timeoutIn'] += delta
                else:
                    row['sampledAtMS'] += delta
                    row['timeoutIn'] = (row['deadlineMS'] - row['sampledAtMS']) / 1000
            with self.subTest(target=target), self.assertRaises(EvidenceError): self.native_deadline_capture(tamper)


if __name__ == '__main__':
    unittest.main()
