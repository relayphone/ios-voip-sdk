#!/usr/bin/env python3
"""Shared-budget console controls using host Python children, never CoreSimulator."""
import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import sim


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_scenario as runner
SIMULATOR = '44444444-4444-4444-8444-444444444444'
OTHER = '55555555-5555-4555-8555-555555555555'
BUNDLE = 'dev.callkitsim.recoveryfixture'
PREAPP = (
    'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
    f'Simulator device failed to launch {BUNDLE}.\nNo such process\n'
    'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
    f"\tApplication launch for '{BUNDLE}' did not return a process handle nor launch error.\n"
    '\tNo such process\n').encode()

FAKE = r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FAKE_CONSOLE_ROOT'])
command = sys.argv[1:]
assert command[0] == 'simctl', command
step = command[1]
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(command) + '\n')
mode = os.environ.get('FAKE_CONSOLE_MODE', 'recover')
if step == 'terminate':
    if mode == 'unknown-cleanup':
        sys.stderr.write('unknown refusal\n')
        sys.exit(7)
    sys.stderr.write(os.environ['FAKE_NOT_RUNNING'])
    sys.exit(3)
assert step == 'launch', command
counter = root / 'launch-count'
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
(root / 'launch-pid').write_text(str(os.getpid()))
bundle = command[-1]
if mode == 'partial':
    print('PROBE {"event":"app.entry"}', flush=True)
    sys.exit(3)
if mode == 'pid':
    print(bundle + ': ' + str(os.getpid()), flush=True)
    sys.exit(3)
if (attempt == 1 and mode != 'success') or mode == 'always-reject':
    sys.stderr.write(os.environ['FAKE_PREAPP'])
    sys.exit(3)
pid = os.getpid()
print(bundle + ': ' + str(pid), flush=True)
for row in ({'event':'app.entry'}, {'event':'launch', 'pid':pid}, {'event':'done'}):
    print('PROBE ' + json.dumps(row), flush=True)
time.sleep(30)
'''


class ConsoleRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sim-console-recovery-host-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        binary = self.root / 'bin'; binary.mkdir()
        executable = binary / 'xcrun'
        executable.write_text('#!' + sys.executable + '\n' + FAKE)
        executable.chmod(0o755)
        self.state = self.root / 'owned.json'
        self.session = sim.Session(self.state, runner=lambda command, timeout:
            sim.Result(command, 0, stdout=(SIMULATOR + '\n').encode()))
        self.session.call(['xcrun', 'simctl', 'create', 'host-console', 'host-device', 'host-runtime'], 1)
        self.trace = self.root / 'case.log'
        self.receipt = self.root / 'case.receipt.json'
        self.summary = self.root / 'summary.md'
        self.marker = self.root / 'classified'
        self.archive = Path(str(self.trace) + '.preapp-attempt-1')
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ.get('PATH', ''),
            FAKE_CONSOLE_ROOT=str(self.root), FAKE_PREAPP=PREAPP.decode(),
            FAKE_NOT_RUNNING=sim.not_running_error(BUNDLE), SIM_STATE=str(self.state),
            GITHUB_STEP_SUMMARY=str(self.summary), SIM_FAILURE_MARKER=str(self.marker))

    def capture(self, *, state='env', mode='recover', inherited=False, simulator=SIMULATOR):
        command = [sys.executable, str(ROOT / 'discovery/run_scenario.py'),
            '--console-launcher-stop', '--output', str(self.trace), '--receipt', str(self.receipt),
            '--timeout', '4', '--run-id', 'host-recovery', '--simulator-id', simulator,
            '--scenario', 'host-recovery-case', '--bundle-id', BUNDLE]
        environment = dict(self.env, FAKE_CONSOLE_MODE=mode)
        if state != 'env':
            environment.pop('SIM_STATE', None)
            if state == 'explicit': command += ['--sim-state', str(self.state)]
            elif state == 'missing': command += ['--sim-state', str(self.root / 'missing.json')]
            else: self.assertEqual(state, 'none')
        if inherited: command += ['--inherit-launcher-group']
        command += ['--terminate-command', 'xcrun', 'simctl', 'terminate', simulator, BUNDLE,
                    '--launch-command', 'xcrun', 'simctl', 'launch', '--console',
                    '--terminate-running-process', simulator, BUNDLE]
        return subprocess.run(command, env=environment, capture_output=True, text=True,
                              start_new_session=True, timeout=15)

    def launches(self):
        path = self.root / 'calls.jsonl'
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [command for command in rows if command[1] == 'launch']

    def evidence(self, path=None):
        path = self.receipt if path is None else path
        return json.loads(path.read_text())

    def flags(self):
        value = json.loads(self.state.read_text())
        return value['retry_used'], value['checkpoint']

    @contextmanager
    def holding_session_lock(self):
        # An independent interpreter owns the lock. Its finite lifetime bounds
        # the negative control even if the implementation regresses to blocking.
        source = ('import fcntl,sys,time; '
                  'stream=open(sys.argv[1],"a"); '
                  'fcntl.flock(stream,fcntl.LOCK_EX); '
                  'print("held",flush=True); time.sleep(3)')
        process = subprocess.Popen([sys.executable, '-c', source, str(self.state) + '.lock'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 3)
            self.assertTrue(ready, 'independent lock holder did not become ready')
            self.assertEqual(process.stdout.readline(), 'held\n')
            yield
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=3)

    def test_exact_rejection_recovers_once_and_retains_original_bytes_and_schema(self):
        result = self.capture(state='explicit')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.launches()), 2)
        first = self.archive / self.trace.name
        self.assertEqual(first.read_bytes(), PREAPP)
        rejected = self.evidence(self.archive / self.receipt.name)
        self.assertEqual(rejected['traceSHA256'], hashlib.sha256(PREAPP).hexdigest())
        self.assertFalse(rejected['completed'])
        self.assertFalse(rejected['success'])
        self.assertEqual(rejected['launchExitCodeBeforeCleanup'], 3)
        self.assertEqual(rejected['launchExitCode'], 3)
        self.assertEqual(rejected['cleanupStderr'], sim.not_running_error(BUNDLE))
        accepted = self.evidence()
        self.assertTrue(accepted['completed'])
        self.assertTrue(accepted['success'])
        self.assertTrue(accepted['appAbsentAfterStop'])
        self.assertEqual(accepted['traceSHA256'], hashlib.sha256(self.trace.read_bytes()).hexdigest())
        self.assertFalse(any('retry' in key.lower() or 'classification' in key.lower() for key in accepted))
        self.assertEqual(self.flags(), (True, True))
        self.assertFalse(self.marker.exists())
        self.assertIn('scheduled', self.summary.read_text())
        self.assertIn('recovered', self.summary.read_text())

    def test_exported_state_uses_the_parent_budget(self):
        result = self.capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.launches()), 2)
        self.assertEqual(self.flags(), (True, True))

    def test_spent_parent_budget_does_not_replay_or_move_the_refusal(self):
        self.assertTrue(self.session.reserve_retry())
        result = self.capture()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.trace.read_bytes(), PREAPP)
        self.assertEqual(self.flags(), (True, False))
        self.assertTrue(self.marker.exists())

    def test_parent_checkpoint_does_not_replay_even_with_unused_budget(self):
        self.session.checkpoint()
        result = self.capture()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.flags(), (False, True))

    def test_second_exact_rejection_is_terminal(self):
        result = self.capture(mode='always-reject')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 2)
        self.assertTrue(self.archive.is_dir())
        self.assertEqual(self.flags(), (True, False))
        self.assertFalse(self.evidence()['success'])
        self.assertTrue(self.marker.exists())

    def test_partial_app_evidence_latches_checkpoint_and_never_replays(self):
        result = self.capture(mode='partial')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertTrue(self.evidence()['appEntryObserved'])
        self.assertEqual(self.flags(), (False, True))
        self.assertFalse(self.archive.exists())

    def test_pid_acknowledgement_latches_checkpoint_and_never_replays(self):
        result = self.capture(mode='pid')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertIn('launcherAppPID', self.evidence())
        self.assertEqual(self.flags(), (False, True))
        self.assertFalse(self.archive.exists())

    def test_unknown_cleanup_is_never_replayed(self):
        result = self.capture(mode='unknown-cleanup')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertEqual(self.flags(), (False, False))
        self.assertFalse(self.archive.exists())
        self.assertIn('infra:terminate', self.summary.read_text())

    def test_inherited_group_leaves_recovery_to_the_sdk_owner(self):
        result = self.capture(inherited=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertTrue(self.evidence()['inheritLauncherGroup'])
        self.assertEqual(self.flags(), (False, False))
        self.assertFalse(self.archive.exists())

    def test_missing_or_wrong_attachment_never_launches_or_creates_a_budget(self):
        for state, simulator in (('missing', SIMULATOR), ('env', OTHER)):
            with self.subTest(state=state, simulator=simulator):
                result = self.capture(state=state, simulator=simulator)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.launches(), [])
                self.assertFalse((self.root / 'missing.json').exists())
                self.assertEqual(self.flags(), (False, False))

    def test_no_attachment_keeps_the_capture_single_attempt(self):
        result = self.capture(state='none')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.flags(), (False, False))

    def wrapper_capture(self, *, fault=None):
        """Drive the real recovery owner while replacing only its capture transport."""
        identity = dict(runID='host-recovery', simulatorID=SIMULATOR,
                        scenario='host-recovery-case', bundleID=BUNDLE)
        launch = ['xcrun', 'simctl', 'launch', '--console', SIMULATOR, BUNDLE]
        terminate = ['xcrun', 'simctl', 'terminate', SIMULATOR, BUNDLE]
        clock, captures, first = [0.0], [], {}
        class Process:
            pid = 712345
            def poll(self): return 3
        process = Process()
        def capture(*arguments, **keywords):
            captures.append((arguments, keywords))
            if len(captures) > 1:
                return 0
            clock[0] = 4 if fault == 'deadline-before-proof' else .5
            value = dict(identity, completed=False, success=False, schemaVersion=2,
                launcherPID=process.pid, stdoutEOFSeconds=.25,
                launchExitCodeBeforeCleanup=3, launchExitCode=3,
                cleanupExitCode=3, cleanupStdout='', cleanupStderr=sim.not_running_error(BUNDLE),
                error='launcher exited before terminal done event',
                identityError='require one launcher app PID acknowledgement; got 0',
                traceSHA256=hashlib.sha256(PREAPP).hexdigest())
            if fault == 'foreign-identity': value['runID'] = 'foreign-run'
            if fault == 'foreign-launcher': value['launcherPID'] += 1
            self.trace.write_bytes(PREAPP)
            self.receipt.write_text(json.dumps(value, separators=(',', ':')) + '\n')
            first.update({path.name: path.read_bytes() for path in (self.trace, self.receipt)})
            keywords['launched'](process)
            sim.report_failure('infra:launch', 'synthetic exact pre-app rejection')
            return 1
        group_calls = []
        def group_absence(pid, number):
            group_calls.append((pid, number))
            self.assertEqual((pid, number), (process.pid, 0))
            if fault == 'live-group': return
            if fault == 'unknown-group': raise PermissionError('owned group outcome unknown')
            raise ProcessLookupError('owned group absent')
        read_bytes = Path.read_bytes
        def archive_read(path):
            if path.parent == self.archive:
                if fault == 'deadline-during-archive': clock[0] = 4
                if fault == 'late-checkpoint': self.session.checkpoint()
                if fault == 'late-output': self.trace.write_bytes(b'late app evidence')
                if fault == 'changed-archive': path.write_bytes(b'changed after archive')
            return read_bytes(path)
        if fault == 'archive-exists': self.archive.mkdir()
        with patch.dict(os.environ, self.env), \
             patch.object(runner, 'run', side_effect=capture), \
             patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(runner.os, 'killpg', side_effect=group_absence), \
             patch.object(Path, 'read_bytes', new=archive_read):
            status = runner.run_with_session(launch, terminate, self.trace, self.receipt, 4,
                identity, console_launcher_stop=True, session=self.session)
        return status, captures, group_calls, first

    def test_replay_keeps_original_bytes_and_only_the_remaining_aggregate_bound(self):
        status, captures, groups, first = self.wrapper_capture()
        self.assertEqual(status, 0)
        self.assertEqual(len(captures), 2)
        self.assertEqual(captures[0][0][4], 4)
        self.assertEqual(captures[1][0][4], 3.5)
        self.assertEqual(groups, [(712345, 0)])
        for name, original in first.items():
            self.assertEqual((self.archive / name).read_bytes(), original)
        self.assertFalse(self.marker.exists())

    def test_live_or_unknown_group_absence_prevents_reservation_and_replay(self):
        for fault in ('live-group', 'unknown-group'):
            with self.subTest(fault=fault):
                status, captures, groups, _ = self.wrapper_capture(fault=fault)
                self.assertEqual(status, 1)
                self.assertEqual(len(captures), 1)
                self.assertEqual(groups, [(712345, 0)])
                self.assertEqual(self.flags(), (False, False))
                self.assertFalse(self.archive.exists())

    def test_unbound_receipt_identity_and_launcher_are_never_probed_or_retried(self):
        for fault in ('foreign-identity', 'foreign-launcher'):
            with self.subTest(fault=fault):
                status, captures, groups, _ = self.wrapper_capture(fault=fault)
                self.assertEqual(status, 1)
                self.assertEqual(len(captures), 1)
                self.assertEqual(groups, [])
                self.assertEqual(self.flags(), (False, False))
                self.assertFalse(self.archive.exists())

    def test_deadline_spent_before_proof_does_not_reserve_or_replay(self):
        status, captures, groups, _ = self.wrapper_capture(fault='deadline-before-proof')
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(groups, [])
        self.assertEqual(self.flags(), (False, False))
        self.assertFalse(self.archive.exists())

    def test_archive_failure_spends_the_budget_without_replaying_or_overwriting(self):
        sentinel = self.archive / 'prior-diagnostic'
        self.archive.mkdir(); sentinel.write_bytes(b'retain prior evidence')
        # The existing directory makes the recovery owner's exclusive mkdir fail.
        status, captures, _, first = self.wrapper_capture()
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(self.flags(), (True, False))
        self.assertEqual(sentinel.read_bytes(), b'retain prior evidence')
        for path in (self.trace, self.receipt):
            self.assertEqual(path.read_bytes(), first[path.name])
        self.assertTrue(self.marker.exists())

    def test_late_checkpoint_prevents_replay_after_the_shared_budget_was_reserved(self):
        status, captures, _, _ = self.wrapper_capture(fault='late-checkpoint')
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(self.flags(), (True, True))
        self.assertTrue(self.marker.exists())

    def test_late_filesystem_or_archive_mutation_never_replays(self):
        status, captures, _, _ = self.wrapper_capture(fault='late-output')
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(self.flags(), (True, False))
        self.assertEqual(self.trace.read_bytes(), b'late app evidence')
        self.assertTrue(self.marker.exists())

    def test_archive_integrity_is_rechecked_before_replay(self):
        status, captures, _, _ = self.wrapper_capture(fault='changed-archive')
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(self.flags(), (True, False))
        self.assertTrue(self.marker.exists())

    def test_archiving_consumes_the_original_deadline_without_a_new_allowance(self):
        status, captures, _, _ = self.wrapper_capture(fault='deadline-during-archive')
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(self.flags(), (True, False))
        self.assertTrue(self.archive.exists())
        self.assertTrue(self.marker.exists())

    def test_busy_session_lock_refuses_reservation_without_waiting_for_recovery(self):
        # Session was attached before the independent lifecycle writer took its
        # lock; retry reservation itself must fail closed within this capture.
        with self.holding_session_lock():
            started = time.perf_counter()
            status, captures, groups, _ = self.wrapper_capture()
            elapsed = time.perf_counter() - started
        self.assertLess(elapsed, 1, 'shared retry reservation waited for the lifecycle lock')
        self.assertEqual(status, 1)
        self.assertEqual(len(captures), 1)
        self.assertEqual(groups, [(712345, 0)])
        self.assertEqual(self.flags(), (False, False))
        self.assertFalse(self.archive.exists())
        self.assertTrue(self.marker.exists())

    def test_busy_checkpoint_lock_cleans_the_live_host_launcher_without_replay(self):
        identity = dict(runID='host-recovery', simulatorID=SIMULATOR,
                        scenario='host-recovery-case', bundleID=BUNDLE)
        launch = ['xcrun', 'simctl', 'launch', '--console', SIMULATOR, BUNDLE]
        terminate = ['xcrun', 'simctl', 'terminate', SIMULATOR, BUNDLE]
        with self.holding_session_lock(), patch.dict(os.environ, self.env, FAKE_CONSOLE_MODE='success'):
            started = time.perf_counter()
            status = runner.run_with_session(launch, terminate, self.trace, self.receipt, .3,
                identity, console_launcher_stop=True, session=self.session)
            elapsed = time.perf_counter() - started
        self.assertLess(elapsed, 2, 'app evidence waited for the lifecycle lock')
        self.assertEqual(status, 1)
        self.assertEqual(len(self.launches()), 1)
        self.assertEqual(self.flags(), (False, False))
        self.assertFalse(self.archive.exists())
        pid = int((self.root / 'launch-pid').read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertFalse(self.evidence()['success'])
        self.assertTrue(self.marker.exists())

    def test_no_session_preserves_the_existing_capture_call_without_an_outer_clock(self):
        identity = dict(bundleID=BUNDLE)
        launch, terminate = ['synthetic-launch'], ['synthetic-stop']
        with patch.object(runner, 'run', return_value=73) as capture, \
             patch.object(runner.time, 'monotonic', side_effect=AssertionError('unexpected outer clock')):
            status = runner.run_with_session(launch, terminate, self.trace, self.receipt, 4,
                identity, console_launcher_stop=True, inherit_launcher_group=True)
        self.assertEqual(status, 73)
        capture.assert_called_once_with(launch, terminate, self.trace, self.receipt, 4, identity,
            console_launcher_stop=True, inherit_launcher_group=True)


if __name__ == '__main__':
    unittest.main()
