"""Command timing observations preserve native outcomes and ownership."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import sim

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'discovery'))
import run_swift_livekit as swift


class SetupDurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='setup-duration-host-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_each_native_attempt_records_elapsed_bound_and_original_outcome(self):
        command = ['xcrun', 'simctl', 'install', 'private-device', 'private-app']
        results = [sim.Result(command, code, timed_out=code == 124) for code in (0, 73, 124)]
        pending = list(results)
        session = sim.Session(self.root / 'owner.json', runner=lambda *args: pending.pop(0))
        with patch.object(sim.time, 'monotonic', side_effect=[10, 11.25, 20, 21.5, 30, 32]):
            for result in results:
                self.assertIs(session.execute(command, 180), result)
        path = self.root / 'commands.status.jsonl'
        rows = [json.loads(row) for row in path.read_text().splitlines()]
        self.assertEqual([row['elapsedSeconds'] for row in rows], [1.25, 1.5, 2])
        self.assertEqual([row['exitCode'] for row in rows], [0, 73, 124])
        self.assertEqual([row['timedOut'] for row in rows], [False, False, True])
        self.assertTrue(all(row['step'] == 'install' and row['timeoutSeconds'] == 180 for row in rows))
        self.assertNotIn('private-', path.read_text())

    def test_executor_exception_keeps_its_identity_and_records_an_unknown_status(self):
        failure = OSError('private-native-detail')
        def native(*args): raise failure
        session = sim.Session(self.root / 'owner.json', runner=native)
        with patch.object(sim.time, 'monotonic', side_effect=[10, 11]), self.assertRaises(OSError) as caught:
            session.execute(['xcrun', 'simctl', 'boot', 'private-device'], 60)
        self.assertIs(caught.exception, failure)
        row = json.loads((self.root / 'commands.status.jsonl').read_text())
        self.assertIsNone(row['exitCode'])
        self.assertEqual(row['error'], 'OSError')
        self.assertEqual(row['elapsedSeconds'], 1)
        self.assertNotIn('private-', json.dumps(row))

    def test_missing_timing_evidence_cannot_lose_a_created_simulator(self):
        device = 'ABCDEF00-1234-4ABC-8123-000000000001'
        calls = []
        def native(command, timeout):
            calls.append(command)
            return sim.Result(command, 0, (device + '\n').encode() if command[2] == 'create' else b'')
        session = sim.Session(self.root / 'owner.json', runner=native)
        (self.root / 'commands.status.jsonl').mkdir()
        with patch.object(sim, 'summary') as report:
            session.call(['xcrun', 'simctl', 'create', 'owned', 'device-type', 'runtime'], 30)
            self.assertEqual(session.current, device)
            self.assertEqual(session.cleanup().returncode, 0)
        self.assertEqual([command[2] for command in calls], ['create', 'shutdown', 'delete'])
        self.assertFalse(session.state['owned'])
        self.assertTrue(any(call.args[0] == 'infra:evidence-write' for call in report.call_args_list))

    def test_swift_status_records_success_failure_and_timeout_durations(self):
        command = ['xcrun', 'simctl', 'install', 'private-device', 'private-app']
        for code in (0, 73, 124):
            with self.subTest(code=code):
                result = sim.Result(command, code, timed_out=code == 124)
                with patch.object(sim, 'bounded', return_value=result), \
                     patch.object(swift.time, 'monotonic', side_effect=[10, 12.5]):
                    try: swift.command(self.root, 'install', command, timeout=180)
                    except Exception:
                        self.assertNotEqual(code, 0)
                row = json.loads((self.root / 'install.status.json').read_text())
                self.assertEqual(row['elapsedSeconds'], 2.5)
                self.assertEqual(row['timeoutSeconds'], 180)
                self.assertEqual(row['exitCode'], None if code == 124 else code)


if __name__ == '__main__':
    unittest.main()
