"""Failure diagnostics must not consume cancellation or change retry behavior."""
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

import sim


class FailureSummaryTests(unittest.TestCase):
    def test_preclassified_capture_failure_keeps_state_snapshot_without_reclassification(self):
        device = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
        calls = []
        def runner(command, timeout):
            calls.append(command)
            if command[2] == 'create':
                return sim.Result(command, 0, stdout=(device + '\n').encode())
            return sim.Result(command, 1, failure_classified=True)
        with tempfile.TemporaryDirectory(prefix='sim-summary-') as root:
            session = sim.Session(Path(root) / 'state.json', runner=runner)
            session.call(['xcrun', 'simctl', 'create', 'owned', 'type', 'runtime'], 2)
            session.checkpoint()
            with patch.object(sim, 'summary') as summary, patch.object(sim, 'report_failure') as report:
                result = session.call(['xcrun', 'simctl', 'launch', device, 'dev.fixture'], 2)
            self.assertTrue(result.failure_classified)
            report.assert_not_called()
            summary.assert_called_once()
            self.assertEqual(summary.call_args.args[0], 'simulator-state')
            self.assertIn('checkpoint=true', summary.call_args.args[1])
            self.assertIn('retry_used=false', summary.call_args.args[1])
            self.assertEqual([row[2] for row in calls], ['create', 'launch'])

    def test_interruption_during_summary_prevents_recovery(self):
        device = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
        calls = []
        def runner(command, timeout):
            calls.append(command)
            if command[2] == 'create':
                return sim.Result(command, 0, stdout=(device + '\n').encode())
            return sim.Result(command, 73)
        with tempfile.TemporaryDirectory(prefix='sim-summary-') as root:
            session = sim.Session(Path(root) / 'state.json', runner=runner)
            session.call(['xcrun', 'simctl', 'create', 'owned', 'type', 'runtime'], 2)
            def interrupted(label, detail):
                if label == 'simulator-state':
                    raise sim.Interrupted(signal.SIGTERM)
            with patch.object(sim, 'summary', side_effect=interrupted):
                with self.assertRaises(sim.Interrupted):
                    session.call(['xcrun', 'simctl', 'boot', device], 2)
            self.assertEqual([row[2] for row in calls], ['create', 'boot'])
            self.assertFalse(session.state['retry_used'])


if __name__ == '__main__': unittest.main()
