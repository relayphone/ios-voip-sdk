#!/usr/bin/env python3
"""Virtual-clock controls for startup and post-entry capture boundaries."""
import json
import os
from pathlib import Path
import queue
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_scenario
from sim import Result

IDENTITY = dict(runID='run', simulatorID='simulator', bundleID='dev.fixture', scenario='fixture')
PID = 12345


def row(event, **extra):
    return ('PROBE ' + json.dumps(dict(event=event, runID='run', simulatorID='simulator',
                                       bundleID='dev.fixture', pid=PID, t_ms=extra.pop('t_ms', 0), **extra)) + '\n').encode()


class Clock:
    now = 0.0
    def monotonic(self): return self.now


class VirtualOutput:
    def __init__(self, clock, events): self.clock, self.events = clock, list(events)
    def get(self, timeout):
        if not self.events or self.events[0][0] > self.clock.now + timeout + 1e-9:
            self.clock.now += timeout
            raise queue.Empty
        when, value = self.events.pop(0)
        self.clock.now = max(self.clock.now, when)
        return value
    def get_nowait(self): raise queue.Empty


class Stream:
    def fileno(self): return 42
    def close(self): pass


class Process:
    pid = 98765
    stdout = None
    stderr = Stream()
    returncode = None
    def poll(self): return self.returncode
    def wait(self, timeout=None):
        self.returncode = 0
        return 0


class NoNativeThread:
    ident = None
    def __init__(self, *args, **kwargs): pass
    def start(self): pass


class CaptureDeadlines(unittest.TestCase):
    def capture(self, events, capture=90, startup=180):
        clock, process = Clock(), Process()
        messages = VirtualOutput(clock, events)
        def kill(target, signum):
            if target == PID and signum == 0: raise ProcessLookupError
            self.assertEqual((target, signum), (process.pid, signal.SIGTERM))
            process.returncode = 0
        def terminate(*args, **kwargs):
            process.returncode = 0
            return Result(args[0], 0)
        with tempfile.TemporaryDirectory(prefix='ci-capture-clock-') as temporary:
            output, receipt = Path(temporary) / 'capture.log', Path(temporary) / 'receipt.json'
            with patch.object(run_scenario.time, 'monotonic', clock.monotonic), \
                 patch.object(run_scenario.queue, 'Queue', return_value=messages), \
                 patch.object(run_scenario.threading, 'Thread', NoNativeThread), \
                 patch.object(run_scenario.tty, 'setraw'), \
                 patch.object(run_scenario.subprocess, 'Popen', return_value=process) as launched, \
                 patch.object(run_scenario, 'bounded', side_effect=terminate), \
                 patch.object(run_scenario.os, 'kill', side_effect=kill):
                status = run_scenario.run(['launch'], ['terminate'], output, receipt, capture,
                                          IDENTITY, console_launcher_stop=True, startup_timeout=startup)
            self.assertEqual(launched.call_count, 1)
            return status, json.loads(receipt.read_text()), clock.now

    def test_hosted_duo_late_start_gets_full_capture_window(self):
        events = [(92.367, row('app.entry')), (92.4, row('launch')),
                  (92.5, b'dev.fixture: 12345\n'), (94.222, row('done')), (94.222, None)]
        status, receipt, now = self.capture(events)
        self.assertEqual(status, 0, receipt)
        self.assertTrue(receipt['success'] and receipt['completed'])
        self.assertGreaterEqual(now, 94.222)

    def test_startup_timeout_is_distinct_and_never_accepts_late_entry(self):
        status, receipt, now = self.capture([(181, row('app.entry')), (182, row('done'))])
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt['timeoutReason'], 'startup')
        self.assertEqual(receipt['failureClass'], 'infra:startup')
        self.assertFalse(receipt['completed'])
        self.assertAlmostEqual(now, 180)

    def test_capture_timeout_stays_bounded_after_entry(self):
        events = [(92, row('app.entry')), (92.1, row('launch')),
                  (92.2, b'dev.fixture: 12345\n'), (183, row('done'))]
        status, receipt, now = self.capture(events)
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt['timeoutReason'], 'capture')
        self.assertEqual(receipt['failureClass'], 'infra:capture')
        self.assertFalse(receipt['completed'])
        self.assertAlmostEqual(now, 182)

    def test_duplicate_entry_never_resets_capture_deadline(self):
        events = [(1, row('app.entry')), (1.1, row('launch')),
                  (1.2, b'dev.fixture: 12345\n'), (89, row('app.entry')), (92, row('done'))]
        status, receipt, now = self.capture(events)
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt['timeoutReason'], 'capture')
        self.assertAlmostEqual(now, 91)

    def test_backlogged_consumer_uses_reader_observation_time(self):
        events = [(100, (row('app.entry'), 1.0)), (100.1, row('launch')),
                  (100.2, b'dev.fixture: 12345\n'), (101, row('done'))]
        status, receipt, _ = self.capture(events)
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt['timeoutReason'], 'capture')
        self.assertFalse(receipt['completed'])

    def test_native_elapsed_rejects_late_done_even_when_console_is_buffered(self):
        events = [(100, row('app.entry', t_ms=0)), (100.1, row('launch', t_ms=1)),
                  (100.2, b'dev.fixture: 12345\n'), (101, row('done', t_ms=91000))]
        status, receipt, _ = self.capture(events)
        self.assertEqual(status, 1, receipt)
        self.assertEqual(receipt['timeoutReason'], 'capture')
        self.assertFalse(receipt['completed'])

    def test_timeout_classification_marks_summary_and_failure(self):
        with tempfile.TemporaryDirectory(prefix='ci-capture-summary-') as temporary:
            marker, summary = Path(temporary) / 'marker', Path(temporary) / 'summary'
            with patch.dict(os.environ, {'SIM_FAILURE_MARKER': str(marker), 'GITHUB_STEP_SUMMARY': str(summary)}):
                run_scenario.report_timeout('infra:startup')
            self.assertTrue(marker.exists())
            self.assertIn('`infra:startup`: never retried', summary.read_text())
            self.assertNotIn('product:', summary.read_text())

    def test_preclassified_result_is_not_reclassified_or_retried(self):
        sys.path.insert(0, str(ROOT / 'scripts/sim'))
        import sim
        owned = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
        calls = []
        def native(command, timeout):
            calls.append(command)
            if command[2] == 'create': return sim.Result(command, 0, (owned + '\n').encode())
            return sim.Result(command, 1, failure_classified=True)
        with tempfile.TemporaryDirectory(prefix='ci-capture-session-') as temporary:
            session = sim.Session(Path(temporary) / 'state.json', runner=native)
            session.call(['xcrun', 'simctl', 'create', 'capture', 'device', 'runtime'], 30)
            session.checkpoint()
            with patch.object(sim, 'report_failure') as report:
                result = session.call(['xcrun', 'simctl', 'launch', owned, 'dev.fixture'], 90)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(result.failure_classified)
            report.assert_not_called()
            self.assertEqual([call[2] for call in calls], ['create', 'launch'])
            self.assertFalse(session.state['retry_used'])

    def test_interrupted_reader_start_preserves_cancellation_and_receipt(self):
        class InterruptedThread:
            ident = 1
            def __init__(self, *args, **kwargs): pass
            def start(self): raise KeyboardInterrupt('during reader start')
            def join(self, timeout=None): pass
            def is_alive(self): return False
        class Tail:
            def __init__(self): self.rows = [(b'late diagnostic\n', 1.0)]
            def get_nowait(self):
                if not self.rows: raise queue.Empty
                return self.rows.pop(0)
        process = Process()
        def terminate(*args, **kwargs):
            process.returncode = 0
            return Result(args[0], 0)
        with tempfile.TemporaryDirectory(prefix='ci-capture-interrupt-') as temporary:
            output, receipt = Path(temporary) / 'capture.log', Path(temporary) / 'receipt.json'
            with patch.object(run_scenario.queue, 'Queue', return_value=Tail()), \
                 patch.object(run_scenario.threading, 'Thread', InterruptedThread), \
                 patch.object(run_scenario.tty, 'setraw'), \
                 patch.object(run_scenario.subprocess, 'Popen', return_value=process), \
                 patch.object(run_scenario, 'bounded', side_effect=terminate):
                with self.assertRaisesRegex(KeyboardInterrupt, 'during reader start'):
                    run_scenario.run(['launch'], ['terminate'], output, receipt, 90,
                                     IDENTITY, console_launcher_stop=True, startup_timeout=180)
            self.assertFalse(json.loads(receipt.read_text())['success'])
            self.assertIn(b'late diagnostic', output.read_bytes())

    def test_done_before_entry_cannot_qualify(self):
        status, receipt, _ = self.capture([(1, row('done'))])
        self.assertEqual(status, 1, receipt)
        self.assertFalse(receipt['success'])

    def test_wrong_identity_entry_does_not_start_capture(self):
        invalid = row('app.entry').replace(b'"runID": "run"', b'"runID": "wrong"')
        status, receipt, _ = self.capture([(1, invalid), (2, row('done'))])
        self.assertEqual(status, 1, receipt)
        self.assertFalse(receipt['success'])


if __name__ == '__main__': unittest.main()
