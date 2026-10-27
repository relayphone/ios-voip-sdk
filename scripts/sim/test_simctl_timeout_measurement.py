"""Timeout observations must be opt-in, sanitized, and outcome-neutral."""
import importlib.util
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

import sim


class SimulatorTimeoutMeasurementTests(unittest.TestCase):
    def invoke(self, *, operation='launch', mode='timeout', enabled='1', failure=None):
        with tempfile.TemporaryDirectory(prefix='sim-timeout-observe-') as temp:
            root = Path(temp)
            fake = root / 'xcrun'
            fake.write_text('#!/bin/sh\ncase "$SIM_FAKE_MODE" in timeout) exec sleep 5 ;; error) exit 73 ;; *) exit 0 ;; esac\n')
            fake.chmod(0o755)
            output = root / 'summary.md'
            env = {'PATH': str(root) + os.pathsep + os.environ.get('PATH', ''),
                   'SIM_FAKE_MODE': mode, 'CKSIM_RECORD_TIMEOUT_OPERATIONS': enabled,
                   'GITHUB_STEP_SUMMARY': str(output)}
            with patch.dict(os.environ, env), patch.object(sim, 'summary', wraps=sim.summary, side_effect=failure) as summary:
                result = sim.bounded(['xcrun', 'simctl', operation, 'private-device', 'private-bundle'], .1 if mode == 'timeout' else 3)
            return result, summary.call_args_list, output.read_text() if output.exists() else ''

    def test_real_timeout_records_only_allowlisted_operation(self):
        result, calls, output = self.invoke()
        self.assertTrue(result.timed_out)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(result.reaped)
        self.assertEqual(len(calls), 1)
        self.assertIn('`measurement:simctl-timeout`: launch', output)
        self.assertNotIn('private-device', output)
        self.assertNotIn('private-bundle', output)

    def test_disabled_or_unknown_operation_never_records(self):
        for options in ({'enabled': '0'}, {'operation': 'secret-operation'}):
            with self.subTest(options=options):
                result, calls, output = self.invoke(**options)
                self.assertTrue(result.timed_out)
                self.assertEqual(calls, [])
                self.assertEqual(output, '')

    def test_success_and_non_timeout_failure_never_record(self):
        for mode, code in (('success', 0), ('error', 73)):
            with self.subTest(mode=mode):
                result, calls, output = self.invoke(mode=mode)
                self.assertFalse(result.timed_out)
                self.assertEqual(result.returncode, code)
                self.assertEqual(calls, [])
                self.assertEqual(output, '')

    def test_runtime_runner_to_phase_summary_preserves_timeout_and_redacts_arguments(self):
        root = Path(__file__).resolve().parents[2]
        def load(name, path):
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        runtime = load('_ci_runtime_runner', root / 'Tests/RuntimeEvents/run.py')
        reporter = load('_ci_runtime_summary', root / 'scripts/ci/runtime_failure_summary.py')
        with tempfile.TemporaryDirectory(prefix='sim-timeout-runner-') as temp:
            temp = Path(temp)
            fake = temp / 'xcrun'
            fake.write_text('#!/bin/sh\nexec sleep 5\n')
            fake.chmod(0o755)
            receipt = temp / 'phase.md'
            env = {'PATH': str(temp) + os.pathsep + os.environ.get('PATH', ''),
                   'CKSIM_RECORD_TIMEOUT_OPERATIONS': '1', 'GITHUB_STEP_SUMMARY': str(receipt)}
            with patch.dict(os.environ, env):
                with self.assertRaises(runtime.CommandError) as caught:
                    runtime.run('xcrun', 'simctl', 'launch', 'private-device', 'private-bundle', timeout=.1)
            self.assertTrue(caught.exception.result.timed_out)
            self.assertEqual(caught.exception.result.returncode, 124)
            report = reporter.render({'inspector': 'failure'}, {'inspector': receipt.read_text()})
            self.assertIn('observed simctl timeouts: `launch`', report)
            self.assertNotIn('private-device', report)
            self.assertNotIn('private-bundle', report)

    def test_diagnostic_failure_preserves_timed_out_result(self):
        result, _, _ = self.invoke(failure=OSError('private-path'))
        self.assertTrue(result.timed_out)
        self.assertEqual(result.returncode, 124)

    def test_cancellation_is_not_suppressed_by_reporting(self):
        with self.assertRaises(sim.Interrupted):
            self.invoke(failure=sim.Interrupted(signal.SIGTERM))


if __name__ == '__main__':
    unittest.main()
