#!/usr/bin/env python3
"""Host-only cancellation controls at the native process creation boundary."""
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


HELPER = Path(__file__).with_name('sim.py')


class CancellationTests(unittest.TestCase):
    def assert_absent(self, pid):
        with self.assertRaises(ProcessLookupError, msg='cancelled native child is still alive or unreaped'):
            os.kill(pid, 0)

    @staticmethod
    def clean_child(pid):
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    def test_cancellation_after_child_creation_kills_and_reaps_native_child(self):
        helper = runpy.run_path(str(HELPER))
        sleeping = [sys.executable, '-c', 'import time;time.sleep(30)']
        for signum, command in ((signal.SIGTERM, sleeping), (signal.SIGINT, sleeping),
                                (signal.SIGTERM, [str(HELPER.parent / 'missing-native-command')])):
            with self.subTest(signal=signum, command=command):
                children = []

                def interrupted(received, _frame):
                    raise helper['Interrupted'](received)

                def trace(frame, event, _argument):
                    if (event == 'line' and frame.f_code.co_name == '_execute_child' and
                            getattr(frame.f_locals.get('self'), '_child_created', False) and not children):
                        children.append(frame.f_locals['self'].pid)
                        os.kill(os.getpid(), signum)
                    return trace

                previous = signal.signal(signum, interrupted)
                original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
                try:
                    sys.settrace(trace)
                    with self.assertRaises(helper['Interrupted']) as error:
                        helper['bounded'](command, .1)
                    sys.settrace(None)
                    self.assertEqual(error.exception.signum, signum)
                    self.assertEqual(len(children), 1, 'the process creation boundary was not exercised')
                    self.assert_absent(children[0])
                    self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), original_mask)
                finally:
                    sys.settrace(None)
                    signal.signal(signum, previous)
                    signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
                    for child in children:
                        self.clean_child(child)

    def test_cli_retains_sigterm_exit_status_at_process_creation_boundary(self):
        with tempfile.TemporaryDirectory(prefix='sim-cancellation-host-') as temporary:
            pid_file = Path(temporary) / 'child-pid'
            code = '''
import os, pathlib, runpy, signal, sys
helper = runpy.run_path(sys.argv[1])
children = []
def trace(frame, event, argument):
    if (event == 'line' and frame.f_code.co_name == '_execute_child' and
            getattr(frame.f_locals.get('self'), '_child_created', False) and not children):
        children.append(frame.f_locals['self'].pid)
        pathlib.Path(sys.argv[2]).write_text(str(children[0]))
        os.kill(os.getpid(), signal.SIGTERM)
    return trace
sys.settrace(trace)
sys.exit(helper['main'](['call', '', '2', sys.executable, '-c', 'import time;time.sleep(30)']))
'''
            child = None
            try:
                result = subprocess.run([sys.executable, '-c', code, str(HELPER), str(pid_file)],
                                        capture_output=True, text=True, timeout=10)
                self.assertTrue(pid_file.exists(), 'the process creation boundary was not exercised')
                child = int(pid_file.read_text())
                self.assertEqual(result.returncode, 143, result.stderr)
                self.assert_absent(child)
            finally:
                if child:
                    self.clean_child(child)

    def test_native_child_does_not_inherit_blocked_cancellation_signals(self):
        helper = runpy.run_path(str(HELPER))
        result = helper['bounded']([sys.executable, '-c',
            'import json,signal;print(json.dumps(list(signal.pthread_sigmask(signal.SIG_BLOCK, []))))'], 2)
        self.assertEqual(result.returncode, 0, result.stderr)
        blocked = json.loads(result.stdout)
        self.assertNotIn(signal.SIGTERM, blocked)
        self.assertNotIn(signal.SIGINT, blocked)

    def check_interrupted_handler_transition(self, stage, with_worker=False):
        helper = runpy.run_path(str(HELPER))
        children = []
        exercised = []

        def interrupted(signum, _frame):
            raise helper['Interrupted'](signum)

        def interrupt_int(signum, _frame):
            raise helper['Interrupted'](signum)

        originals = {signal.SIGTERM: interrupted, signal.SIGINT: interrupt_int}
        previous = {signum: signal.signal(signum, handler) for signum, handler in originals.items()}
        original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
        stop = threading.Event()
        worker = threading.Thread(target=stop.wait) if with_worker else None
        if worker:
            worker.start()

        def trace(frame, event, _argument):
            if (event == 'line' and frame.f_code.co_name == '_execute_child' and
                    getattr(frame.f_locals.get('self'), '_child_created', False) and not children):
                children.append(frame.f_locals['self'].pid)
            if event == 'line' and frame.f_code.co_name == 'bounded':
                process = frame.f_locals.get('process')
                restoring = (stage == 'restoration' and process is not None and
                        signal.getsignal(signal.SIGTERM) is interrupted and
                        signal.getsignal(signal.SIGINT) is not interrupt_int)
                installing = (stage == 'installation' and process is None and
                        signal.getsignal(signal.SIGTERM) is not interrupted and
                        signal.getsignal(signal.SIGINT) is interrupt_int)
                if not exercised and (restoring or installing):
                    exercised.append(True)
                    os.kill(os.getpid(), signal.SIGTERM if restoring else signal.SIGINT)
                    if with_worker:
                        time.sleep(.02)  # Let an unblocked worker schedule a Python signal callback.
            return trace

        try:
            sys.settrace(trace)
            with self.assertRaises(helper['Interrupted']):
                helper['bounded']([sys.executable, '-c', 'import time;time.sleep(30)'], 2)
            sys.settrace(None)
            self.assertTrue(exercised, 'the handler transition boundary was not exercised')
            self.assert_absent(children[0])
            for signum, handler in originals.items():
                self.assertIs(signal.getsignal(signum), handler)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), original_mask)
        finally:
            sys.settrace(None)
            for signum, handler in previous.items():
                signal.signal(signum, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
            for child in children:
                self.clean_child(child)
            stop.set()
            if worker:
                worker.join(timeout=2)

    def test_interrupted_handler_restoration_restores_parent_state(self):
        self.check_interrupted_handler_transition('restoration')

    def test_interrupted_handler_installation_restores_parent_state(self):
        self.check_interrupted_handler_transition('installation')

    def test_worker_signal_during_restoration_restores_parent_state(self):
        self.check_interrupted_handler_transition('restoration', with_worker=True)

    def check_timeout_cancellation(self, stage, with_worker=False):
        helper = runpy.run_path(str(HELPER))
        children, exercised = [], []
        stop = threading.Event()
        worker = threading.Thread(target=stop.wait) if with_worker else None

        def interrupted(signum, _frame):
            raise helper['Interrupted'](signum)

        previous = signal.signal(signal.SIGTERM, interrupted)
        previous_int = signal.getsignal(signal.SIGINT)
        original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
        if worker:
            worker.start()

        def trace(frame, event, _argument):
            if (event == 'line' and frame.f_code.co_name == '_execute_child' and
                    getattr(frame.f_locals.get('self'), '_child_created', False) and not children):
                children.append(frame.f_locals['self'].pid)
            native = frame
            while native is not None and native.f_code.co_name != 'bounded':
                native = native.f_back
            timeout_handler = (native is not None and
                               isinstance(native.f_locals.get('error'), subprocess.TimeoutExpired))
            boundary = ((stage == 'handler' and frame is native) or
                        (stage == 'reaping' and frame.f_code.co_name == 'communicate'))
            if event == 'line' and timeout_handler and boundary and not exercised:
                exercised.append(True)
                os.kill(os.getpid(), signal.SIGTERM)
                if worker:
                    time.sleep(.02)
            return trace

        try:
            sys.settrace(trace)
            with self.assertRaises(helper['Interrupted']):
                helper['bounded']([sys.executable, '-c', 'import time;time.sleep(30)'], .05)
            sys.settrace(None)
            self.assertTrue(exercised, 'the timeout cancellation boundary was not exercised')
            self.assert_absent(children[0])
            self.assertIs(signal.getsignal(signal.SIGTERM), interrupted)
            self.assertIs(signal.getsignal(signal.SIGINT), previous_int)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), original_mask)
        finally:
            sys.settrace(None)
            signal.signal(signal.SIGTERM, previous)
            signal.signal(signal.SIGINT, previous_int)
            signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
            for child in children:
                self.clean_child(child)
            stop.set()
            if worker:
                worker.join(timeout=2)

    def test_sigterm_on_timeout_handler_entry_kills_and_reaps_native_child(self):
        self.check_timeout_cancellation('handler')

    def test_sigterm_during_timeout_reaping_finishes_native_cleanup(self):
        self.check_timeout_cancellation('reaping')

    def test_worker_sigterm_on_timeout_handler_entry_finishes_native_cleanup(self):
        self.check_timeout_cancellation('handler', with_worker=True)

    def test_native_child_preserves_ignored_cancellation_signals(self):
        helper = runpy.run_path(str(HELPER))
        previous = {signum: signal.signal(signum, signal.SIG_IGN)
                    for signum in (signal.SIGTERM, signal.SIGINT)}
        try:
            result = helper['bounded']([sys.executable, '-c',
                'import json,signal;print(json.dumps([signal.getsignal(s)==signal.SIG_IGN '
                'for s in (signal.SIGTERM,signal.SIGINT)]))'], 2)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), [True, True])
            for signum in previous:
                self.assertEqual(signal.getsignal(signum), signal.SIG_IGN)
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


if __name__ == '__main__':
    unittest.main()
