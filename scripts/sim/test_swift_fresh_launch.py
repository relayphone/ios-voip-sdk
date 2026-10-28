"""The planned Swift console launch requests a fresh process without a retry."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_swift_livekit as runner


class SwiftFreshLaunchTests(unittest.TestCase):
    def test_each_mode_plans_exactly_one_fresh_launch_at_the_original_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for mode in runner.CASES:
                with self.subTest(mode=mode):
                    output = root / mode
                    output.mkdir()
                    primary = RuntimeError('host-only planned-spawn boundary')
                    with patch.object(subprocess, 'run', side_effect=AssertionError('native run denied')), \
                         patch.object(subprocess, 'Popen', side_effect=primary) as spawn, \
                         patch.object(runner.os, 'kill', side_effect=AssertionError('native signal denied')), \
                         patch.object(runner.os, 'killpg', side_effect=AssertionError('native group signal denied')):
                        with self.assertRaises(RuntimeError) as caught:
                            runner.capture_case(root, output, 'owned-simulator', '', mode)
                    self.assertIs(caught.exception, primary)
                    self.assertEqual(spawn.call_count, 1)
                    command = spawn.call_args.args[0]
                    self.assertEqual(command[command.index('--launch-command') + 1:],
                        ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process',
                         'owned-simulator', runner.BUNDLE])
                    self.assertEqual(command[command.index('--timeout') + 1], '90')
                    self.assertEqual(command.count('--startup-timeout'), 1)
                    self.assertEqual(command[command.index('--startup-timeout') + 1], '180')
                    self.assertEqual(command.count('--inherit-launcher-group'), 1)
                    self.assertIs(spawn.call_args.kwargs['start_new_session'], True)


if __name__ == '__main__':
    unittest.main()
