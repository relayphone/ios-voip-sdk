#!/usr/bin/env python3
"""Real host console children verify summary labels outside capture receipts."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sim

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = 'dev.callkitsim.summaryfixture'


class ConsoleRunnerLabelsTests(unittest.TestCase):
    def capture(self, launch_source, stop_source, *, console=True, reporting=True):
        temporary = tempfile.TemporaryDirectory(prefix='sim-console-labels-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        launch, stop = root / 'launch.py', root / 'stop.py'
        launch.write_text(launch_source)
        stop.write_text(stop_source)
        trace, receipt = root / 'case.log', root / 'case.receipt.json'
        summary, marker = root / 'summary.md', root / 'classified'
        command = [sys.executable, str(ROOT / 'discovery/run_scenario.py'),
            '--output', str(trace), '--receipt', str(receipt), '--timeout', '3',
            '--bundle-id', BUNDLE, '--scenario', 'summary-case', '--run-id', 'host-run',
            '--simulator-id', 'host-only-simulator']
        if console:
            command.append('--console-launcher-stop')
        command += ['--terminate-command', sys.executable, str(stop),
                    '--launch-command', sys.executable, str(launch)]
        environment = dict(os.environ, GITHUB_STEP_SUMMARY=str(summary))
        if reporting:
            environment['SIM_FAILURE_MARKER'] = str(marker)
        else:
            environment.pop('SIM_FAILURE_MARKER', None)
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=12)
        evidence = json.loads(receipt.read_text())
        self.assertEqual(evidence['traceSHA256'], hashlib.sha256(trace.read_bytes()).hexdigest())
        self.assertNotIn(b'infra:', trace.read_bytes())
        self.assertNotIn(b'product:', trace.read_bytes())
        self.assertFalse(any('retry' in key.lower() or 'classification' in key.lower() for key in evidence))
        return result, evidence, summary, marker

    def test_exact_preapp_rejection_is_infrastructure_and_marks_parent(self):
        error = (
            'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
            f'Simulator device failed to launch {BUNDLE}.\nNo such process\n'
            'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
            f"\tApplication launch for '{BUNDLE}' did not return a process handle nor launch error.\n"
            '\tNo such process\n')
        result, evidence, summary, marker = self.capture(
            'import sys\nsys.stderr.write(' + repr(error) + ')\nsys.exit(3)\n',
            'import sys\nsys.stderr.write(' + repr(sim.not_running_error(BUNDLE)) + ')\nsys.exit(3)\n')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(evidence['launchExitCode'], 3)
        self.assertEqual(evidence['cleanupExitCode'], 3)
        self.assertIn('infra:launch', summary.read_text())
        self.assertNotIn('infra:terminate', summary.read_text())
        self.assertNotIn('product:', summary.read_text())
        self.assertTrue(marker.exists())

    def test_entered_app_capture_failure_is_product_and_never_replayed(self):
        result, evidence, summary, marker = self.capture(
            'import sys\nprint(\'PROBE {"event":"app.entry"}\', flush=True)\nsys.exit(7)\n',
            'import sys\nsys.exit(0)\n')
        self.assertEqual(result.returncode, 1)
        self.assertTrue(evidence['appEntryObserved'])
        self.assertIn('product:summary-case', summary.read_text())
        self.assertNotIn('infra:', summary.read_text())
        self.assertTrue(marker.exists())

    def test_preapp_rejection_with_unknown_cleanup_stays_infrastructure_and_never_replays(self):
        error = (
            'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
            f'Simulator device failed to launch {BUNDLE}.\nNo such process\n'
            'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
            f"\tApplication launch for '{BUNDLE}' did not return a process handle nor launch error.\n"
            '\tNo such process\n')
        result, evidence, summary, marker = self.capture(
            'import sys\nsys.stderr.write(' + repr(error) + ')\nsys.exit(3)\n',
            'import sys\nsys.exit(7)\n')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(evidence['cleanupExitCode'], 7)
        self.assertIn('infra:launch', summary.read_text())
        self.assertIn('infra:terminate', summary.read_text())
        self.assertNotIn('product:', summary.read_text())
        self.assertTrue(marker.exists())

    def test_offline_negative_control_cannot_pollute_native_job_summary(self):
        result, evidence, summary, marker = self.capture(
            'import sys\nprint(\'PROBE {"event":"app.entry"}\', flush=True)\nsys.exit(7)\n',
            'import sys\nsys.exit(0)\n', reporting=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(evidence['appEntryObserved'])
        self.assertFalse(summary.exists())
        self.assertFalse(marker.exists())

    def test_completed_capture_with_stop_failure_is_only_termination_infrastructure(self):
        launch = '''import json, os, time
pid = os.getpid()
print(''' + repr(BUNDLE + ': ') + ''' + str(pid), flush=True)
for row in ({'event':'app.entry'}, {'event':'launch', 'pid':pid}, {'event':'done'}):
    print('PROBE ' + json.dumps(row), flush=True)
time.sleep(30)
'''
        result, evidence, summary, marker = self.capture(launch, 'import sys\nsys.exit(7)\n', console=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(evidence['completed'])
        self.assertEqual(evidence['terminateExitCode'], 7)
        self.assertEqual(evidence['cleanupExitCode'], 7)
        self.assertIn('infra:terminate', summary.read_text())
        self.assertNotIn('product:', summary.read_text())
        self.assertTrue(marker.exists())

    def test_failed_pid_binding_is_not_hidden_by_a_stop_failure(self):
        launch = '''import json, os, time
pid = os.getpid()
print(''' + repr(BUNDLE + ': ') + ''' + str(pid + 1), flush=True)
for row in ({'event':'app.entry'}, {'event':'launch', 'pid':pid}, {'event':'done'}):
    print('PROBE ' + json.dumps(row), flush=True)
time.sleep(30)
'''
        result, evidence, summary, marker = self.capture(launch, 'import sys\nsys.exit(7)\n', console=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(evidence['completed'])
        self.assertEqual(evidence['identityError'], 'launcher/probe app PID mismatch')
        self.assertIn('product:summary-case', summary.read_text())
        self.assertIn('infra:terminate', summary.read_text())
        self.assertTrue(marker.exists())

    def test_post_stop_drain_failure_includes_termination_classification(self):
        sys.path.insert(0, str(ROOT / 'discovery'))
        from check_console_stop import fixtures, run_case
        with tempfile.TemporaryDirectory(prefix='sim-console-drain-') as temporary:
            root = Path(temporary)
            summary, marker = root / 'summary.md', root / 'classified'
            with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(summary), SIM_FAILURE_MARKER=str(marker)):
                result, evidence, _ = run_case(root, fixtures(root), 'orphan-output')
            self.assertEqual(result.returncode, 1)
            self.assertTrue(evidence['completed'])
            self.assertIn('launcher output did not close after stop', evidence['error'])
            self.assertIn('infra:terminate', summary.read_text())
            self.assertTrue(marker.exists())

    def test_successful_console_capture_adds_no_failure_or_marker(self):
        launch = '''import json, os, time
pid = os.getpid()
print(''' + repr(BUNDLE + ': ') + ''' + str(pid), flush=True)
for row in ({'event':'app.entry'}, {'event':'launch', 'pid':pid}, {'event':'done'}):
    print('PROBE ' + json.dumps(row), flush=True)
time.sleep(30)
'''
        result, evidence, summary, marker = self.capture(launch, 'raise RuntimeError("unexpected fallback")\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(evidence['success'])
        self.assertFalse(summary.exists())
        self.assertFalse(marker.exists())


class SystemRunnerMarkerTests(unittest.TestCase):
    def test_primary_journey_failure_survives_cleanup_classification(self):
        sys.path.insert(0, str(ROOT / 'discovery'))
        import run_sdk_system as runner
        import sdk_system_conformance as gate
        from types import SimpleNamespace
        owner = 7001
        for proof in ('unclassified', 'entered', 'preapp'):
            with self.subTest(proof=proof), tempfile.TemporaryDirectory(prefix='sim-system-primary-failure-') as temporary:
                root = Path(temporary)
                package, container = root / 'package', root / 'container'
                package.mkdir(); container.mkdir()
                (package / 'fixture').write_text('inert host package')
                summary, marker = root / 'summary.md', root / 'classified'
                primary = RuntimeError('synthetic product checkpoint failed')
                waits, signals = [], []
                class Process:
                    pid = owner
                    alive = True
                    def poll(self): return None if self.alive else 0
                    def wait(self, timeout):
                        waits.append(timeout)
                        if timeout == 25:
                            raise subprocess.TimeoutExpired('synthetic-supervisor', timeout)
                        self.alive = False
                        return 0
                process = Process()
                def start(journey, *_):
                    journey.process = process
                    if proof != 'unclassified':
                        sim.report_failure('infra:launch', 'synthetic child rejection')
                    if proof == 'entered':
                        journey.runtime.parent.mkdir(parents=True)
                        runner.write(journey.runtime.parent / 'session.json',
                            dict(runID=journey.args.run_id, pid=7003, bundleID=runner.BUNDLE))
                        return dict(pid=7003)
                    raise primary
                def group(group_id, value):
                    self.assertEqual(group_id, owner)
                    signals.append(value)
                    if value == 0:
                        raise ProcessLookupError('synthetic absent owned group')
                    self.assertEqual(value, runner.signal.SIGKILL)
                    process.alive = False
                args = SimpleNamespace(package=package, output=root / 'output', simulator='host-owned',
                                       run_id='host-run', data_container=container)
                with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(summary), SIM_FAILURE_MARKER=str(marker)), \
                     patch.object(runner.m0, 'source_identity', return_value={}), \
                     patch.object(gate, 'package_check'), \
                     patch.object(runner.Journey, 'start', start), \
                     patch.object(runner.Journey, 'push', side_effect=primary) as push, \
                     patch.object(runner.Journey, 'sim', side_effect=RuntimeError('synthetic termination failure')) as stop, \
                     patch.object(runner.signal, 'signal'), \
                     patch.object(runner.os, 'getpgid', return_value=owner), \
                     patch.object(runner.os, 'getsid', return_value=owner), \
                     patch.object(runner.os, 'killpg', side_effect=group):
                    with self.assertRaises(RuntimeError) as raised:
                        runner.run(args)
                self.assertIs(raised.exception, primary)
                if proof == 'entered':
                    push.assert_called_once_with('first')
                else:
                    push.assert_not_called()
                stop.assert_called_once_with('terminate', 'host-owned', runner.BUNDLE, timeout=10)
                self.assertEqual(waits, [25, 5])
                self.assertEqual(signals, [runner.signal.SIGKILL, 0])
                labels = summary.read_text()
                self.assertIn('infra:terminate', labels)
                if proof == 'preapp':
                    self.assertNotIn('product:', labels)
                else:
                    self.assertIn('product:sdk-system-answer-end', labels)
                    self.assertLess(labels.index('product:sdk-system-answer-end'), labels.index('infra:terminate'))
                self.assertFalse((args.output / 'answer-end/sdk-system-answer-end.receipt.json').exists())
                self.assertTrue(marker.exists())

    def test_completed_capture_stop_failure_remains_only_infrastructure(self):
        sys.path.insert(0, str(ROOT / 'discovery'))
        import run_sdk_system as runner
        import sdk_system_conformance as gate
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(prefix='sim-system-capture-failure-') as temporary:
            root = Path(temporary)
            package, container = root / 'package', root / 'container'
            package.mkdir(); container.mkdir()
            (package / 'fixture').write_text('inert host package')
            summary, marker = root / 'summary.md', root / 'classified'
            waits = []
            class Process:
                pid = 7001
                alive = True
                journey = None
                def poll(self): return None if self.alive else 1
                def wait(self, timeout):
                    waits.append(timeout)
                    self.alive = False
                    journey = self.journey
                    runner.write(journey.root / (journey.name + '.receipt.json'),
                                 dict(schemaVersion=2, completed=True, success=False))
                    sim.report_failure('infra:terminate', 'synthetic child stop failure')
                    return 1
            process = Process()
            def start(journey, *_):
                journey.process = process
                process.journey = journey
                journey.runtime.parent.mkdir(parents=True)
                runner.write(journey.runtime.parent / 'session.json',
                    dict(runID=journey.args.run_id, pid=7003, bundleID=runner.BUNDLE))
                return dict(pid=7003)
            args = SimpleNamespace(package=package, output=root / 'output', simulator='host-owned',
                                   run_id='host-run', data_container=container)
            incoming = dict(callUUID='host-call')
            with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(summary), SIM_FAILURE_MARKER=str(marker)), \
                 patch.object(runner.m0, 'source_identity', return_value={}), \
                 patch.object(gate, 'package_check'), patch.object(runner, 'CASES', ('decline',)), \
                 patch.object(runner.Journey, 'start', start), \
                 patch.object(runner.Journey, 'push', return_value=incoming) as push, \
                 patch.object(runner.Journey, 'end') as end, \
                 patch.object(runner.Journey, 'wait', side_effect=[dict(sequence=1), True]) as wait, \
                 patch.object(runner.Journey, 'command') as command, \
                 patch.object(runner.Journey, 'sim') as stop, \
                 patch.object(runner.signal, 'signal'), \
                 patch.object(runner.os, 'killpg', side_effect=ProcessLookupError) as group:
                with self.assertRaisesRegex(gate.EvidenceError, 'system supervisor refused capture'):
                    runner.run(args)
            push.assert_called_once_with('first')
            end.assert_called_once_with(incoming, True)
            self.assertEqual(wait.call_count, 2)
            command.assert_called_once_with('finish')
            stop.assert_not_called()
            group.assert_called_once_with(process.pid, 0)
            self.assertEqual(waits, [30])
            self.assertEqual(summary.read_text().count('infra:terminate'), 1)
            self.assertNotIn('product:', summary.read_text())
            receipt = json.loads((args.output / 'decline/sdk-system-decline.receipt.json').read_text())
            self.assertTrue(receipt['completed'])
            self.assertFalse(receipt['success'])
            self.assertTrue(marker.exists())

    def test_fresh_runtime_evidence_refuses_retry_and_reports_product(self):
        sys.path.insert(0, str(ROOT / 'discovery'))
        from check_sdk_system import startup_recovery_controls
        with tempfile.TemporaryDirectory(prefix='sim-system-fresh-evidence-') as temporary:
            root = Path(temporary)
            summary, marker = root / 'summary.md', root / 'classified'
            marker.touch()  # The first child already classified its exact rejection.
            with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(summary), SIM_FAILURE_MARKER=str(marker)):
                controls = startup_recovery_controls(selected=[
                    'preapp-session-changed', 'preapp-journal-changed'])
            self.assertEqual(len(controls), 2)  # Both controls assert exactly one launch.
            labels = summary.read_text()
            self.assertEqual(labels.count('product:sdk-system-decline'), 2)
            self.assertIn('runtime evidence changed; never retried', labels)
            self.assertNotIn('scheduled', labels)
            self.assertNotIn('recovered', labels)
            self.assertTrue(marker.exists())

    def test_recovery_clears_only_the_rejected_attempt_marker(self):
        sys.path.insert(0, str(ROOT / 'discovery'))
        from check_sdk_system import startup_recovery_controls
        with tempfile.TemporaryDirectory(prefix='sim-system-marker-') as temporary:
            root = Path(temporary)
            summary, marker = root / 'summary.md', root / 'classified'
            marker.touch()
            with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(summary), SIM_FAILURE_MARKER=str(marker)):
                startup_recovery_controls(selected=['preapp-rejection-recovered-once'])
            self.assertFalse(marker.exists())
            self.assertIn('scheduled', summary.read_text())
            self.assertIn('recovered', summary.read_text())

    def test_standalone_system_capture_restores_the_callers_marker_environment(self):
        sys.path.insert(0, str(ROOT / 'discovery'))
        from check_sdk_system import container_cache_controls
        for inherited in (None, '', '/host-only/inherited-marker'):
            with self.subTest(inherited=inherited), patch.dict(os.environ):
                if inherited is None:
                    os.environ.pop('SIM_FAILURE_MARKER', None)
                else:
                    os.environ['SIM_FAILURE_MARKER'] = inherited
                container_cache_controls()
                self.assertEqual(os.environ.get('SIM_FAILURE_MARKER'), inherited)


if __name__ == '__main__':
    unittest.main()
