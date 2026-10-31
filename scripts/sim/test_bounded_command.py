"""Host-only checks of the bounded command entry point."""
import os
from pathlib import Path
import signal
import runpy
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

COMMAND = Path(__file__).resolve().parents[1] / 'ci/bounded'


class BoundedTests(unittest.TestCase):
    def run_command(self, *args, **kwargs):
        return subprocess.run([sys.executable, str(COMMAND), *args],
                              capture_output=True, text=True, timeout=15, **kwargs)

    def test_exit_status_and_argument_bytes_pass_through_without_a_shell(self):
        result = self.run_command('3', sys.executable, '-c',
                                 'import sys; print(sys.argv[1]); sys.exit(7)', '$(not-a-shell); literal')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, '$(not-a-shell); literal\n')

    def test_invalid_budgets_do_not_start_a_command(self):
        for value in ('0', '-1', 'nan', 'inf', 'bad'):
            with self.subTest(value=value):
                self.assertEqual(self.run_command(value, 'not-a-command').returncode, 2)
        self.assertEqual(self.run_command('1', 'not-a-command').returncode, 127)

    def test_cancellation_racing_a_successful_wait_cannot_return_success(self):
        program = runpy.run_path(str(COMMAND))
        handlers, sent = {}, []
        def install(sig, handler):
            previous = handlers.get(sig, signal.SIG_DFL)
            handlers[sig] = handler
            return previous
        class Child:
            pid = 42
            def wait(self, **_options):
                handlers[signal.SIGTERM](signal.SIGTERM, None)
                return 0
        with patch.object(signal, 'signal', side_effect=install), \
             patch.object(subprocess, 'Popen', return_value=Child()), \
             patch.object(os, 'killpg', side_effect=lambda pid, sig: sent.append((pid, sig))), \
             patch.object(time, 'sleep'), patch.dict(program['execute'].__globals__, GRACE_SECONDS=.001):
            self.assertEqual(program['main'](['1', 'synthetic']), 143)
        self.assertEqual([row for row in sent if row[1]], [(42, signal.SIGTERM), (42, signal.SIGKILL)])

    def test_timeout_sends_term_then_kills_an_ignoring_owned_group(self):
        with tempfile.TemporaryDirectory(prefix='bounded-host-') as temporary:
            marker = Path(temporary) / 'term'
            descendant = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)'
            child = ('import os,signal,time,sys,subprocess; '
                     'signal.signal(signal.SIGTERM,lambda *_:open(sys.argv[1],"w").write("term")); '
                     'other=subprocess.Popen([sys.executable,"-c",sys.argv[2]]); '
                     'print(os.getpid(),other.pid,flush=True); time.sleep(30)')
            started = time.monotonic()
            result = self.run_command('.5', sys.executable, '-c', child, str(marker), descendant)
            elapsed = time.monotonic() - started
            self.assertEqual(result.returncode, 124)
            self.assertEqual(marker.read_text(), 'term')
            self.assertGreaterEqual(elapsed, 10)
            self.assertLess(elapsed, 14)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(result.stdout.split()[0]), 0)
            status = subprocess.run(['ps', '-p', result.stdout.split()[1], '-o', 'stat='],
                                    capture_output=True, text=True, timeout=2)
            self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith('Z'),
                            'SIGTERM-ignoring descendant remained running')


if __name__ == '__main__':
    unittest.main()
