#!/usr/bin/env python3
"""Host-only container lookup controls; no simulator or native RPC runs."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import paths


SIMULATOR = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
FOREIGN = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
CONTAINER = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC'
BUNDLE = 'dev.iosvoipsdk.m1contracts'
RUN_ID = 'host-only-container-fixture'
PID = 12345


def write_json(path, value):
    path.write_text(json.dumps(value) + '\n')


def make_capture(root):
    """Reusable filesystem-only fixture, never a native qualification receipt."""
    root = Path(root).resolve()
    captures = root / 'captures'
    captures.mkdir()
    trace = captures / 'sdk-m1-contract-audio-lifecycle.log'
    rows = [dict(event=event, t_ms=index, pid=PID, runID=RUN_ID, simulatorID=SIMULATOR,
                 bundleID=BUNDLE, main=True) for index, event in enumerate(('app.entry', 'launch', 'done'))]
    trace.write_text(BUNDLE + ': ' + str(PID) + '\n' +
                     ''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
    receipt = trace.with_suffix('.receipt.json')
    write_json(receipt, dict(schemaVersion=2, scenario=trace.stem, bundleID=BUNDLE,
        runID=RUN_ID, simulatorID=SIMULATOR, appPID=PID, launcherAppPID=PID,
        completed=True, success=True, lastProbeEvent='done', launchExitCode=0,
        traceSHA256=hashlib.sha256(trace.read_bytes()).hexdigest(),
        terminationMethod='console-launcher-signal', consoleTransport='host-pty',
        appAbsenceMethod='signal-zero', appAbsentAfterStop=True, launcherPID=23456,
        terminationSignal=15, terminationSignalDelivered=True))
    home = root / 'home'
    devices = home / 'Library/Developer/CoreSimulator/Devices'
    container = devices / SIMULATOR / 'data/Containers/Data/Application' / CONTAINER
    runtime = container / 'Documents/.callkit-simulator'
    journal = runtime / RUN_ID / 'events.jsonl'
    journal.parent.mkdir(parents=True)
    journal.write_text(json.dumps(dict(event='host-only-journal', pid=PID, runID=RUN_ID, bundleID=BUNDLE)) + '\n')
    session = runtime / 'session.json'
    write_json(session, dict(schemaVersion=1, runID=RUN_ID, pid=PID, bundleID=BUNDLE,
                            notification='dev.callkitsim.control.' + str(PID)))
    return dict(receipt=receipt, trace=trace, devices_root=devices, simulator=SIMULATOR,
                run_id=RUN_ID, bundle=BUNDLE, container=container, journal=journal, session=session, home=home)


class CompletedContainerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sim-container-host-')
        self.root = Path(self.temporary.name).resolve()
        self.fixture = make_capture(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def locate(self, **updates):
        options = {key: self.fixture[key] for key in
                   ('receipt', 'trace', 'simulator', 'run_id', 'bundle', 'devices_root')}
        options.update(updates)
        return paths.completed_container(**options)

    def edit_json(self, key, **updates):
        value = json.loads(self.fixture[key].read_text())
        value.update(updates)
        write_json(self.fixture[key], value)

    def test_unique_completed_process_selects_exact_owned_container(self):
        self.assertEqual(self.locate(), self.fixture['container'])
        self.assertEqual(self.locate().resolve(strict=True), self.locate())

    def test_foreign_simulator_and_unrelated_sessions_are_not_selected(self):
        foreign = Path(str(self.fixture['container']).replace(SIMULATOR, FOREIGN))
        shutil.copytree(self.fixture['container'], foreign)
        unrelated = self.fixture['container'].with_name('DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD')
        shutil.copytree(self.fixture['container'], unrelated)
        session = unrelated / 'Documents/.callkit-simulator/session.json'
        value = json.loads(session.read_text()); value['runID'] = 'old-run'
        write_json(session, value)
        self.assertEqual(self.locate(), self.fixture['container'])
        shutil.rmtree(self.fixture['container'])
        with self.assertRaises(ValueError): self.locate()

    def test_two_matching_canonical_containers_are_ambiguous(self):
        duplicate = self.fixture['container'].with_name('DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD')
        shutil.copytree(self.fixture['container'], duplicate)
        with self.assertRaisesRegex(ValueError, 'got 2'): self.locate()
        (duplicate / 'Documents/.callkit-simulator' / RUN_ID / 'events.jsonl').unlink()
        with self.assertRaisesRegex(ValueError, 'got 2'): self.locate()

    def test_stale_or_malformed_session_cannot_match(self):
        original = self.fixture['session'].read_text()
        cases = (dict(runID='old-run'), dict(pid=PID + 1), dict(pid=True), dict(bundleID='dev.foreign'),
                 dict(schemaVersion=True), dict(schemaVersion=2), dict(notification='wrong'))
        for update in cases:
            with self.subTest(update=update):
                self.fixture['session'].write_text(original)
                self.edit_json('session', **update)
                with self.assertRaises(ValueError): self.locate()
        for value in ('broken JSON', '[]', 'null'):
            with self.subTest(value=value):
                self.fixture['session'].write_text(value)
                with self.assertRaises(ValueError): self.locate()

    def test_non_console_stop_cannot_replace_the_current_app_absence_proof(self):
        value = json.loads(self.fixture['receipt'].read_text())
        for key in ('terminationSignal', 'terminationSignalDelivered'):
            value.pop(key)
        value.update(terminationMethod='command', terminateExitCode=0)
        write_json(self.fixture['receipt'], value)
        with self.assertRaisesRegex(ValueError, 'console app-stop proof'): self.locate()

    def test_missing_session_or_journal_cannot_match(self):
        for key in ('session', 'journal'):
            with self.subTest(missing=key):
                path = self.fixture[key]
                content = path.read_bytes(); path.unlink()
                with self.assertRaises(ValueError): self.locate()
                path.write_bytes(content)

    def test_symlinked_container_session_journal_or_parent_is_not_selected(self):
        for key in ('container', 'session', 'journal'):
            with self.subTest(symlink=key):
                path = self.fixture[key]
                outside = self.root / ('outside-' + key)
                path.rename(outside)
                path.symlink_to(outside, target_is_directory=outside.is_dir())
                with self.assertRaises(ValueError): self.locate()
                path.unlink(); outside.rename(path)
        documents = self.fixture['container'] / 'Documents'
        outside = self.root / 'outside-documents'
        documents.rename(outside); documents.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError): self.locate()

    def test_symlinked_owned_simulator_directory_is_rejected(self):
        simulator = self.fixture['devices_root'] / SIMULATOR
        outside = self.root / 'foreign-device-directory'
        simulator.rename(outside); simulator.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError): self.locate()

    def test_mismatched_or_incomplete_supervisor_identity_is_rejected(self):
        original = self.fixture['receipt'].read_text()
        cases = (dict(simulatorID=FOREIGN), dict(runID='old-run'), dict(bundleID='dev.foreign'),
                 dict(appPID=PID + 1), dict(launcherAppPID=PID + 1), dict(success=False),
                 dict(completed=False), dict(cleanupExitCode=0), dict(traceSHA256='0' * 64),
                 dict(appAbsentAfterStop=False), dict(scenario='another-capture'))
        for update in cases:
            with self.subTest(update=update):
                self.fixture['receipt'].write_text(original)
                self.edit_json('receipt', **update)
                with self.assertRaises(ValueError): self.locate()

    def test_native_launcher_header_must_be_sole_and_bound_even_with_rehashed_trace(self):
        original = self.fixture['trace'].read_text()
        for header in ('', BUNDLE + ': 999\n', BUNDLE + ': ' + str(PID) + '\n' + BUNDLE + ': ' + str(PID) + '\n'):
            with self.subTest(header=header):
                self.fixture['trace'].write_text(header + original.split('\n', 1)[1])
                self.edit_json('receipt', traceSHA256=hashlib.sha256(self.fixture['trace'].read_bytes()).hexdigest())
                with self.assertRaises(ValueError): self.locate()

    def test_rehashed_trace_with_foreign_or_unfinished_app_evidence_is_rejected(self):
        original = self.fixture['trace'].read_text()
        for update in (dict(pid=PID + 1), dict(runID='old-run'), dict(simulatorID=FOREIGN),
                       dict(bundleID='dev.foreign'), dict(main=False), dict(event='not-done')):
            with self.subTest(update=update):
                lines = original.splitlines()
                row = json.loads(lines[-1].split('PROBE ', 1)[1]); row.update(update)
                lines[-1] = 'PROBE ' + json.dumps(row)
                self.fixture['trace'].write_text('\n'.join(lines) + '\n')
                self.edit_json('receipt', traceSHA256=hashlib.sha256(self.fixture['trace'].read_bytes()).hexdigest())
                with self.assertRaises(ValueError): self.locate()

    def test_traversal_or_non_uuid_selection_is_rejected(self):
        for options in (dict(simulator='../foreign'), dict(run_id='../foreign'), dict(bundle='../foreign')):
            with self.subTest(options=options):
                with self.assertRaises(ValueError): self.locate(**options)
        self.fixture['container'].rename(self.fixture['container'].with_name('not-a-container-uuid'))
        with self.assertRaises(ValueError): self.locate()

    def test_receipt_and_trace_must_be_the_same_nonsymlink_capture(self):
        receipt = self.fixture['receipt']
        other = receipt.with_name('another.receipt.json')
        shutil.copyfile(receipt, other)
        with self.assertRaises(ValueError): self.locate(receipt=other)
        for key in ('trace', 'receipt'):
            with self.subTest(symlink=key):
                path = self.fixture[key]
                outside = self.root / ('outside-' + key)
                path.rename(outside); path.symlink_to(outside)
                with self.assertRaises(ValueError): self.locate()
                path.unlink(); outside.rename(path)

    def test_capture_mutation_during_identity_binding_is_refused(self):
        original = paths.bound_rows
        def change_after_binding(*args, **kwargs):
            result = original(*args, **kwargs)
            with self.fixture['trace'].open('ab') as stream:
                stream.write(b'console changed after identity validation\n')
            return result
        with patch.object(paths, 'bound_rows', side_effect=change_after_binding):
            with self.assertRaisesRegex(ValueError, 'capture changed'):
                self.locate()


if __name__ == '__main__':
    unittest.main()
