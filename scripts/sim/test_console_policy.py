#!/usr/bin/env python3
"""Pure console-policy and classification controls; no native tools are run."""
from contextlib import redirect_stderr
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import sim

IDENTITY = dict(runID='host-run', simulatorID='host-owned-simulator',
                scenario='sdk-system-decline', bundleID='dev.iosvoipsdk.example')
OWNER = 4200
BUNDLE = IDENTITY['bundleID']
PREAPP_ERROR = (
    'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
    f'Simulator device failed to launch {BUNDLE}.\nNo such process\n'
    'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
    f"\tApplication launch for '{BUNDLE}' did not return a process handle nor launch error.\n"
    '\tNo such process\n').encode()
NOT_RUNNING = (
    'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
    f'Simulator device failed to terminate {BUNDLE}.\nfound nothing to terminate\n'
    'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
    f'\tThe request to terminate "{BUNDLE}" failed. found nothing to terminate\n\tfound nothing to terminate\n')


def receipt():
    return dict(IDENTITY, completed=False, success=False,
        error='launcher exited before terminal done event',
        identityError='require one launcher app PID acknowledgement; got 0',
        launchExitCodeBeforeCleanup=3, launchExitCode=3, stdoutEOFSeconds=.25,
        cleanupExitCode=3, cleanupStdout='', cleanupStderr=NOT_RUNNING,
        inheritLauncherGroup=True, supervisorPID=OWNER, supervisorPGID=OWNER,
        supervisorSID=OWNER, launcherPGID=OWNER, launcherPID=OWNER + 1)


class ConsolePolicyTests(unittest.TestCase):
    def eligible(self, value=None, trace=PREAPP_ERROR, identity=None, owner=OWNER):
        return sim.console_preapp_rejection(receipt() if value is None else value, trace,
            IDENTITY if identity is None else identity, owner, 120)

    def test_only_exact_completed_preapp_rejection_is_eligible(self):
        self.assertEqual(sim.not_running_error(BUNDLE), NOT_RUNNING)
        self.assertTrue(self.eligible())
        for eof in (0, 1, 119.999):
            with self.subTest(eof=eof):
                value = receipt(); value['stdoutEOFSeconds'] = eof
                self.assertTrue(self.eligible(value))
        for trace in (b'', PREAPP_ERROR[:-1], PREAPP_ERROR + b'\n',
                      PREAPP_ERROR + b'PROBE {"event":"app.entry"}\n',
                      PREAPP_ERROR.replace(BUNDLE.encode(), b'foreign.bundle')):
            with self.subTest(trace=trace):
                self.assertFalse(self.eligible(trace=trace))

    def test_each_required_receipt_field_and_identity_guard_is_retained(self):
        faults = dict(completed=True, success=True, error='other failure',
            identityError='launcher/probe app PID mismatch', launchExitCodeBeforeCleanup=0,
            launchExitCode=0, cleanupExitCode=0, cleanupStdout='unexpected output',
            cleanupStderr=NOT_RUNNING + '\n', inheritLauncherGroup=False,
            supervisorPID=OWNER + 10, supervisorPGID=OWNER + 10,
            supervisorSID=OWNER + 10, launcherPGID=OWNER + 10,
            runID='other-run', simulatorID='other-simulator', scenario='other-case',
            bundleID='other.bundle')
        for key, changed in faults.items():
            with self.subTest(field=key, fault='changed'):
                value = receipt(); value[key] = changed
                self.assertFalse(self.eligible(value))
            with self.subTest(field=key, fault='missing'):
                value = receipt(); del value[key]
                self.assertFalse(self.eligible(value))
        for key in IDENTITY:
            with self.subTest(expected_identity=key):
                identity = dict(IDENTITY); identity[key] = 'unexpected'
                self.assertFalse(self.eligible(identity=identity))
        self.assertFalse(self.eligible(owner=OWNER + 99))

    def test_any_app_or_cleanup_error_field_is_a_permanent_refusal(self):
        for key in ('appPID', 'launcherAppPID', 'appEntryObserved', 'lastProbeEvent', 'cleanupError'):
            for changed in (None, False, 0, ''):
                with self.subTest(field=key, value=changed):
                    value = receipt(); value[key] = changed
                    self.assertFalse(self.eligible(value))

    def test_generic_classifier_does_not_require_an_inherited_supervisor_group(self):
        generic = receipt()
        for key in (*IDENTITY, 'inheritLauncherGroup', 'supervisorPID', 'supervisorPGID',
                    'supervisorSID', 'launcherPGID'):
            del generic[key]
        self.assertTrue(sim.console_launch_rejection(generic, PREAPP_ERROR, BUNDLE, 120))
        self.assertFalse(self.eligible(generic))
        for key, changed in (('appEntryObserved', False), ('cleanupError', None),
                             ('cleanupStderr', 'unknown stop result'), ('stdoutEOFSeconds', float('nan'))):
            with self.subTest(field=key):
                bad = dict(generic); bad[key] = changed
                self.assertFalse(sim.console_launch_rejection(bad, PREAPP_ERROR, BUNDLE, 120))
        self.assertFalse(sim.console_launch_rejection(generic, PREAPP_ERROR + b'\n', BUNDLE, 120))

    def test_eof_and_launcher_pid_types_bounds_are_not_relaxed(self):
        for eof in (None, True, False, '0.25', -.001, 120, float('inf'), float('nan')):
            with self.subTest(eof=eof):
                value = receipt(); value['stdoutEOFSeconds'] = eof
                self.assertFalse(self.eligible(value))
        for pid in (None, True, False, '4201', 0, -1, OWNER):
            with self.subTest(pid=pid):
                value = receipt(); value['launcherPID'] = pid
                self.assertFalse(self.eligible(value))
        value = receipt(); value['inheritLauncherGroup'] = 1
        self.assertFalse(self.eligible(value))
        for key in ('completed', 'success'):
            value = receipt(); value[key] = 0
            self.assertFalse(self.eligible(value))


class TerminationPolicyTests(unittest.TestCase):
    def test_transport_is_called_once_with_original_bound_and_result(self):
        command = ['host-stop', 'owned-app']
        result = subprocess.CompletedProcess(command, 73, b'partial', b'refused')
        transport = Mock(return_value=result)
        self.assertIs(sim.terminate_once(command, 20, transport), result)
        transport.assert_called_once_with(command, capture_output=True, timeout=20)

    def test_transport_failures_propagate_without_a_retry(self):
        command = ['host-stop', 'owned-app']
        for error in (subprocess.TimeoutExpired(command, 10, output=b'partial'), OSError('transport unavailable')):
            with self.subTest(error=type(error).__name__):
                transport = Mock(side_effect=error)
                with self.assertRaises(type(error)) as caught:
                    sim.terminate_once(command, 10, transport)
                self.assertIs(caught.exception, error)
                transport.assert_called_once_with(command, capture_output=True, timeout=10)

    def test_invalid_deadlines_do_not_execute_transport(self):
        for timeout in (0, -1, float('nan'), float('inf')):
            with self.subTest(timeout=timeout):
                transport = Mock()
                with self.assertRaises(ValueError):
                    sim.terminate_once(['host-stop'], timeout, transport)
                transport.assert_not_called()


class FailureMarkerTests(unittest.TestCase):
    def test_only_final_reports_mark_and_clear_the_optional_failure(self):
        with tempfile.TemporaryDirectory(prefix='console-policy-host-') as temporary:
            root = Path(temporary); marker = root / 'classified'; summary = root / 'summary.md'
            with patch.dict(os.environ, dict(SIM_FAILURE_MARKER=str(marker),
                            GITHUB_STEP_SUMMARY=str(summary))), redirect_stderr(io.StringIO()):
                self.assertFalse(sim.failure_is_classified())
                sim.summary('infra:launch', 'scheduled')
                sim.summary('infra:launch', 'recovered')
                self.assertFalse(marker.exists(), 'nonterminal summary created a failure marker')
                sim.report_failure('infra:launch', 'exhausted')
                self.assertTrue(sim.failure_is_classified())
                marker.write_text('retained failure')
                sim.summary('infra:shutdown', 'not eligible; delete attempted')
                self.assertEqual(marker.read_text(), 'retained failure', 'summary changed terminal state')
                sim.clear_failure_marker()
                self.assertFalse(sim.failure_is_classified())
                sim.clear_failure_marker()
                sim.report_failure('product:decline')
                self.assertTrue(sim.failure_is_classified())
                self.assertIn('product:decline', summary.read_text())

    def test_optional_marker_can_be_absent_and_labels_cannot_inject_summary_rows(self):
        with tempfile.TemporaryDirectory(prefix='console-policy-summary-') as temporary:
            summary = Path(temporary) / 'summary.md'
            environment = {key: value for key, value in os.environ.items() if key != 'SIM_FAILURE_MARKER'}
            environment['GITHUB_STEP_SUMMARY'] = str(summary)
            with patch.dict(os.environ, environment, clear=True), redirect_stderr(io.StringIO()):
                sim.clear_failure_marker()
                self.assertFalse(sim.failure_is_classified())
                sim.report_failure('product:check\n| injected |')
                self.assertFalse(sim.failure_is_classified())
            self.assertEqual(len(summary.read_text().splitlines()), 1)
            self.assertNotIn('| injected |', summary.read_text())


if __name__ == '__main__':
    unittest.main()
