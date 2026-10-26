#!/usr/bin/env python3
"""Host controls for failed process teardown and the shared no-replay barrier."""
from contextlib import ExitStack
import errno
import json
import linecache
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
COMMAND = ['xcrun', 'simctl', 'boot', DEVICE]


class Stream:
    def __init__(self, calls, name, error=None):
        self.calls, self.name, self.error = calls, name, error

    def close(self):
        self.calls.append(self.name)
        if self.error:
            raise self.error


class Process:
    pid = 987654321  # Every signal is mocked; this is never a real host target.

    def __init__(self, *, status=None, communication=None, close_error=None, reap_error=None):
        self.calls, self.returncode = [], status
        self.communication, self.reap_error = communication, reap_error
        self.stdout = Stream(self.calls, 'stdout-close', close_error)
        self.stderr = Stream(self.calls, 'stderr-close', close_error)

    def communicate(self, timeout):
        self.calls.append(('communicate', timeout))
        if self.communication:
            raise self.communication
        return b'output', b'error'

    def wait(self, timeout):
        self.calls.append(('wait', timeout))
        if self.reap_error:
            raise self.reap_error
        self.returncode = self.returncode if self.returncode is not None else -9
        return self.returncode


class BoundedCleanupTests(unittest.TestCase):
    def invoke(self, process, *, denied=False, pending=None, restore_error=None, mask_error=None):
        handlers = {signal.SIGTERM: signal.SIG_DFL, signal.SIGINT: signal.SIG_DFL}
        original = dict(handlers)
        restore_calls, mask_calls = [], []

        def set_mask(operation, mask):
            if operation == signal.SIG_SETMASK:
                mask_calls.append(operation)
                if mask_error and len(mask_calls) > 1:
                    raise mask_error
            return set()

        def set_handler(signum, handler):
            if handler == original[signum]:
                restore_calls.append(signum)
                if restore_error:
                    raise restore_error
            previous, handlers[signum] = handlers[signum], handler
            return previous

        def communicate(timeout):
            if pending:
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            return Process.communicate(process, timeout)

        with ExitStack() as stack:
            stack.enter_context(patch.object(sim.subprocess, 'Popen', return_value=process))
            kill = stack.enter_context(patch.object(sim.os, 'killpg', side_effect=
                PermissionError(errno.EPERM, 'denied') if denied else None))
            stack.enter_context(patch.object(sim.signal, 'pthread_sigmask', side_effect=set_mask))
            stack.enter_context(patch.object(sim.signal, 'getsignal', side_effect=handlers.get))
            stack.enter_context(patch.object(sim.signal, 'signal', side_effect=set_handler))
            stack.enter_context(patch.object(process, 'communicate', side_effect=communicate))
            stack.enter_context(patch.object(sim.time, 'monotonic', side_effect=[0, 0, 1]))
            report = stack.enter_context(patch.object(sim, 'summary'))
            try:
                return sim.bounded(['host-fixture'], .01), kill, report, restore_calls
            finally:
                self.last_mask_calls = mask_calls
                if mask_error:
                    self.assertEqual(len(mask_calls), 3)
                self.assertIn('stdout-close', process.calls)
                self.assertIn('stderr-close', process.calls)
                self.assertIn(('wait', 2), process.calls)
                for call in kill.call_args_list:
                    self.assertEqual(call.args, (process.pid, signal.SIGKILL))

    def test_timeout_eperm_preserves_capture_and_attempts_all_cleanup(self):
        process = Process(communication=subprocess.TimeoutExpired('fixture', .01,
            output=b'partial', stderr=b'error'), close_error=OSError('close'),
            reap_error=subprocess.TimeoutExpired('fixture', 2))
        result, kill, report, _ = self.invoke(process, denied=True)
        self.assertEqual((result.returncode, result.timed_out, result.stdout, result.stderr),
                         (124, True, b'partial', b'error'))
        self.assertTrue(result.cleanup_uncertain)
        self.assertFalse(result.reaped)
        self.assertEqual(kill.call_count, 2)
        self.assertIn(('communicate', 2), process.calls)
        self.assertIn('killpg:PermissionError', result.cleanup_errors)
        self.assertIn('child reaped=false', report.call_args.args[1])

    def test_reaped_leader_does_not_prove_group_cleanup_after_eperm(self):
        process = Process(communication=subprocess.TimeoutExpired('fixture', .01))
        result, _, _, _ = self.invoke(process, denied=True)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(result.reaped)
        self.assertTrue(result.cleanup_uncertain)

    def test_close_and_reap_faults_never_turn_success_into_success(self):
        process = Process(status=0, close_error=ValueError('closed'), reap_error=OSError('wait'))
        result, _, _, _ = self.invoke(process)
        self.assertEqual(result.returncode, 125)
        self.assertEqual(result.stdout, b'output')
        self.assertFalse(result.reaped)
        self.assertTrue(result.cleanup_uncertain)

    def test_command_status_is_preserved_despite_cleanup_failure(self):
        result, _, _, _ = self.invoke(Process(status=73, close_error=RuntimeError('close')))
        self.assertEqual(result.returncode, 73)
        self.assertTrue(result.cleanup_uncertain)

    def test_primary_exception_identity_survives_cleanup_and_pending_cancellation(self):
        for primary in (RuntimeError('command'), OSError('command'),
                        sim.Interrupted(signal.SIGINT), KeyboardInterrupt(), SystemExit(43)):
            with self.subTest(primary=type(primary).__name__):
                process = Process(communication=primary, close_error=OSError('close'),
                                  reap_error=OSError('wait'))
                with self.assertRaises(type(primary)) as caught:
                    self.invoke(process, denied=True, pending=True)
                self.assertIs(caught.exception, primary)
                self.assertTrue(primary.cleanup_uncertain)
                self.assertFalse(primary.reaped)

    def test_persistent_handler_restore_faults_are_finite_and_force_failure(self):
        process = Process(status=0)
        started = time.monotonic()
        result, _, _, restore_calls = self.invoke(process, restore_error=OSError('signal'))
        self.assertLess(time.monotonic() - started, .5)
        self.assertEqual(restore_calls, [signal.SIGTERM, signal.SIGINT] * 2)
        self.assertEqual(result.returncode, 125)
        self.assertTrue(result.cleanup_uncertain)

    def test_persistent_mask_restore_failure_is_finite_and_reported(self):
        result, _, _, _ = self.invoke(Process(status=0), mask_error=RuntimeError('mask'))
        self.assertEqual(result.returncode, 125)
        self.assertIn('restore-mask:RuntimeError', result.cleanup_errors)

    def test_control_exception_during_close_is_not_swallowed(self):
        for primary in (KeyboardInterrupt(), SystemExit(43), sim.Interrupted(signal.SIGINT)):
            with self.subTest(primary=type(primary).__name__):
                with self.assertRaises(type(primary)) as caught:
                    self.invoke(Process(status=0, close_error=primary))
                self.assertIs(caught.exception, primary)
                self.assertTrue(primary.cleanup_uncertain)

    def test_between_handler_and_mask_restoration_preserves_primary_and_restores_mask(self):
        primary, cancellation = RuntimeError('command'), sim.Interrupted(signal.SIGTERM)
        injected = []
        def trace(frame, event, argument):
            if (event == 'line' and frame.f_code is sim.bounded.__code__ and not injected
                    and linecache.getline(sim.__file__, frame.f_lineno).strip() == 'if len(faults) == count:'):
                injected.append(True)
                raise cancellation
            return trace
        try:
            sys.settrace(trace)
            with self.assertRaises(RuntimeError) as caught:
                self.invoke(Process(communication=primary))
            self.assertIs(caught.exception, primary)
            self.assertTrue(injected)
            self.assertEqual(len(self.last_mask_calls), 2, 'original mask was not restored')
            self.assertIn('teardown:Interrupted', primary.cleanup_errors)
        finally:
            sys.settrace(None)

    def test_real_host_child_eperm_timeout_has_finite_cleanup_and_honest_unreaped_result(self):
        # This toy Python child is owned by this test. The production kill path
        # is denied; the test independently kills and reaps its own child after.
        children = []
        popen, killpg = subprocess.Popen, os.killpg

        def capture(*args, **kwargs):
            child = popen(*args, **kwargs)
            children.append(child)
            return child

        try:
            with patch.object(sim.subprocess, 'Popen', side_effect=capture), \
                 patch.object(sim.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'denied')), \
                 patch.object(sim, 'summary'):
                started = time.monotonic()
                result = sim.bounded([sys.executable, '-c', 'import time;time.sleep(30)'], .05)
                elapsed = time.monotonic() - started
            self.assertGreater(elapsed, 3.8)
            self.assertLess(elapsed, 5.5)
            self.assertEqual(result.returncode, 124)
            self.assertTrue(result.timed_out)
            self.assertTrue(result.cleanup_uncertain)
            self.assertFalse(result.reaped)
            self.assertIsNone(children[0].poll())
        finally:
            for child in children:
                try:
                    killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=2)


class UncertainSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sim-uncertain-host-')
        self.path = Path(self.temp.name) / 'state.json'
        self.calls = []
        self.outcome = None
        self.session = sim.Session(self.path, runner=self.run_command)
        self.session.call(['xcrun', 'simctl', 'create', 'fixture', 'device', 'runtime'], 30)

    def tearDown(self):
        self.temp.cleanup()

    def run_command(self, command, timeout):
        self.calls.append(list(command))
        if command[2] == 'create':
            return sim.Result(command, 0, DEVICE.encode())
        if self.outcome is not None:
            outcome, self.outcome = self.outcome, None
            if isinstance(outcome, BaseException):
                raise outcome
            return outcome
        return sim.Result(command, 0)

    @staticmethod
    def unknown(status=124):
        return sim.Result(COMMAND, status, timed_out=True, cleanup_uncertain=True,
                          cleanup_errors=('killpg:PermissionError', 'reap:TimeoutExpired'), reaped=False)

    def assert_barrier(self):
        state = json.loads(self.path.read_text())
        self.assertTrue(state['checkpoint'])
        self.assertFalse(state['retry_used'])
        resumed = sim.Session.resume(self.path, runner=self.run_command)
        self.assertFalse(resumed.reserve_retry())
        self.assertFalse(self.session.reserve_retry())
        self.assertEqual(len(self.calls), 2)

    def test_preparation_uncertainty_is_final_infra_without_spending_or_replay(self):
        for step in ('boot', 'bootstatus', 'install', 'launch'):
            with self.subTest(step=step), patch.object(sim, 'report_failure') as report:
                self.path = Path(self.temp.name) / (step + '.json')
                self.calls = []
                self.session = sim.Session(self.path, runner=self.run_command)
                self.session.call(['xcrun', 'simctl', 'create', 'fixture', 'device', 'runtime'], 30)
                self.outcome = result = self.unknown()
                command = ['xcrun', 'simctl', step, DEVICE]
                command += {'bootstatus': ['-b'], 'install': ['app'], 'launch': ['bundle']}.get(step, [])
                self.assertIs(self.session.call(command, 60), result)
                self.assertTrue(result.failure_classified)
                self.assertEqual(report.call_args.args[0], 'infra:' + step)
                self.assertFalse(any('product:' in call.args[0] for call in report.call_args_list))
                self.assert_barrier()

    def test_uncertain_zero_is_forced_failure_before_product_launch_classification(self):
        self.outcome = result = self.unknown(0)
        result.stdout = b'bundle: 1234'
        with patch.object(sim, 'report_failure') as report:
            self.assertIs(self.session.call(['xcrun', 'simctl', 'launch', DEVICE, 'bundle'], 20), result)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report.call_args.args[0], 'infra:launch')
        self.assert_barrier()

    def test_cancellation_identity_survives_and_persists_no_replay_barrier(self):
        for primary in (sim.Interrupted(signal.SIGTERM), KeyboardInterrupt(), SystemExit(43)):
            with self.subTest(primary=type(primary).__name__), patch.object(sim, 'report_failure'):
                self.path = Path(self.temp.name) / (type(primary).__name__ + '.json')
                self.calls = []
                self.session = sim.Session(self.path, runner=self.run_command)
                self.session.call(['xcrun', 'simctl', 'create', 'fixture', 'device', 'runtime'], 30)
                primary.cleanup_uncertain, primary.reaped = True, False
                self.outcome = primary
                with self.assertRaises(type(primary)) as caught:
                    self.session.call(COMMAND, 60)
                self.assertIs(caught.exception, primary)
                self.assert_barrier()

    def test_failed_barrier_write_preserves_original_and_blocks_local_retry(self):
        for primary in (self.unknown(), sim.Interrupted(signal.SIGTERM)):
            self.calls = self.calls[:1]
            primary.cleanup_uncertain = True
            self.outcome = primary
            with patch.object(self.session, 'checkpoint', side_effect=OSError('disk')), \
                 patch.object(sim, 'report_failure'), patch.object(sim, 'summary') as summary:
                if isinstance(primary, BaseException):
                    with self.assertRaises(type(primary)) as caught:
                        self.session.call(COMMAND, 60)
                    self.assertIs(caught.exception, primary)
                else:
                    self.assertIs(self.session.call(COMMAND, 60), primary)
            self.assertFalse(primary.cleanup_barrier_saved)
            self.assertFalse(self.session.reserve_retry())
            self.assertIn('persistence unknown', summary.call_args.args[1])

    def test_disappeared_state_cannot_replace_the_original_uncertain_failure(self):
        self.outcome = result = self.unknown()
        runner = self.session.runner
        def disappear(command, timeout):
            outcome = runner(command, timeout)
            self.path.unlink()
            return outcome
        self.session.runner = disappear
        with patch.object(sim, 'report_failure'), patch.object(sim, 'summary') as summary:
            self.assertIs(self.session.call(COMMAND, 60), result)
        self.assertFalse(result.cleanup_barrier_saved)
        self.assertFalse(self.session.reserve_retry())
        self.assertIn('persistence unknown', summary.call_args.args[1])

    def test_malformed_state_preserves_primary_and_blocks_recovery(self):
        for malformed in ({}, []):
            for primary in (self.unknown(), RuntimeError('command'),
                            sim.Interrupted(signal.SIGTERM), KeyboardInterrupt(), SystemExit(43)):
                with self.subTest(state=malformed, primary=type(primary).__name__), ExitStack() as stack:
                    native = [stack.enter_context(patch.object(subprocess, name,
                        side_effect=AssertionError('native services are forbidden')))
                        for name in ('Popen', 'run')]
                    self.calls = []
                    self.path = Path(self.temp.name) / f'{type(malformed).__name__}-{type(primary).__name__}.json'
                    self.session = sim.Session(self.path, runner=self.run_command)
                    self.session.call(['xcrun', 'simctl', 'create', 'fixture', 'device', 'runtime'], 30)
                    primary.cleanup_uncertain, primary.reaped = True, False
                    primary.cleanup_errors = ('killpg:PermissionError',)
                    self.outcome = primary

                    def corrupt(command, timeout):
                        self.path.write_text(json.dumps(malformed))
                        return self.run_command(command, timeout)

                    self.session.runner = corrupt
                    recovery = [stack.enter_context(patch.object(self.session, name,
                        wraps=getattr(self.session, name)))
                        for name in ('reserve_retry', 'replacement', 'create', 'cleanup')]
                    report = stack.enter_context(patch.object(sim, 'report_failure'))
                    summary = stack.enter_context(patch.object(sim, 'summary'))
                    if isinstance(primary, BaseException):
                        with self.assertRaises(type(primary)) as caught:
                            self.session.call(COMMAND, 60)
                        self.assertIs(caught.exception, primary)
                    else:
                        self.assertIs(self.session.call(COMMAND, 60), primary)
                        self.assertEqual((primary.returncode, primary.timed_out), (124, True))
                    self.assertIs(self.session._host_cleanup_failure, primary)
                    self.assertTrue(primary.failure_classified)
                    self.assertFalse(primary.cleanup_barrier_saved)
                    self.assertEqual(primary.cleanup_errors, ('killpg:PermissionError',))
                    self.assertFalse(primary.reaped)
                    self.assertEqual(report.call_args.args[0], 'infra:boot')
                    self.assertIn('persistence unknown', summary.call_args.args[1])
                    self.assertEqual(json.loads(self.path.read_text()), malformed)
                    for operation in recovery:
                        operation.assert_not_called()
                    self.assertFalse(self.session.reserve_retry())
                    self.assertEqual([command[2] for command in self.calls], ['create', 'boot'])
                    for operation in native:
                        operation.assert_not_called()

    def test_checkpoint_cancellation_is_not_treated_as_an_ordinary_persistence_error(self):
        for cancellation in (KeyboardInterrupt(), SystemExit(43), sim.Interrupted(signal.SIGINT)):
            with self.subTest(cancellation=type(cancellation).__name__):
                self.calls = self.calls[:1]
                self.outcome = self.unknown()
                with patch.object(self.session, 'checkpoint', side_effect=cancellation), \
                     patch.object(sim, 'report_failure') as report:
                    with self.assertRaises(type(cancellation)) as caught:
                        self.session.call(COMMAND, 60)
                self.assertIs(caught.exception, cancellation)
                report.assert_not_called()
                self.assertFalse(self.session.reserve_retry())
                self.assertEqual([command[2] for command in self.calls], ['create', 'boot'])

    def test_reporting_io_faults_preserve_result_and_exception_identity(self):
        for primary in (self.unknown(), sim.Interrupted(signal.SIGTERM)):
            with self.subTest(primary=type(primary).__name__):
                self.calls = self.calls[:1]
                primary.cleanup_uncertain = True
                self.outcome = primary
                with patch.object(self.session, 'checkpoint', side_effect=OSError('disk')), \
                     patch.object(sim, 'summary', side_effect=ValueError('closed')), \
                     patch.object(sim, 'report_failure', side_effect=OSError('report')):
                    if isinstance(primary, BaseException):
                        with self.assertRaises(type(primary)) as caught:
                            self.session.call(COMMAND, 60)
                        self.assertIs(caught.exception, primary)
                    else:
                        self.assertIs(self.session.call(COMMAND, 60), primary)
                self.assertFalse(primary.cleanup_barrier_saved)
                self.assertTrue(primary.failure_classified)
                self.assertFalse(self.session.reserve_retry())

    def test_independent_uncertain_commands_keep_their_own_cleanup_evidence(self):
        first, second = self.unknown(), self.unknown()
        first.reaped, first.cleanup_errors = True, ('killpg:PermissionError',)
        second.cleanup_errors = ('reap:TimeoutExpired',)
        with patch.object(sim, 'report_failure'):
            self.outcome = first
            self.session.execute(COMMAND, 60)
            self.outcome = second
            self.session.execute(COMMAND, 60)
        self.assertTrue(first.reaped)
        self.assertFalse(second.reaped)
        self.assertEqual(second.cleanup_errors, ('reap:TimeoutExpired',))

    def test_cli_cancellation_status_survives_disappeared_state_and_cleanup_failure(self):
        primary = sim.Interrupted(signal.SIGTERM)
        primary.cleanup_uncertain, primary.reaped = True, False
        def disappear(command, timeout):
            self.calls.append(list(command))
            self.path.unlink()
            raise primary
        self.session.runner = disappear
        with patch.object(sim, 'Session', return_value=self.session), \
             patch.object(sim.signal, 'signal'), patch.object(sim, 'summary') as summary, \
             patch.object(sim, 'report_failure'):
            status = sim.main(['call', str(self.path), '60', *COMMAND])
        self.assertEqual(status, 143)
        self.assertFalse(primary.cleanup_barrier_saved)
        self.assertTrue(primary.failure_classified)
        self.assertFalse(self.session.reserve_retry())
        self.assertIn('cancellation cleanup uncertain', summary.call_args.args[1])
        self.assertEqual(len(self.calls), 2, 'no native recovery may follow unknown cancellation')

    def test_uncertain_create_keeps_exact_reserved_name_and_never_retries(self):
        with tempfile.TemporaryDirectory() as root:
            calls = []
            result = self.unknown(0)
            result.stdout = DEVICE.encode()
            owner = sim.Session(Path(root) / 'state.json', runner=lambda command, timeout:
                                (calls.append(command) or result))
            with patch.object(sim, 'report_failure'):
                self.assertIs(owner.call(['xcrun', 'simctl', 'create', 'fixture', 'device', 'runtime'], 30), result)
            self.assertEqual(len(calls), 1)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(owner.reserve_retry())
            resumed = sim.Session.resume(owner.path, runner=self.run_command)
            self.assertFalse(resumed.reserve_retry())
            self.assertIsNone(owner.current)
            self.assertTrue(owner.state['owned'][0]['uncertain'])
            self.assertEqual(owner.state['owned'][0]['name'], calls[0][3])

    def test_uncertain_cleanup_during_recovery_preserves_original_without_replacement(self):
        original = sim.Result(COMMAND, 73)
        unknown = self.unknown()
        results = iter((original, unknown, sim.Result([], 0)))
        self.session.runner = lambda command, timeout: (self.calls.append(command) or next(results))
        with patch.object(sim, 'report_failure'):
            result = self.session.call(COMMAND, 60)
        self.assertIs(result, original)
        self.assertTrue(result.cleanup_uncertain)
        self.assertEqual([call[2] for call in self.calls], ['create', 'boot', 'shutdown', 'delete'])
        self.assertTrue(sim.Session.resume(self.path).state['checkpoint'])
