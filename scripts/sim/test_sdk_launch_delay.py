#!/usr/bin/env python3
"""Host-only virtual-clock capture control; never native product evidence."""
import json
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import check_sdk_m1_container_capture as controls
import run_scenario


class Clock:
    now = 0.0

    def monotonic(self):
        return self.now


class VirtualOutput:
    """Deliver the observed 70s startup and 30s native window without sleeping."""
    def __init__(self, clock, events):
        self.clock, self.events = clock, list(events)

    def get(self, timeout):
        when, value = self.events[0]
        if when > self.clock.now + timeout + 1e-9:
            self.clock.now += timeout
            raise queue.Empty
        self.clock.now = max(self.clock.now, when)
        self.events.pop(0)
        return value


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


class ContractLaunchDelayTests(unittest.TestCase):
    def capture(self, timeout_override=None):
        # Execute the actual contract-loop caller with the owner's inert
        # supervisor to obtain its arguments; only the clock/transport below is
        # synthetic; the real checked-out runner supplies its call-site budget.
        result, calls = controls.ContractCaptureBudgetControls().capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        case = next(row for row in calls if row['case'] == 'unhandled-fail')
        args = case['args']
        value = lambda name: args[args.index(name) + 1]
        timeout = float(value('--timeout')) if timeout_override is None else timeout_override
        launch_index, terminate_index = args.index('--launch-command'), args.index('--terminate-command')
        launch, terminate = args[launch_index + 1:], args[terminate_index + 1:launch_index]
        identity = dict(runID=value('--run-id'), simulatorID=value('--simulator-id'),
                        scenario=value('--scenario'), bundleID=value('--bundle-id'))
        self.assertIn('--console-launcher-stop', args)

        pid = 12345
        def row(event, elapsed, **extra):
            payload = dict(event=event, pid=pid, runID=identity['runID'],
                           simulatorID=identity['simulatorID'], bundleID=identity['bundleID'],
                           t_ms=elapsed, **extra)
            return b'PROBE ' + json.dumps(payload).encode() + b'\n'
        events = [(70.0, row('app.entry', 0)),
                  (70.5, row('launch', 500, case='unhandled-fail')),
                  (70.6, (identity['bundleID'] + ': ' + str(pid) + '\n').encode()),
                  (71.1, row('contract.pending', 1100, remainingMS=27000)),
                  (98.15, row('contract.actionDiagnostic', 28150, phase='policy-fire')),
                  (101.2, row('contract.failureObservation', 31200, pendingCleared=True)),
                  (101.5, row('done', 31500, success=True)), (101.5, None)]
        clock, process = Clock(), Process()
        output_queue = VirtualOutput(clock, events)
        def kill(target, signum):
            if target == pid and signum == 0:
                raise ProcessLookupError
            self.assertEqual((target, signum), (process.pid, signal.SIGTERM))
            process.returncode = 0
        def terminate_owned(*args, **kwargs):
            process.returncode = 0
            return subprocess.CompletedProcess(args[0], 0, b'', b'')
        with tempfile.TemporaryDirectory(prefix='sdk-virtual-launch-') as temporary:
            output = Path(temporary) / 'capture.log'
            receipt = output.with_suffix('.receipt.json')
            with patch.object(run_scenario.time, 'monotonic', clock.monotonic), \
                 patch.object(run_scenario.queue, 'Queue', return_value=output_queue), \
                 patch.object(run_scenario.threading, 'Thread', NoNativeThread), \
                 patch.object(run_scenario.tty, 'setraw'), \
                 patch.object(run_scenario.subprocess, 'Popen', return_value=process) as launched, \
                 patch.object(run_scenario.subprocess, 'run', side_effect=terminate_owned), \
                 patch.object(run_scenario.os, 'kill', side_effect=kill):
                status = run_scenario.run(launch, terminate, output, receipt, timeout, identity,
                                          console_launcher_stop=True)
            captured = json.loads(receipt.read_text())
            self.assertEqual(launched.call_count, 1, 'the fixture must never replay a case')
            return status, captured, clock.now

    def test_seventy_second_launch_preserves_the_native_policy_window(self):
        status, captured, elapsed = self.capture()
        self.assertTrue(captured.get('appEntryObserved'), captured)
        self.assertEqual(status, 0, captured)
        self.assertTrue(captured['completed'] and captured['success'], captured)
        self.assertEqual(captured['lastProbeEvent'], 'done')
        self.assertGreaterEqual(elapsed, 101.5)

    def test_original_ninety_second_host_bound_fails_after_app_entry(self):
        status, captured, elapsed = self.capture(timeout_override=90)
        self.assertEqual(status, 1, captured)
        self.assertTrue(captured.get('appEntryObserved'), captured)
        self.assertEqual(captured['lastProbeEvent'], 'contract.pending')
        self.assertEqual(captured['error'], 'deadline before terminal done event')
        self.assertAlmostEqual(elapsed, 90.0, places=6)


if __name__ == '__main__':
    unittest.main()
