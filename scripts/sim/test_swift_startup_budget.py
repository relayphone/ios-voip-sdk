"""Swift launch and capture timing controls without native services."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_capture_deadlines import Clock, NoNativeThread, Process, VirtualOutput
import test_swift_livekit_setup as setup

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_scenario
import run_swift_livekit as runner


class SwiftSupervisorBudgetTests(unittest.TestCase):
    def planned_command(self, root, mode):
        output = root / 'planned'; output.mkdir()
        boundary = RuntimeError('planned process boundary')
        with patch.object(runner.subprocess, 'Popen', side_effect=boundary) as spawn, \
             patch.object(runner.subprocess, 'run', side_effect=AssertionError('native command refused')), \
             patch.object(runner.os, 'kill', side_effect=AssertionError('native signal refused')), \
             patch.object(runner.os, 'killpg', side_effect=AssertionError('native group signal refused')):
            with self.assertRaises(RuntimeError) as caught:
                runner.capture_case(root, output, 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA', '', mode)
        self.assertIs(caught.exception, boundary)
        self.assertEqual(spawn.call_count, 1)
        return spawn.call_args.args[0]

    def capture(self, schedule):
        with tempfile.TemporaryDirectory(prefix='swift-capture-clock-') as temporary:
            root = Path(temporary)
            command = self.planned_command(root, 'stale-audio')
            value = lambda name: command[command.index(name) + 1]
            launch_index = command.index('--launch-command')
            stop_index = command.index('--terminate-command')
            identity = dict(runID=value('--run-id'), simulatorID=value('--simulator-id'),
                            bundleID=value('--bundle-id'), scenario=value('--scenario'))
            timeout = float(value('--timeout'))
            startup = float(value('--startup-timeout')) if '--startup-timeout' in command else None
            self.assertEqual(timeout, 90)
            pid, supervisor = 12345, 44001

            def row(event, elapsed):
                return b'PROBE ' + json.dumps(dict(identity, event=event, pid=pid, t_ms=elapsed)).encode() + b'\n'

            events = [(when, (identity['bundleID'] + ': ' + str(pid) + '\n').encode()
                       if event == 'header' else None if event == 'eof' else row(event, elapsed))
                      for when, event, elapsed in schedule]
            clock, process = Clock(), Process()
            messages = VirtualOutput(clock, events)

            def kill(target, signum):
                if (target, signum) == (pid, 0):
                    raise ProcessLookupError
                self.assertEqual((target, signum), (process.pid, signal.SIGTERM))
                process.returncode = 0

            def terminate(arguments, **options):
                process.returncode = 0
                return subprocess.CompletedProcess(arguments, 0, b'', b'')

            output, receipt = root / 'capture.log', root / 'capture.receipt.json'
            with patch.object(run_scenario.time, 'monotonic', clock.monotonic), \
                 patch.object(run_scenario.queue, 'Queue', return_value=messages), \
                 patch.object(run_scenario.threading, 'Thread', NoNativeThread), \
                 patch.object(run_scenario.tty, 'setraw'), \
                 patch.object(run_scenario.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.object(run_scenario.subprocess, 'run', side_effect=terminate), \
                 patch.object(run_scenario.os, 'getpid', return_value=supervisor), \
                 patch.object(run_scenario.os, 'getpgid', return_value=supervisor), \
                 patch.object(run_scenario.os, 'getsid', return_value=supervisor), \
                 patch.object(run_scenario.os, 'kill', side_effect=kill), \
                 patch.dict(run_scenario.os.environ, {}, clear=True):
                status = run_scenario.run(command[launch_index + 1:], command[stop_index + 1:launch_index],
                    output, receipt, timeout, identity,
                    console_launcher_stop='--console-launcher-stop' in command,
                    inherit_launcher_group='--inherit-launcher-group' in command,
                    startup_timeout=startup)
            self.assertEqual(spawn.call_count, 1)
            self.assertFalse(spawn.call_args.kwargs['start_new_session'])
            return status, json.loads(receipt.read_text()), clock.now

    def test_entry_after_ninety_seconds_gets_the_full_capture_window(self):
        status, receipt, now = self.capture([(92, 'app.entry', 0), (92.1, 'launch', 100),
            (92.2, 'header', 0), (181, 'done', 89000), (181, 'eof', 0)])
        self.assertEqual(status, 0, receipt)
        self.assertTrue(receipt['success'] and receipt['completed'])
        self.assertTrue(receipt['inheritLauncherGroup'])
        self.assertEqual(receipt['captureStart'], 'observed-app-entry')
        self.assertEqual(now, 181)

    def test_missing_entry_expires_at_the_startup_bound(self):
        status, receipt, now = self.capture([])
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt.get('timeoutReason'), 'startup')
        self.assertEqual(receipt.get('failureClass'), 'infra:startup')
        self.assertFalse(receipt['completed'])
        self.assertAlmostEqual(now, 180)

    def test_late_entry_cannot_qualify(self):
        for entry_at in (180, 181):
            with self.subTest(entry_at=entry_at):
                status, receipt, now = self.capture([(entry_at, 'app.entry', 0), (entry_at + 1, 'done', 1000)])
                self.assertEqual(status, 1, receipt)
                self.assertEqual(receipt.get('timeoutReason'), 'startup')
                self.assertFalse(receipt.get('appEntryObserved', False))
                self.assertFalse(receipt['completed'])
                self.assertAlmostEqual(now, 180)

    def test_capture_expires_ninety_seconds_after_entry(self):
        status, receipt, now = self.capture([(92, 'app.entry', 0), (92.1, 'launch', 100),
            (92.2, 'header', 0), (183, 'done', 91000)])
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt.get('timeoutReason'), 'capture')
        self.assertEqual(receipt.get('failureClass'), 'infra:capture')
        self.assertFalse(receipt['completed'])
        self.assertAlmostEqual(now, 182)

    def test_duplicate_entry_does_not_extend_capture(self):
        status, receipt, now = self.capture([(92, 'app.entry', 0), (92.1, 'launch', 100),
            (92.2, 'header', 0), (170, 'app.entry', 78000), (183, 'done', 91000)])
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt.get('timeoutReason'), 'capture')
        self.assertFalse(receipt['completed'])
        self.assertAlmostEqual(now, 182)


class SwiftCaptureClassificationTests(unittest.TestCase):
    setUp = setup.SwiftLiveKitSetupTests.setUp
    capture = setup.SwiftLiveKitSetupTests.capture
    failure_labels = setup.SwiftLiveKitSetupTests.failure_labels

    def test_child_timeout_classification_survives_the_host_watchdog(self):
        for index, (label, original) in enumerate((
                ('infra:startup', subprocess.TimeoutExpired(['supervisor'], 130)),
                ('infra:capture', subprocess.TimeoutExpired(['supervisor'], 130)),
                ('infra:startup', runner.NativeCommandError('host execution failed')),
                ('infra:capture', runner.NativeCommandError('host execution failed')))):
            with self.subTest(label=label, error=type(original).__name__):
                self.out = self.root / ('capture-' + str(index))
                self.case_calls.clear()
                (self.root / 'job-summary.md').unlink(missing_ok=True)
                native = setup.NativeService()
                self.assertIs(self.capture(native, override='', case_failure=original,
                                           child_failure_label=label), original)
                self.assertEqual(self.failure_labels(), [label])
                self.assertEqual(len(self.case_calls), 1)
                self.assertFalse(self.case_calls[0]['state']['retry_used'])
                self.assertEqual(native.devices, {})
                self.assertFalse((self.out / 'manifest.json').exists())

    def test_cancellation_precedes_a_fresh_child_classification(self):
        original = KeyboardInterrupt()
        self.assertIs(self.capture(setup.NativeService(), override='', case_failure=original,
                                   child_failure_label='infra:startup'), original)
        self.assertEqual(self.failure_labels(), ['infra:startup', 'infra:runner-cancelled'])

    def test_evidence_failure_precedes_a_fresh_child_classification(self):
        original = OSError('capture evidence unavailable')
        self.assertIs(self.capture(setup.NativeService(), override='', case_failure=original,
                                   child_failure_label='infra:capture'), original)
        self.assertEqual(self.failure_labels(), ['infra:capture', 'infra:evidence-write'])

    def test_unchanged_marker_cannot_hide_a_new_product_failure(self):
        Path(str(self.out) + '.failure-classified').touch()
        original = RuntimeError('product checkpoint failed')
        self.assertIs(self.capture(setup.NativeService(), override='', case_failure=original), original)
        self.assertEqual(self.failure_labels(), ['product:swift-livekit-healthy'])
        self.assertEqual(len(self.case_calls), 1)

    def test_unclassified_host_timeout_remains_a_launch_failure(self):
        original = subprocess.TimeoutExpired(['supervisor'], 130)
        self.assertIs(self.capture(setup.NativeService(), override='', case_failure=original), original)
        self.assertEqual(self.failure_labels(), ['infra:launch'])


if __name__ == '__main__':
    unittest.main()
