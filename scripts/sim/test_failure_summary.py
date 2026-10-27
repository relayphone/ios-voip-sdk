"""Failure diagnostics must not consume cancellation or change retry behavior."""
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

import sim


class FailureSummaryTests(unittest.TestCase):
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
