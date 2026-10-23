import contextlib
import io
import subprocess
import unittest
from unittest.mock import patch

import run


class RunnerTests(unittest.TestCase):
    def test_cold_boot_timeout_is_explicit_and_keeps_diagnostics(self):
        failure = subprocess.TimeoutExpired(['simctl'], 300, output=b'Waiting for SpringBoard')
        with patch.object(run.subprocess, 'run', side_effect=failure) as process:
            with self.assertRaisesRegex(RuntimeError, 'Waiting for SpringBoard'):
                run.run('xcrun', 'simctl', 'bootstatus', 'owned', '-b', timeout=300)
        self.assertEqual(process.call_args.kwargs['timeout'], 300)

    def test_delete_is_attempted_after_shutdown_fails(self):
        with patch.object(run, 'run', side_effect=[RuntimeError('shutdown timed out'), '']) as process:
            with self.assertRaisesRegex(RuntimeError, 'shutdown timed out'):
                run.remove_simulators(['owned'])
        self.assertEqual([call.args[2] for call in process.call_args_list], ['shutdown', 'delete'])
        self.assertTrue(all(call.kwargs['timeout'] == 30 for call in process.call_args_list))

    def test_cleanup_keeps_the_original_failure(self):
        with patch.object(run, 'run', side_effect=RuntimeError('cleanup failed')) as process:
            with contextlib.redirect_stderr(io.StringIO()) as output:
                with self.assertRaisesRegex(ValueError, 'original failure'):
                    try:
                        raise ValueError('original failure')
                    finally:
                        run.remove_simulators(['owned'])
        self.assertEqual(process.call_count, 2)
        self.assertIn('cleanup failed', output.getvalue())


if __name__ == '__main__':
    unittest.main()
