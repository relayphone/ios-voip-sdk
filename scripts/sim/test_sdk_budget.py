#!/usr/bin/env python3
"""SDK startup controls share the parent's budget without native services."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import sim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_sdk_system as runner
import sdk_system_conformance as gate

SIMULATOR = '12345678-1234-4234-8234-123456789ABC'


class SDKSharedBudgetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sim-sdk-shared-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.container = self.root / 'container'
        self.container.mkdir()
        self.package = self.root / 'package'
        self.package.mkdir()
        (self.package / 'fixture').write_text('inert host package')
        self.state = self.root / 'state.json'
        self.session = sim.Session(self.state, runner=lambda command, timeout:
            sim.Result(command, 0, (SIMULATOR + '\n').encode()))
        self.session.call(['xcrun', 'simctl', 'create', 'host-control', 'device', 'runtime'], 1)
        self.args = SimpleNamespace(run_id='host-sdk', simulator=SIMULATOR, package=self.package,
                                   data_container=self.container, output=self.root / 'output',
                                   sim_session=self.session)
        self.environment = patch.dict(os.environ)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        for key in ('SIM_STATE', 'SIM_FAILURE_MARKER', 'GITHUB_STEP_SUMMARY'):
            os.environ.pop(key, None)

    def journey(self, name='case'):
        journey = runner.Journey(self.args, self.root / name, 'decline', self.container)
        journey.runtime.mkdir(parents=True, exist_ok=True)
        return journey

    @contextmanager
    def held_session_lock(self):
        # Use the same stable sibling as independent runner processes do.
        with Path(str(self.state) + '.lock').open('r+') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            def blocked(_signum, _frame):
                raise AssertionError('SDK waited for a contended session lock')
            original = signal.signal(signal.SIGALRM, blocked)
            signal.setitimer(signal.ITIMER_REAL, 2)
            try:
                yield
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, original)

    def startup(self, journey, *, mutate=None, late=None, success_first=False):
        clock, launches, first = [0.0], [], {}
        receipt = journey.root / (journey.name + '.receipt.json')
        command = ['python3', 'run_scenario.py', '--inherit-launcher-group', '--timeout', '120']
        environment = {'host-control': 'preserved'}
        class Process:
            def __init__(self, attempt): self.pid, self.attempt = 7200 + attempt, attempt
            def poll(self): return None if success_first or self.attempt == 2 else 1
        def spawn(argv, **kwargs):
            attempt = len(launches) + 1
            launches.append((list(argv), kwargs))
            self.assertIs(kwargs['env'], environment)
            self.assertTrue(kwargs['start_new_session'])
            self.assertIs(kwargs['stderr'], subprocess.STDOUT)
            self.assertEqual(set(kwargs), {'env', 'stdout', 'stderr', 'start_new_session'})
            process = Process(attempt)
            if attempt == 1 and not success_first:
                clock[0] += .5
                value = dict(schemaVersion=2, completed=False, success=False,
                    runID=self.args.run_id, simulatorID=SIMULATOR, scenario=journey.name, bundleID=runner.BUNDLE,
                    inheritLauncherGroup=True, supervisorPID=process.pid, supervisorPGID=process.pid,
                    supervisorSID=process.pid, launcherPID=7301, launcherPGID=process.pid,
                    consoleTransport='host-pty', stdoutEOFSeconds=.25, elapsedSeconds=.5,
                    launchExitCodeBeforeCleanup=3, launchExitCode=3, cleanupExitCode=3,
                    cleanupStdout='', cleanupStderr=runner.NOT_RUNNING,
                    error='launcher exited before terminal done event',
                    identityError='require one launcher app PID acknowledgement; got 0')
                if mutate:
                    mutate(value, journey)
                journey.trace.write_bytes(runner.PREAPP_ERROR)
                receipt.write_text(json.dumps(value) + '\n')
                kwargs['stdout'].write(b'host supervisor diagnostic\n')
                kwargs['stdout'].flush()
                first.update({path.name: path.read_bytes() for path in
                              (journey.trace, receipt, journey.root / 'supervisor.log')})
            else:
                journey.trace.write_bytes(b'PROBE {"event":"system.ready","pid":7203}\n')
            return process
        original_read = Path.read_bytes
        def read(path):
            result = original_read(path)
            if late and path.parent.name == 'preapp-attempt-1' and path.name == receipt.name:
                late(clock)
            return result
        error = None
        with patch.object(runner.subprocess, 'Popen', side_effect=spawn), \
             patch.object(runner.subprocess, 'run', side_effect=AssertionError('unexpected native command')), \
             patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(runner.time, 'sleep', side_effect=lambda value: clock.__setitem__(0, clock[0] + value)), \
             patch.object(runner.os, 'killpg', side_effect=ProcessLookupError), \
             patch.object(Path, 'read_bytes', new=read):
            try:
                ready = journey.start(command, environment)
            except (OSError, RuntimeError, gate.EvidenceError) as caught:
                error, ready = caught, None
        archive = journey.root / 'preapp-attempt-1'
        if archive.exists():
            for name, content in first.items():
                self.assertEqual((archive / name).read_bytes(), content)
        return launches, ready, error, archive

    def test_shared_reservation_preserves_owned_capture_and_remaining_deadline(self):
        journey = self.journey()
        launches, ready, error, archive = self.startup(journey)
        self.assertIsNone(error)
        self.assertEqual(ready, {'event': 'system.ready', 'pid': 7203})
        self.assertEqual(len(launches), 2)
        self.assertEqual(launches[0][0][-1], '120.0')
        self.assertEqual(launches[1][0][-1], '119.5')
        self.assertTrue(archive.is_dir())
        attached = sim.Session.attach(self.state, SIMULATOR)
        self.assertTrue(attached.is_checkpointed())
        self.assertFalse(attached.reserve_retry())
        self.assertTrue(attached.state['retry_used'])

    def assert_replay_denied(self):
        launches, _, error, archive = self.startup(self.journey())
        self.assertIsNotNone(error)
        self.assertEqual(len(launches), 1)
        self.assertFalse(archive.exists())

    def test_prior_lifecycle_reservation_refuses_sdk_replay(self):
        self.assertTrue(self.session.reserve_retry())
        self.assert_replay_denied()

    def test_prior_checkpoint_refuses_sdk_replay_without_spending_budget(self):
        self.session.checkpoint()
        self.assert_replay_denied()
        self.assertFalse(sim.Session.attach(self.state, SIMULATOR).state['retry_used'])

    def test_contended_shared_reservation_never_waits_or_starts_a_second_supervisor(self):
        self.args.sim_session = sim.Session.attach(self.state, SIMULATOR)
        journey = self.journey()
        before = time.perf_counter()
        with self.held_session_lock():
            launches, ready, error, archive = self.startup(journey)
        self.assertLess(time.perf_counter() - before, 1)
        self.assertIsInstance(error, BlockingIOError)
        self.assertIsNone(ready)
        self.assertEqual(len(launches), 1)
        self.assertEqual(launches[0][0][-1], '120.0')
        self.assertFalse(archive.exists())
        attached = sim.Session.attach(self.state, SIMULATOR)
        self.assertFalse(attached.state['retry_used'])
        self.assertFalse(attached.is_checkpointed())

    def test_contended_checkpoint_fails_promptly_without_qualifying_app_evidence(self):
        self.args.sim_session = sim.Session.attach(self.state, SIMULATOR)
        journey = self.journey()
        journey.trace.write_bytes(b'PROBE {"event":"runtime.installed"}\n')
        before = time.perf_counter()
        with self.held_session_lock(), patch.object(runner.subprocess, 'Popen') as spawn:
            with self.assertRaises(BlockingIOError):
                journey.rows()
        self.assertLess(time.perf_counter() - before, 1)
        spawn.assert_not_called()
        self.assertFalse(journey.checkpoint_observed)
        attached = sim.Session.attach(self.state, SIMULATOR)
        self.assertFalse(attached.state['retry_used'])
        self.assertFalse(attached.is_checkpointed())

    def test_invalid_sdk_proof_never_consumes_shared_reservation(self):
        for field, changed in (('cleanupExitCode', 0), ('supervisorPID', 1),
                               ('appPID', 7203), ('bundleID', 'another.bundle')):
            with self.subTest(field=field):
                journey = self.journey(field)
                launches, _, error, archive = self.startup(journey,
                    mutate=lambda value, _: value.update({field: changed}))
                self.assertIsNotNone(error)
                self.assertEqual(len(launches), 1)
                self.assertFalse(archive.exists())
                self.assertFalse(sim.Session.attach(self.state, SIMULATOR).state['retry_used'])

    def test_late_shared_checkpoint_refuses_replay_without_refunding_reservation(self):
        launches, _, error, archive = self.startup(self.journey(),
            late=lambda _: sim.Session.attach(self.state, SIMULATOR).checkpoint())
        self.assertIsNotNone(error)
        self.assertEqual(len(launches), 1)
        self.assertTrue(archive.is_dir())
        attached = sim.Session.attach(self.state, SIMULATOR)
        self.assertTrue(attached.is_checkpointed())
        self.assertTrue(attached.state['retry_used'])

    def test_ready_first_attempt_latches_checkpoint_across_cases(self):
        launches, ready, error, _ = self.startup(self.journey('first'), success_first=True)
        self.assertIsNone(error)
        self.assertEqual(len(launches), 1)
        self.assertEqual(ready['pid'], 7203)
        launches, _, error, archive = self.startup(self.journey('next'))
        self.assertIsNotNone(error)
        self.assertEqual(len(launches), 1)
        self.assertFalse(archive.exists())
        attached = sim.Session.attach(self.state, SIMULATOR)
        self.assertTrue(attached.is_checkpointed())
        self.assertFalse(attached.state['retry_used'])

    def test_first_probe_latches_before_system_ready(self):
        journey = self.journey()
        journey.trace.write_bytes(b'PROBE {"event":"runtime.installed"}\n')
        self.assertEqual(journey.rows(), [{'event': 'runtime.installed'}])
        self.assertTrue(sim.Session.attach(self.state, SIMULATOR).is_checkpointed())

    def invoke_native_entry(self, *, state=None, environment_state=None):
        self.args.sim_state = state
        if environment_state is not None:
            os.environ['SIM_STATE'] = str(environment_state)
        observed = []
        def journey_run(journey):
            observed.append(journey.args.sim_session)
            if journey.args.sim_session is not None:
                journey.checkpoint()
        with patch.object(runner.m0, 'source_identity', return_value={}), \
             patch.object(gate, 'package_check'), patch.object(runner, 'CASES', ('decline', 'mute-echo')), \
             patch.object(runner.Journey, 'run', new=journey_run), \
             patch.object(runner.subprocess, 'run', side_effect=AssertionError('unexpected native command')):
            runner.run(self.args)
        return observed

    def test_native_entry_attaches_one_context_for_all_cases(self):
        for source in ('argument', 'environment'):
            with self.subTest(source=source):
                self.args.output = self.root / source
                observed = self.invoke_native_entry(
                    state=self.state if source == 'argument' else None,
                    environment_state=self.state if source == 'environment' else None)
                self.assertEqual(len(observed), 2)
                self.assertIs(observed[0], observed[1])
                self.assertIsNotNone(observed[0])
                self.assertFalse(observed[1].reserve_retry())

    def test_native_entry_without_parent_installs_explicit_denial(self):
        observed = self.invoke_native_entry()
        self.assertEqual(observed, [None, None])
        launches, _, error, archive = self.startup(self.journey())
        self.assertIsNotNone(error)
        self.assertEqual(len(launches), 1)
        self.assertFalse(archive.exists())
        self.assertFalse(sim.Session.attach(self.state, SIMULATOR).state['retry_used'])

    def test_invalid_parent_state_is_not_replaced_by_a_new_budget(self):
        absent = self.root / 'missing.json'
        with self.assertRaises((OSError, ValueError)):
            self.invoke_native_entry(state=absent)
        self.assertFalse(absent.exists())
        self.assertFalse(self.args.output.exists())

    def test_explicit_session_path_reaches_owned_capture_child(self):
        journey = self.journey()
        primary = RuntimeError('stop before native capture')
        def start(_journey, command, env):
            self.assertEqual(env['SIM_STATE'], str(self.state))
            self.assertIn('--inherit-launcher-group', command)
            raise primary
        with patch.object(runner.Journey, 'start', new=start), \
             patch.object(runner.subprocess, 'run', side_effect=AssertionError('unexpected native command')):
            with self.assertRaises(RuntimeError) as raised:
                journey.run()
        self.assertIs(raised.exception, primary)


if __name__ == '__main__':
    unittest.main()
