import json
from pathlib import Path
import runpy
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

CLI = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))
RUNNER = runpy.run_path(str(Path(__file__).with_name('run.py')))


class StartupTests(unittest.TestCase):
    def test_outer_watchdog_allows_slow_sequential_transport_startup(self):
        elapsed = [0]
        def advance(_):
            elapsed[0] += 30
        clock = SimpleNamespace(monotonic=lambda: elapsed[0], sleep=advance)
        log = Mock()
        log.read_text.side_effect = lambda: 'Inspector on display' if elapsed[0] >= 90 else 'Installing inspector'
        ready = RUNNER['wait_for_inspector']
        with patch.dict(ready.__globals__, time=clock):
            ready(Mock(poll=Mock(return_value=None)), log)

    def test_startup_failure_keeps_inner_diagnostic(self):
        output = ['Inspector: installing app']
        def exited():
            output[0] += '\nsimctl install timed out'
            return 1
        log = Mock(read_text=Mock(side_effect=lambda: output[0]))
        with self.assertRaisesRegex(RuntimeError, 'simctl install timed out'):
            RUNNER['wait_for_inspector'](Mock(poll=exited), log)


class BridgeTests(unittest.TestCase):
    def test_display_cold_boot_has_an_explicit_bounded_timeout(self):
        boot = CLI['simctl']
        with patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('simctl', 300)) as process:
            with self.assertRaisesRegex(RuntimeError, 'after 300s'):
                boot('bootstatus', 'owned', '-b', timeout=300)
        self.assertEqual(process.call_args.kwargs['timeout'], 300)

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture')
        (self.root / 'session.json').write_text(json.dumps(self.session))
        (self.root / 'run').mkdir()
        self.path = self.root / 'run/events.jsonl'
        self.path.write_bytes(b'')
        self.args = SimpleNamespace(bundle='test.fixture')
        self.bridge = CLI['InspectorBridge'](self.args, 'device', self.root)

    def append(self, sequence):
        row = dict(self.session, event='report.incoming', sequence=sequence, t_ms=25, wallTimeMS=1000)
        with self.path.open('a') as output:
            output.write(json.dumps(row) + '\n')
        return row

    def test_empty_poll_replay_and_incremental_delivery(self):
        self.assertEqual(self.bridge.events(0)['events'], [])
        first = self.append(1)
        self.assertEqual(self.bridge.events(0)['events'], [first])
        second = self.append(2)
        self.assertEqual(self.bridge.events(0)['events'], [first], 'HTTP retry must replay the same batch')
        self.assertEqual(self.bridge.events(1)['events'], [second])
        self.assertEqual(self.bridge.events(2)['events'], [])
        with self.assertRaisesRegex(RuntimeError, 'cursor changed'):
            self.bridge.events(0)

    def test_restart_rejects_even_replayed_batch(self):
        self.append(1)
        self.bridge.events(0)
        (self.root / 'session.json').write_text(json.dumps(dict(self.session, pid=456)))
        with self.assertRaisesRegex(RuntimeError, 'session changed'):
            self.bridge.events(0)

    def test_controls_use_existing_transport_and_expected_session(self):
        control = Mock(return_value={'success': True})
        send = self.bridge.command
        with patch.dict(send.__globals__, control=control):
            for operation in ('answer','decline','end','hold-and-accept','end-and-accept'):
                self.assertTrue(send(dict(operation=operation, callUUID='A7E390AF-6B78-4190-B946-26D9C6438584'))['success'])
                args, device = control.call_args.args
                self.assertEqual(args.operation, operation)
                self.assertEqual(device, 'device')
                self.assertEqual(control.call_args.kwargs['expected_session'], self.session)
            for value in ([], dict(operation='push'), dict(operation='answer', callUUID='bad'),
                          dict(operation='answer', callUUID='A7E390AF-6B78-4190-B946-26D9C6438584', runID='other')):
                with self.assertRaises((RuntimeError, ValueError)):
                    send(value)


if __name__ == '__main__':
    unittest.main()
