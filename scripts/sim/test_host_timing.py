#!/usr/bin/env python3
"""Observational host timing controls; no simulator or native command runs."""
from contextlib import ExitStack
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_scenario


BUNDLE = 'dev.iosvoipsdk.host-timing-control'
BASE_FIELDS = dict(schemaVersion=1, source='supervisor', monotonicNS=123456789,
                   wallTimeNS=987654321, hostPID=1234)


class HostTimingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='host-timing-control-')
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / 'capture.log'
        self.sidecar = Path(str(self.output) + '.host-timing.jsonl')
        for target, value in (('monotonic_ns', 123456789), ('time_ns', 987654321)):
            mock = patch.object(run_scenario.time, target, return_value=value)
            mock.start(); self.addCleanup(mock.stop)
        pid = patch.object(run_scenario.os, 'getpid', return_value=1234)
        pid.start(); self.addCleanup(pid.stop)
        deadline = patch.object(run_scenario.time, 'monotonic',
                                side_effect=AssertionError('diagnostics consumed the deadline clock'))
        deadline.start(); self.addCleanup(deadline.stop)

    def rows(self):
        return [json.loads(line) for line in self.sidecar.read_text().splitlines()]

    def test_records_are_buffered_until_flush_with_integer_clock_identity(self):
        timing = run_scenario.HostTiming(self.output, 'supervisor')
        timing.record('supervisor.start')
        self.assertFalse(self.sidecar.exists(), 'timing IO must wait until capture has ended')
        timing.flush()
        self.assertEqual(self.rows(), [dict(BASE_FIELDS, event='supervisor.start')])
        self.assertEqual(self.sidecar.stat().st_mode & 0o777, 0o600)

    def test_whitelist_retains_only_finite_numeric_metadata(self):
        timing = run_scenario.HostTiming(self.output, 'supervisor')
        timing.record('numeric', pid=45, appWallTimeMS=2000, appElapsedMS=3,
                      timeoutSeconds=0.25, deadlineMonotonicNS=8000,
                      returncode=-15, byteCount=42,
                      argv=['untrusted-secret'], env={'TOKEN': 'untrusted-secret'},
                      raw={'secret': 'untrusted-secret'}, success=True)
        timing.record('invalid', pid=True, appWallTimeMS='2000', appElapsedMS=None,
                      timeoutSeconds=float('nan'), deadlineMonotonicNS=float('inf'),
                      returncode=float('-inf'), byteCount={})
        timing.flush()
        self.assertEqual(self.rows(), [dict(BASE_FIELDS, event='numeric', pid=45,
            appWallTimeMS=2000, appElapsedMS=3, timeoutSeconds=0.25,
            deadlineMonotonicNS=8000, returncode=-15, byteCount=42),
            dict(BASE_FIELDS, event='invalid')])
        self.assertNotIn('untrusted-secret', self.sidecar.read_text())

    def test_first_observation_is_retained_once_and_buffer_is_bounded(self):
        timing = run_scenario.HostTiming(self.output, 'supervisor')
        timing.first('read.pid', pid=45)
        for unused in range(1000):
            timing.first('read.pid', pid=99)
        for index in range(1000):
            timing.record('sample', byteCount=index)
        timing.flush()
        rows = self.rows()
        self.assertEqual(len(rows), 128)
        self.assertEqual(rows[0], dict(BASE_FIELDS, event='read.pid', pid=45))
        self.assertEqual(rows[-1], dict(BASE_FIELDS, event='sample', byteCount=126))

    def test_bound_pid_and_selected_probe_rows_are_first_observations_only(self):
        timing = run_scenario.HostTiming(self.output, 'supervisor', BUNDLE)
        timing.observe_line((BUNDLE + ': 45\r\n').encode(), 'read')
        timing.observe_line((BUNDLE + ': 99\n').encode(), 'read')
        for event in ('app.entry', 'launch', 'livekit.readyForFault'):
            row = dict(event=event, pid=45, wallTimeMS=2000, t_ms=3,
                       runID='untrusted-secret', secret={'arbitrary': 'untrusted-secret'})
            timing.observe_line(b'console prefix PROBE ' + json.dumps(row).encode() + b'\n', 'read')
            timing.observe_row(dict(row, pid=99), 'read')
            timing.observe_row(row, 'consume')
        timing.flush()
        expected = [dict(BASE_FIELDS, event='read.pid', pid=45)]
        for event in ('app.entry', 'launch', 'livekit.readyForFault'):
            for stage in ('read', 'consume'):
                expected.append(dict(BASE_FIELDS, event=stage + '.' + event, pid=45,
                                     appWallTimeMS=2000, appElapsedMS=3))
        self.assertEqual(self.rows(), expected)
        self.assertNotIn('untrusted-secret', self.sidecar.read_text())

    def test_unrelated_malformed_or_untyped_probe_input_never_qualifies(self):
        timing = run_scenario.HostTiming(self.output, 'supervisor', BUNDLE)
        for line in (b'', b'PROBE broken', b'PROBE \xff', b'PROBE null', b'PROBE []',
                     b'PROBE true', b'PROBE {"event":"done","success":true}',
                     b'PROBE {"event":{"launch":true}}',
                     b'foreign.bundle: 45\n', b'prefix ' + BUNDLE.encode() + b': 45\n'):
            timing.observe_line(line, 'read')
        for row in (None, [], True, 12, 'launch', {}, {'event': ['launch']},
                    {'event': 'done', 'success': True}):
            timing.observe_row(row, 'consume')
        timing.observe_row(dict(event='launch', pid=True, wallTimeMS='2000', t_ms=None,
                                success=True, completed=True), 'consume')
        timing.flush()
        self.assertEqual(self.rows(), [dict(BASE_FIELDS, event='consume.launch')])

    def test_diagnostic_parser_or_observer_fault_keeps_action_outcome(self):
        for target, fault in (('parser', RecursionError('deep diagnostic input')),
                              ('observer', RuntimeError('diagnostic observer unavailable'))):
            with self.subTest(target=target):
                timing = run_scenario.HostTiming(self.output, 'supervisor')
                guard = (patch.object(run_scenario.json, 'loads', side_effect=fault) if target == 'parser'
                         else patch.object(timing, 'observe_row', side_effect=fault))
                value, primary = object(), RuntimeError('original checkpoint failure')
                def observe():
                    timing.observe_line(b'PROBE {"event":"launch"}', 'read')
                    return value
                def fail():
                    observe()
                    raise primary
                with guard:
                    self.assertIs(timing.checkpoint('launch', observe, 90), value)
                    with self.assertRaises(RuntimeError) as caught:
                        timing.checkpoint('launch', fail, 90)
                    self.assertIs(caught.exception, primary)
                timing.flush()
                self.assertNotIn('read.launch', [row['event'] for row in self.rows()])

    def test_driver_and_supervisor_append_independent_buffers(self):
        supervisor = run_scenario.HostTiming(self.output, 'supervisor')
        driver = run_scenario.HostTiming(self.output, 'driver')
        supervisor.first('read.launch', pid=45)
        driver.first('poll.launch', pid=45)
        self.assertFalse(self.sidecar.exists())
        driver.flush()
        supervisor.flush()
        self.assertEqual(self.rows(), [dict(BASE_FIELDS, source='driver', event='poll.launch', pid=45),
                                      dict(BASE_FIELDS, event='read.launch', pid=45)])

    def test_checkpoint_returns_the_same_action_result(self):
        value = object()
        timing = run_scenario.HostTiming(self.output, 'supervisor')
        self.assertIs(timing.checkpoint('launch', lambda: value, 90), value)
        timing.flush()
        self.assertEqual(self.rows(), [dict(BASE_FIELDS, event='launch.checkpoint.start', timeoutSeconds=90),
                                      dict(BASE_FIELDS, event='launch.checkpoint.observed')])

    def test_checkpoint_preserves_timeout_failure_and_interrupt_exception_identity(self):
        exceptions = (RuntimeError('fixture checkpoint deadline'),
                      RuntimeError('other fixture failure'),
                      subprocess.TimeoutExpired('synthetic', 90), SystemExit(143), KeyboardInterrupt())
        for error in exceptions:
            with self.subTest(error=type(error).__name__, message=str(error)):
                timing = run_scenario.HostTiming(self.output, 'supervisor')
                def action():
                    raise error
                with self.assertRaises(type(error)) as caught:
                    timing.checkpoint('launch', action, 90)
                self.assertIs(caught.exception, error)
                timing.flush()
                outcome = 'timeout' if type(error) is RuntimeError and str(error) == 'fixture checkpoint deadline' else 'failure'
                self.assertEqual(self.rows()[-2:], [dict(BASE_FIELDS, event='launch.checkpoint.start', timeoutSeconds=90),
                    dict(BASE_FIELDS, event='launch.checkpoint.' + outcome)])

    def test_clock_failure_does_not_replace_action_result_or_primary_exception(self):
        for clock in ('monotonic_ns', 'time_ns'):
            with self.subTest(clock=clock), patch.object(run_scenario.time, clock, side_effect=OSError('clock unavailable')):
                timing = run_scenario.HostTiming(self.output, 'supervisor')
                value = object()
                self.assertIs(timing.checkpoint('launch', lambda: value, 90), value)
                error = SystemExit(143)
                def interrupted():
                    raise error
                with self.assertRaises(SystemExit) as caught:
                    timing.checkpoint('launch', interrupted, 90)
                self.assertIs(caught.exception, error)
                timing.flush()
                self.assertEqual(self.rows(), [])

    def test_context_flush_failure_does_not_replace_product_exception(self):
        for target in ('open', 'write'):
            with self.subTest(target=target):
                error = SystemExit(143)
                with patch.object(run_scenario.os, target, side_effect=OSError('timing storage unavailable')):
                    with self.assertRaises(SystemExit) as caught:
                        with run_scenario.HostTiming(self.output, 'supervisor') as timing:
                            timing.record('capture.failure')
                            raise error
                self.assertIs(caught.exception, error)

    def test_unwritable_diagnostic_path_and_symlink_cannot_change_success(self):
        missing = self.output.parent / 'missing' / 'capture.log'
        with run_scenario.HostTiming(missing, 'supervisor') as timing:
            self.assertEqual(timing.checkpoint('launch', lambda: 'success', 90), 'success')
        target = self.output.parent / 'existing-file'
        target.write_text('original evidence\n')
        self.sidecar.symlink_to(target)
        with run_scenario.HostTiming(self.output, 'supervisor') as timing:
            timing.record('success')
        self.assertEqual(target.read_text(), 'original evidence\n')


class ExistingDriverControlsTests(unittest.TestCase):
    def test_acceptance_controls_keep_their_outcomes_with_native_calls_refused(self):
        import check_swift_livekit
        native = ('subprocess.Popen', 'subprocess.run', 'os.system', 'os.kill', 'os.killpg',
                  'os.fork', 'os.posix_spawn', 'os.posix_spawnp', 'signal.signal')
        with ExitStack() as stack:
            for target in native:
                stack.enter_context(patch(target, side_effect=AssertionError('native services forbidden: ' + target)))
            result = check_swift_livekit.controls()
        self.assertTrue(result['success'])
        # The three notification-field mutations retired with that transport.
        self.assertEqual(result['checks'], 148)
        for label in ('launch_at29', 'launch_at31', 'launch_at33', 'launch_never', 'launch_beyond90',
                      'launch_beyond_watchdog', 'launch_early_exit', 'timeout-kills-exact-owned-group', 'unknown-group-never-killed',
                      'owner-exited-no-group-kill', 'launchd-timeout-stops-and-cleans'):
            self.assertIn(label, result['cases'])


    def test_driver_observer_fault_preserves_allowed_and_refused_controls(self):
        with patch.object(run_scenario.HostTiming, 'observe_row',
                          side_effect=RuntimeError('diagnostic observer unavailable')):
            self.test_acceptance_controls_keep_their_outcomes_with_native_calls_refused()

    def test_strict_live_parser_error_keeps_its_original_identity(self):
        import run_swift_livekit as runner
        class Process:
            pid = 123456
            returncode = 0
            def poll(self): return 0
        primary = json.JSONDecodeError('original product parse failure', '?', 0)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with patch.object(runner, 'live', side_effect=primary), \
                 patch.object(runner.HostTiming, 'observe_row', side_effect=RuntimeError('observer fault')), \
                 patch.object(subprocess, 'Popen', return_value=Process()), \
                 patch.object(subprocess, 'run', side_effect=AssertionError('native run forbidden')), \
                 patch.object(runner, 'command', side_effect=AssertionError('native cleanup forbidden')), \
                 patch.object(runner.os, 'killpg', side_effect=ProcessLookupError), \
                 patch.object(runner.signal, 'signal'):
                with self.assertRaises(json.JSONDecodeError) as caught:
                    runner.capture_case(output, output, 'host-only-simulator', '', 'healthy')
        self.assertIs(caught.exception, primary)


if __name__ == '__main__':
    unittest.main()
