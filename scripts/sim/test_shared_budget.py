#!/usr/bin/env python3
"""Host-only controls for one invocation's shared simulator retry budget."""
import json
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import sim


DEVICE = '11111111-1111-4111-8111-111111111111'
OTHER_DEVICE = '22222222-2222-4222-8222-222222222222'
HELPER_DIRECTORY = Path(__file__).resolve().parent

RESERVATION_WORKER = '''
from pathlib import Path
import sys, time
import sim
session = sim.Session.attach(sys.argv[1], sys.argv[2])
root, name = Path(sys.argv[3]), sys.argv[4]
(root / ('ready-' + name)).touch()
deadline = time.monotonic() + 10
while not (root / 'release').exists():
    if time.monotonic() >= deadline:
        raise RuntimeError('host reservation control release deadline')
    time.sleep(.005)
try:
    reserved = session.reserve_retry()
except BlockingIOError:
    reserved = False  # Contention is a terminal refusal, never a wait/retry.
print(int(reserved), flush=True)
'''

LOCK_WORKER = '''
from pathlib import Path
import fcntl, os, signal, sys
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
Path(sys.argv[2]).touch()
signal.pause()
'''


class FakeNative:
    """Independent native inventory and calls, with one requested refusal."""
    def __init__(self):
        self.calls, self.inventory, self.failures = [], [], {}
        self.creates = 0

    def __call__(self, command, timeout):
        self.calls.append(list(command))
        step = command[2]
        if self.failures.get(step, 0):
            self.failures[step] -= 1
            return sim.Result(command, 73, stderr=b'synthetic native refusal\n')
        if step == 'create':
            self.creates += 1
            device = DEVICE if self.creates == 1 else OTHER_DEVICE
            self.inventory.append(dict(name=command[3], udid=device))
            return sim.Result(command, 0, stdout=(device + '\n').encode())
        if step == 'list':
            value = dict(devices={'host-runtime': list(self.inventory)})
            return sim.Result(command, 0, stdout=json.dumps(value).encode())
        if step == 'delete':
            self.inventory = [device for device in self.inventory if device['udid'] != command[3]]
        return sim.Result(command, 0)

    def count(self, step):
        return sum(command[2] == step for command in self.calls)


class SharedBudgetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sim-shared-budget-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / 'simulator-state.json'
        self.native = FakeNative()
        self.session = sim.Session(self.path, runner=self.native)
        self.assertEqual(self.session.call(
            ['xcrun', 'simctl', 'create', 'host-owned', 'device-type', 'runtime'], 1).returncode, 0)
        self.environment = patch.dict(os.environ)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop('GITHUB_STEP_SUMMARY', None)

    def test_attached_console_reservation_is_visible_to_the_existing_parent(self):
        child = sim.Session.attach(self.path, DEVICE)
        self.assertTrue(child.reserve_retry())
        self.assertFalse(self.session.reserve_retry())
        self.assertTrue(sim.Session.attach(self.path, DEVICE).state['retry_used'])

    def test_attach_refuses_missing_state_without_creating_a_new_budget(self):
        missing = self.root / 'not-a-session.json'
        with self.assertRaises((ValueError, OSError)):
            sim.Session.attach(missing, DEVICE)
        self.assertFalse(missing.exists())

    def test_attach_refuses_wrong_simulator_or_symlink_without_changing_state(self):
        original = self.path.read_bytes()
        with self.assertRaises((ValueError, OSError)):
            sim.Session.attach(self.path, OTHER_DEVICE)
        link = self.root / 'linked-state.json'
        link.symlink_to(self.path)
        with self.assertRaises((ValueError, OSError)):
            sim.Session.attach(link, DEVICE)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(sim.Session.attach(self.path, DEVICE).state['retry_used'])

    def test_stale_parent_save_cannot_restore_either_sticky_flag(self):
        child = sim.Session.attach(self.path, DEVICE)
        self.assertTrue(child.reserve_retry())
        child.checkpoint()
        # This object predates both child writes, as the shell parent's does.
        self.assertFalse(self.session.state['retry_used'])
        self.assertFalse(self.session.state['checkpoint'])
        self.session.save()
        current = sim.Session.attach(self.path, DEVICE)
        self.assertTrue(current.state['retry_used'])
        self.assertTrue(current.state['checkpoint'])
        self.assertFalse(current.reserve_retry())

    def test_checkpoint_and_preparation_save_preserve_a_prior_reservation(self):
        stale = sim.Session.attach(self.path, DEVICE)
        self.assertTrue(self.session.reserve_retry())
        stale.checkpoint()
        self.assertEqual(self.session.call(['xcrun', 'simctl', 'boot', DEVICE], 1).returncode, 0)
        current = sim.Session.attach(self.path, DEVICE)
        self.assertTrue(current.state['retry_used'])
        self.assertTrue(current.state['checkpoint'])
        self.assertFalse(current.reserve_retry())

    def test_stale_attached_save_cannot_resurrect_deleted_simulator_ownership(self):
        child = sim.Session.attach(self.path, DEVICE)
        self.assertEqual(self.session.cleanup(timeout=1).returncode, 0)
        self.assertEqual(self.native.inventory, [])
        child.save()
        current = sim.Session(self.path, runner=self.native)
        self.assertIsNone(current.current)
        self.assertEqual(current.state['owned'], [])
        self.assertEqual(self.native.count('delete'), 1)

    def test_stale_lifecycle_owner_cannot_overwrite_cleanup_or_replacement(self):
        for action in ('cleanup', 'replacement'):
            with self.subTest(action=action):
                native = FakeNative()
                path = self.root / ('stale-' + action + '.json')
                owner = sim.Session(path, runner=native)
                self.assertEqual(owner.call(['xcrun', 'simctl', 'create',
                    'host-owned', 'device-type', 'runtime'], 1).returncode, 0)
                stale = sim.Session(path, runner=native)
                if action == 'cleanup':
                    self.assertEqual(owner.cleanup(timeout=1).returncode, 0)
                else:
                    native.failures['boot'] = 1
                    self.assertEqual(owner.call(['xcrun', 'simctl', 'boot', DEVICE], 1).returncode, 0)
                    self.assertEqual(owner.current, OTHER_DEVICE)
                authoritative = path.read_bytes()
                with self.assertRaises(ValueError):
                    stale.save()
                self.assertEqual(path.read_bytes(), authoritative)

    def test_attached_context_refuses_replay_checks_after_parent_replacement(self):
        child = sim.Session.attach(self.path, DEVICE)
        self.native.failures['boot'] = 1
        self.assertEqual(self.session.call(['xcrun', 'simctl', 'boot', DEVICE], 1).returncode, 0)
        self.assertEqual(self.session.current, OTHER_DEVICE)
        authoritative = self.path.read_bytes()
        for label, operation in (('reserve', child.reserve_retry),
                                 ('checkpoint-status', child.is_checkpointed)):
            with self.subTest(operation=label):
                with self.assertRaises(ValueError):
                    operation()
                self.assertEqual(self.path.read_bytes(), authoritative)

    def assert_busy(self, operation):
        def expired(_signum, _frame):
            self.fail('contested Session operation blocked past its host control deadline')
        handler = signal.signal(signal.SIGALRM, expired)
        timer = signal.setitimer(signal.ITIMER_REAL, .75)
        started = time.monotonic()
        try:
            with self.assertRaises(OSError):
                operation()
            self.assertLess(time.monotonic() - started, .5)
        finally:
            signal.setitimer(signal.ITIMER_REAL, *timer)
            signal.signal(signal.SIGALRM, handler)

    def test_lock_contention_fails_closed_promptly_without_state_mutation(self):
        original = self.path.read_bytes()
        with open(str(self.path) + '.lock', 'r+b') as locked:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for label, operation in (
                    ('reserve', self.session.reserve_retry),
                    ('checkpoint', self.session.checkpoint),
                    ('attach', lambda: sim.Session.attach(self.path, DEVICE))):
                with self.subTest(operation=label):
                    self.assert_busy(operation)
                    self.assertEqual(self.path.read_bytes(), original)
        self.assertTrue(sim.Session.attach(self.path, DEVICE).reserve_retry())

    def test_cancelled_lock_holder_does_not_leave_the_session_locked(self):
        ready = self.root / 'lock-holder-ready'
        holder = subprocess.Popen([sys.executable, '-c', LOCK_WORKER,
            str(self.path) + '.lock', str(ready)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists():
                if holder.poll() is not None:
                    stdout, stderr = holder.communicate(timeout=1)
                    self.fail('host lock holder exited before readiness: ' + stdout + stderr)
                if time.monotonic() >= deadline:
                    self.fail('host lock holder readiness deadline')
                time.sleep(.005)
            self.assert_busy(self.session.reserve_retry)
            holder.send_signal(signal.SIGTERM)
            stdout, stderr = holder.communicate(timeout=5)
            self.assertEqual(holder.returncode, -signal.SIGTERM, stdout + stderr)
            self.assertTrue(sim.Session.attach(self.path, DEVICE).reserve_retry())
        finally:
            if holder.poll() is None:
                holder.kill()
            holder.communicate(timeout=5)

    def test_session_lock_does_not_survive_exec_in_an_unrelated_child(self):
        children = []
        replace = os.replace
        def spawn_during_write(source, target):
            # The public save is holding its lock here. Deliberately opt out of
            # Popen's usual descriptor closure to check the lock's exec policy.
            children.append(subprocess.Popen([sys.executable, '-c',
                'import time; time.sleep(30)'], close_fds=False,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            return replace(source, target)
        try:
            with patch.object(sim.os, 'replace', side_effect=spawn_during_write):
                self.session.save()
            self.assertEqual(len(children), 1)
            self.assertIsNone(children[0].poll())
            self.assertTrue(sim.Session.attach(self.path, DEVICE).reserve_retry())
            self.assertIsNone(children[0].poll())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)

    def test_cancelled_checkpoint_releases_lock_and_removes_temporary_state(self):
        original = self.path.read_bytes()
        files = {path.name for path in self.root.iterdir()}
        interrupted = sim.Interrupted(signal.SIGTERM)
        with patch.object(sim.os, 'replace', side_effect=interrupted):
            with self.assertRaises(sim.Interrupted) as raised:
                self.session.checkpoint()
        self.assertIs(raised.exception, interrupted)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual({path.name for path in self.root.iterdir()}, files)
        self.assertTrue(sim.Session.attach(self.path, DEVICE).reserve_retry())

    def test_public_cleanup_releases_lock_for_the_next_session_operation(self):
        self.assertEqual(self.session.cleanup(timeout=1).returncode, 0)
        current = sim.Session(self.path)
        self.assertIsNone(current.current)
        self.assertEqual(current.state['owned'], [])
        self.assertTrue(current.reserve_retry())

    def workers(self, count):
        environment = dict(os.environ, PYTHONPATH=str(HELPER_DIRECTORY))
        processes = []
        def cleanup():
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)
        self.addCleanup(cleanup)
        # Attachment itself fails closed on contention. Load these snapshots
        # serially so the barrier isolates the reservation race under test.
        for index in range(count):
            process = subprocess.Popen([sys.executable, '-c', RESERVATION_WORKER,
                str(self.path), DEVICE, str(self.root), str(index)],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(process)
            deadline = time.monotonic() + 10
            while not (self.root / ('ready-' + str(index))).exists():
                if process.poll() is not None:
                    stdout, stderr = process.communicate(timeout=1)
                    self.fail('host reservation worker exited before release: ' + stdout + stderr)
                if time.monotonic() >= deadline:
                    self.fail('host reservation worker readiness deadline')
                time.sleep(.005)
        return processes

    def release(self, processes):
        (self.root / 'release').touch()
        values = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIn(stdout.strip(), ('0', '1'), stdout + stderr)
            values.append(int(stdout.strip()))
        return values

    def test_concurrent_attached_processes_have_exactly_one_reservation_winner(self):
        # Every process loads the unspent state before any process may reserve.
        processes = self.workers(4)
        self.assertEqual(sum(self.release(processes)), 1)
        self.assertFalse(self.session.reserve_retry())
        self.assertTrue(sim.Session.attach(self.path, DEVICE).state['retry_used'])

    def test_checkpoint_wins_against_reservation_from_an_already_attached_process(self):
        process = self.workers(1)
        self.session.checkpoint()
        self.assertEqual(self.release(process), [0])
        current = sim.Session.attach(self.path, DEVICE)
        self.assertTrue(current.state['checkpoint'])
        self.assertFalse(current.state['retry_used'])

    def test_lifecycle_recovery_exhausts_the_attached_console_budget(self):
        for step, suffix in (('create', []), ('boot', []), ('bootstatus', ['-b']),
                ('install', ['probe.app']), ('privacy', ['grant', 'microphone', 'host.fixture'])):
            with self.subTest(step=step):
                native = FakeNative()
                state_path = self.root / (step + '.json')
                session = sim.Session(state_path, runner=native)
                if step == 'create':
                    native.failures[step] = 1
                created = session.call(['xcrun', 'simctl', 'create',
                    'host-owned', 'device-type', 'runtime'], 1)
                self.assertEqual(created.returncode, 0)
                if step != 'create':
                    native.failures[step] = 1
                    result = session.call(['xcrun', 'simctl', step, session.current, *suffix], 1)
                    self.assertEqual(result.returncode, 0)
                self.assertEqual(native.count(step), 2)
                self.assertFalse(sim.Session.attach(state_path, session.current).reserve_retry())

    def test_console_reservation_makes_the_existing_parent_lifecycle_failure_final(self):
        self.assertTrue(sim.Session.attach(self.path, DEVICE).reserve_retry())
        for step, suffix in (('boot', []), ('bootstatus', ['-b']),
                ('install', ['probe.app']), ('privacy', ['grant', 'microphone', 'host.fixture'])):
            with self.subTest(step=step):
                self.native.failures[step] = 1
                result = self.session.call(['xcrun', 'simctl', step, DEVICE, *suffix], 1)
                self.assertEqual(result.returncode, 73)
                self.assertEqual(self.native.count(step), 1)
                self.assertEqual(self.native.count('create'), 1)
                self.assertEqual(self.session.current, DEVICE)


if __name__ == '__main__':
    unittest.main()
