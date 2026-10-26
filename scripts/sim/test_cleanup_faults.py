#!/usr/bin/env python3
"""Cleanup must finish the owned sweep before reporting transport or evidence faults."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import sim


FIRST = '11111111-1111-4111-8111-111111111111'
SECOND = '22222222-2222-4222-8222-222222222222'


class CleanupFaultTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='sim-cleanup-fault-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / 'owner.json'
        self.calls = []
        self.devices = {FIRST: 'first-owned', SECOND: 'second-owned'}
        self.failures = {}
        self.session = sim.Session(self.path, runner=self.native, recovery_timeout=7)
        self.session.state.update(current=SECOND, owned=[
            dict(name='first-owned', id=FIRST, uncertain=False),
            dict(name='second-owned', id=SECOND, uncertain=False)])
        self.session.save()
        self.environment = patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.root / 'summary.md'),
                                      SIM_FAILURE_MARKER=str(self.root / 'failure'), SIM_STATE='')
        self.environment.start()
        self.native_deny = [patch.object(subprocess, name, side_effect=AssertionError('native services forbidden'))
                            for name in ('run', 'Popen')]
        for guard in self.native_deny:
            guard.start()
            self.addCleanup(guard.stop)
        self.addCleanup(self.environment.stop)

    def native(self, command, timeout):
        self.calls.append((command, timeout))
        step = command[2]
        key = (step, command[3])
        if key in self.failures:
            raise self.failures[key]
        if step == 'list':
            output = json.dumps(dict(devices={'runtime': [dict(udid=device, name=name)
                for device, name in self.devices.items()]})).encode()
        else:
            output = (step + '-output').encode()
            if step == 'delete':
                self.devices.pop(command[3], None)
        return sim.Result(command, 0, stdout=output)

    def assert_sweep(self, expected=None):
        expected = expected or [('shutdown', FIRST), ('delete', FIRST),
                                ('shutdown', SECOND), ('delete', SECOND)]
        self.assertEqual([(command[2], command[3]) for command, _ in self.calls], expected)
        for command, timeout in self.calls:
            self.assertEqual(timeout, 7 if command[2] == 'list' else 60)

    def assert_original_after_sweep(self, original):
        with self.assertRaises(type(original)) as raised:
            self.session.cleanup(timeout=60)
        self.assertIs(raised.exception, original)
        self.assert_sweep()
        self.assertEqual(self.devices, {})

    def test_borrowed_cleanup_does_not_mutate_or_delete_parent_devices(self):
        before = self.path.read_bytes()
        borrowed = sim.Session.attach(self.path, SECOND, runner=self.native)
        observed = []
        self.assertEqual(borrowed.cleanup(timeout=60, on_error=observed.append).returncode, 0)
        self.assertEqual(observed, [])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(set(self.devices), {FIRST, SECOND})

    def test_resumed_owner_preserves_inventory_and_cleanup_bounds_after_fault(self):
        self.session.state['owned'][0].update(id=None, uncertain=True)
        self.session.state['retry_used'] = self.session.state['checkpoint'] = True
        self.session.save()
        self.session = sim.Session.resume(self.path, SECOND, runner=self.native,
                                          recovery_timeout=7, inventory_timeout=60)
        original = OSError('first resumed shutdown failure')
        self.failures['shutdown', FIRST] = original
        with self.assertRaises(OSError) as raised:
            self.session.cleanup(timeout=30)
        self.assertIs(raised.exception, original)
        self.assertEqual([(command[2], command[3], timeout) for command, timeout in self.calls],
            [('list', 'devices', 60), ('shutdown', FIRST, 30), ('delete', FIRST, 30),
             ('shutdown', SECOND, 30), ('delete', SECOND, 30)])
        self.assertEqual(self.devices, {})
        final = json.loads(self.path.read_text())
        self.assertEqual(final['owned'], [])
        self.assertTrue(final['retry_used'])
        self.assertTrue(final['checkpoint'])

    def test_first_record_log_open_fault_does_not_skip_later_device(self):
        original = OSError('private first cleanup log failure')
        opened, count = Path.open, [0]
        def open_path(path, *args, **kwargs):
            if path.name == 'cleanup.log':
                count[0] += 1
                if count[0] == 1:
                    raise original
            return opened(path, *args, **kwargs)
        with patch.object(Path, 'open', open_path):
            self.assert_original_after_sweep(original)
        self.assertEqual(json.loads(self.path.read_text())['owned'], [])

    def test_error_observer_sees_core_fault_before_later_adapter_recording_fault(self):
        original, later = OSError('first core recording failure'), OSError('later adapter recording failure')
        opened, native, observed, count = Path.open, self.session.runner, [], [0]
        def open_path(path, *args, **kwargs):
            if path.name == 'cleanup.log':
                count[0] += 1
                if count[0] == 1:
                    raise original
            return opened(path, *args, **kwargs)
        def adapter(command, timeout):
            result = native(command, timeout)
            if command[2:4] == ['delete', SECOND]:
                observed.append(later)  # An adapter may defer its own recording error.
            return result
        self.session.runner = adapter
        with patch.object(Path, 'open', open_path):
            with self.assertRaises(OSError) as raised:
                self.session.cleanup(timeout=60, on_error=observed.append)
        self.assertIs(raised.exception, original)
        self.assertEqual(observed, [original, later])
        self.assert_sweep()
        self.assertEqual(self.devices, {})

    def test_observer_baseexception_cannot_abort_teardown_or_replace_original(self):
        original, observed = OSError('private shutdown recording failure'), []
        self.failures['shutdown', FIRST] = original
        def observer(error):
            observed.append(error)
            raise KeyboardInterrupt('observer cannot cancel teardown')
        with self.assertRaises(OSError) as raised:
            self.session.cleanup(timeout=60, on_error=observer)
        self.assertIs(raised.exception, original)
        self.assertEqual(observed, [original])
        self.assertIs(original.failure_classified, True)
        self.assert_sweep()
        self.assertEqual(self.devices, {})

    def test_final_cleanup_receipt_fault_is_raised_after_both_devices(self):
        original = OSError('private cleanup receipt failure')
        write = Path.write_text
        def write_text(path, *args, **kwargs):
            if path.name == 'cleanup.json':
                raise original
            return write(path, *args, **kwargs)
        with patch.object(Path, 'write_text', write_text):
            self.assert_original_after_sweep(original)

    def test_first_log_write_error_survives_close_error_and_later_device_cleanup(self):
        original, later = OSError('private log write failure'), OSError('private log close failure')
        opened, writes, count = Path.open, [], [0]
        class Log:
            def write(self, value):
                writes.append(value)
                if len(writes) == 1:
                    raise original
            def close(self):
                raise later
        def open_path(path, *args, **kwargs):
            if path.name == 'cleanup.log':
                count[0] += 1
                if count[0] == 1:
                    return Log()
            return opened(path, *args, **kwargs)
        with patch.object(Path, 'open', open_path):
            self.assert_original_after_sweep(original)
        self.assertEqual(writes, [b'shutdown-output', b'delete-output'])

    def test_first_state_save_fault_does_not_abort_or_resurrect_deleted_records(self):
        original = OSError('private ownership write failure')
        write, count = self.session._write_state, [0]
        def write_state():
            count[0] += 1
            if count[0] == 1:
                raise original
            return write()
        with patch.object(self.session, '_write_state', side_effect=write_state):
            self.assert_original_after_sweep(original)
        self.assertEqual(json.loads(self.path.read_text())['owned'], [])

    def test_permanent_state_write_fault_retains_disk_ownership_without_skipping_teardown(self):
        original = OSError('private persistent state write failure')
        before = self.path.read_bytes()
        with patch.object(self.session, '_write_state', side_effect=original):
            self.assert_original_after_sweep(original)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.session.state['owned'], [])
        self.session.save()
        self.assertEqual(json.loads(self.path.read_text())['owned'], [])

    def test_post_replace_state_error_cannot_resurrect_a_committed_record_removal(self):
        original = OSError('private post-replace ownership failure')
        remember, count = self.session._remember_ownership, [0]
        def remember_state():
            count[0] += 1
            if count[0] == 1:
                raise original
            return remember()
        with patch.object(self.session, '_remember_ownership', side_effect=remember_state):
            self.assert_original_after_sweep(original)
        owned = json.loads(self.path.read_text())['owned']
        self.assertEqual([record['id'] for record in owned], [SECOND])

    def test_shutdown_runner_error_still_deletes_this_and_later_owned_devices(self):
        original = OSError('private shutdown transport or recording failure')
        self.failures['shutdown', FIRST] = original
        self.assert_original_after_sweep(original)
        receipt = json.loads((self.root / 'cleanup.json').read_text())
        self.assertTrue(receipt['deleted'])

    def test_runner_timeout_exception_keeps_identity_and_native_cleanup_bounds(self):
        original = subprocess.TimeoutExpired(['private-owned-command'], 60,
                                             output=b'partial output', stderr=b'private detail')
        self.failures['shutdown', FIRST] = original
        self.assert_original_after_sweep(original)

    def test_only_the_deferred_exception_gets_an_in_memory_classification_flag(self):
        original, unrelated = OSError('private cleanup transport failure'), OSError('unrelated error')
        self.failures['shutdown', FIRST] = original
        self.assert_original_after_sweep(original)
        self.assertIs(original.failure_classified, True)
        self.assertFalse(hasattr(unrelated, 'failure_classified'))
        self.assertNotIn('failure_classified', self.path.read_text())
        self.assertNotIn('failure_classified', (self.root / 'cleanup.json').read_text())

    def test_exception_refusing_a_classification_tag_cannot_abort_the_sweep(self):
        class UntaggableError(OSError):
            def __setattr__(self, name, value):
                if name == 'failure_classified':
                    raise TypeError('classification attributes refused')
                super().__setattr__(name, value)
        original = UntaggableError('private cleanup transport failure')
        self.failures['shutdown', FIRST] = original
        self.assert_original_after_sweep(original)
        self.assertFalse(hasattr(original, 'failure_classified'))

    def test_delete_runner_error_preserves_ownership_and_continues_later_device(self):
        original = OSError('private delete transport or recording failure')
        self.failures['delete', FIRST] = original
        with self.assertRaises(OSError) as raised:
            self.session.cleanup(timeout=60)
        self.assertIs(raised.exception, original)
        self.assert_sweep()
        self.assertEqual(self.devices, {FIRST: 'first-owned'})
        self.assertEqual([row['id'] for row in json.loads(self.path.read_text())['owned']], [FIRST])

    def test_inventory_error_keeps_unresolved_name_and_cleans_later_known_device(self):
        original = OSError('private inventory transport or recording failure')
        self.session.state['owned'][0].update(id=None, uncertain=True)
        self.session.save()
        self.failures['list', 'devices'] = original
        with self.assertRaises(OSError) as raised:
            self.session.cleanup(timeout=60)
        self.assertIs(raised.exception, original)
        self.assert_sweep([('list', 'devices'), ('shutdown', SECOND), ('delete', SECOND)])
        self.assertEqual(self.devices, {FIRST: 'first-owned'})
        owned = json.loads(self.path.read_text())['owned']
        self.assertEqual(len(owned), 1)
        self.assertEqual(owned[0]['name'], 'first-owned')

    def test_recovered_identity_save_error_does_not_discard_native_ownership_proof(self):
        original = OSError('private recovered ownership write failure')
        self.session.state['owned'][0].update(id=None, uncertain=True)
        self.session.save()
        save, count = self.session.save, [0]
        def save_state():
            count[0] += 1
            if count[0] == 1:
                raise original
            return save()
        with patch.object(self.session, 'save', side_effect=save_state):
            with self.assertRaises(OSError) as raised:
                self.session.cleanup(timeout=60)
        self.assertIs(raised.exception, original)
        self.assert_sweep([('list', 'devices'), ('shutdown', FIRST), ('delete', FIRST),
                           ('shutdown', SECOND), ('delete', SECOND)])
        self.assertEqual(self.devices, {})
        self.assertEqual(json.loads(self.path.read_text())['owned'], [])

    def test_first_error_and_primary_marker_survive_later_io_and_reporting_errors(self):
        first, later = OSError('first private shutdown failure'), OSError('later private failure')
        self.failures['shutdown', FIRST] = first
        self.failures['shutdown', SECOND] = later
        marker = self.root / 'failure'
        marker.write_text('existing primary')
        with patch.object(sim, 'report_failure', side_effect=later):
            self.assert_original_after_sweep(first)
        self.assertEqual(marker.read_text(), 'existing primary')

    def test_stale_ownership_save_failure_never_overwrites_authoritative_state(self):
        save, observed = self.session.save, []
        foreign = copy.deepcopy(self.session.state)
        foreign['owned'] = [dict(name='independent-owner', id=None, uncertain=True)]
        foreign['current'] = None
        def save_state():
            self.path.write_text(json.dumps(foreign))
            try:
                return save()
            except ValueError as error:
                observed.append(error)
                raise
        with patch.object(self.session, 'save', side_effect=save_state):
            with self.assertRaises(ValueError) as raised:
                self.session.cleanup(timeout=60)
        self.assertIs(raised.exception, observed[0])
        self.assert_sweep()
        self.assertEqual(self.devices, {})
        self.assertEqual(json.loads(self.path.read_text()), foreign)


if __name__ == '__main__':
    unittest.main()
