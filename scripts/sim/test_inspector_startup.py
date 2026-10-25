"""Canonical probe discovery and owned host-launch controls without simctl."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from inspector_startup import cleanup_operations, deferred_interrupts, locate_probe, supervise_launch


SIMULATOR = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
CONTAINER = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
OTHER = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC'
NONCE = 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD'
BUNDLE = 'dev.callkitsim.inspector'


class InspectorStartupTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name).resolve()
        self.devices = self.root / 'Devices'
        self.container = self.devices / SIMULATOR / 'data/Containers/Data/Application' / CONTAINER
        self.receipt = self.container / 'Documents/cksim-inspector-results.json'
        self.started = int(time.time() * 1000)

    def publish(self, **changes):
        self.receipt.parent.mkdir(parents=True, exist_ok=True)
        value = dict(nonce=NONCE, inspectorBundleID=BUNDLE, inspectorDataContainer=str(self.container))
        value.update(changes)
        self.receipt.write_text(json.dumps(value))

    def locate(self):
        return locate_probe(SIMULATOR, NONCE, BUNDLE, devices_root=self.devices)

    def test_absent_partial_and_stale_receipts_do_not_satisfy_fresh_discovery(self):
        self.assertIsNone(self.locate())
        self.publish(nonce='older-launch')
        self.assertIsNone(self.locate())
        self.receipt.write_text('{')
        self.assertIsNone(self.locate())
        self.publish()
        self.assertEqual(self.locate(), self.receipt)

    def test_fresh_identity_conflicts_duplicates_and_symlinks_are_terminal(self):
        for changes in (dict(inspectorBundleID='foreign.bundle'), dict(inspectorBundleID=None),
                        dict(inspectorDataContainer='/foreign/container')):
            with self.subTest(changes=changes):
                self.publish(**changes)
                with self.assertRaises(ValueError):
                    self.locate()
        self.publish()
        other = self.container.with_name(OTHER)
        path = other / 'Documents/cksim-inspector-results.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(dict(nonce=NONCE, inspectorBundleID=BUNDLE, inspectorDataContainer=str(other))))
        with self.assertRaises(ValueError):
            self.locate()
        path.unlink()
        self.receipt.rename(self.root / 'outside')
        self.receipt.symlink_to(self.root / 'outside')
        with self.assertRaises(ValueError):
            self.locate()

    def launch(self, observe, **kwargs):
        command = [sys.executable, '-c', 'import os,time; print("secret-token",flush=True); time.sleep(20)']
        return supervise_launch(command, env=dict(os.environ), log=self.root / 'launch.log',
                                observe=observe, bridge_alive=lambda: True, host_timeout=.3,
                                consumer_timeout=kwargs.pop('consumer_timeout', 25), redactions=('secret-token',), **kwargs)

    def test_qualified_native_ack_reaps_pending_host_and_revalidates_before_return(self):
        calls = []
        value = dict(online=True, inspectorPID=42, startedWallTimeMS=self.started, wallTimeMS=self.started,
                     session=dict(runID='fresh'), cursor=1)
        def observe(resume_after=None):
            calls.append(True)
            if resume_after is None and b'secret-token' not in (self.root / 'launch.log').read_bytes():
                return None
            return dict(value, wallTimeMS=resume_after if resume_after is not None else self.started)
        ready, deadline = self.launch(observe)
        self.assertEqual(ready['inspectorPID'], value['inspectorPID'])
        self.assertGreaterEqual(len(calls), 2)
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertTrue(outcome['qualifiedNativeAcknowledgement'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)
        self.assertNotIn('secret-token', (self.root / 'launch.log').read_text())
        self.assertIn('<redacted>', (self.root / 'launch.log').read_text())
        self.assertIsInstance(deadline, float)

    def test_offline_progress_cannot_resolve_or_replay_a_timed_out_launch(self):
        with self.assertRaisesRegex(RuntimeError, 'timed out'):
            self.launch(lambda **kwargs: dict(online=False, inspectorPID=42))
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertFalse(outcome['qualifiedNativeAcknowledgement'])
        self.assertTrue(outcome['timedOut'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_changed_native_identity_after_host_reap_is_terminal(self):
        values = iter([dict(online=True, inspectorPID=42, startedWallTimeMS=self.started, session={}, cursor=0),
                       dict(online=True, inspectorPID=43, startedWallTimeMS=self.started, session={}, cursor=0)])
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            self.launch(lambda **kwargs: next(values))
        outcome = json.loads((self.root / 'launch.json').read_text())
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_qualified_ack_observed_after_original_host_bound_is_rejected(self):
        def late(**kwargs):
            time.sleep(.35)
            return dict(online=True, inspectorPID=42, startedWallTimeMS=1, session={}, cursor=0)
        with self.assertRaisesRegex(RuntimeError, 'timed out'):
            self.launch(late)

    def test_old_online_receipt_cannot_acknowledge_app_survival_after_host_reap(self):
        value = dict(online=True, inspectorPID=42, startedWallTimeMS=self.started, wallTimeMS=self.started - 1,
                     session={}, cursor=0)
        with self.assertRaisesRegex(RuntimeError, 'budget|publication'):
            self.launch(lambda **kwargs: value, consumer_timeout=.2)

    def test_post_reap_publication_cannot_extend_the_original_startup_bound(self):
        value = dict(online=True, inspectorPID=42, startedWallTimeMS=self.started, session={}, cursor=0)
        def observe(resume_after=None):
            if resume_after is not None:
                time.sleep(.35)
            return dict(value, wallTimeMS=resume_after if resume_after is not None else self.started)
        with self.assertRaisesRegex(RuntimeError, 'budget expired'):
            self.launch(observe)

    def test_blocked_probe_observation_does_not_extend_the_native_host_lifetime(self):
        real_spawn = subprocess.Popen
        real_killpg = os.killpg
        processes = []
        watchdog_killed = threading.Event()
        killed_groups = []
        def spawn(*args, **kwargs):
            process = real_spawn(*args, **kwargs)
            processes.append(process)
            return process
        def killpg(group, signum):
            result = real_killpg(group, signum)
            if signum == signal.SIGKILL and threading.current_thread() is not threading.main_thread():
                killed_groups.append(group)
                watchdog_killed.set()
            return result
        def observe(**kwargs):
            self.assertTrue(watchdog_killed.wait(2), 'watchdog must kill while observation is blocked')
            self.assertEqual(killed_groups, [processes[0].pid])
            processes[0].wait(timeout=2)
            return None
        with patch('inspector_startup.subprocess.Popen', side_effect=spawn), \
                patch('inspector_startup.os.killpg', side_effect=killpg), \
                patch('inspector_startup.threading.Timer', wraps=threading.Timer) as timer:
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                self.launch(observe)
        self.assertLessEqual(timer.call_args.args[0], .3)

    def test_all_cleanup_stages_run_without_replacing_the_original_body_error(self):
        primary = ValueError('original product failure')
        called = []
        def fail():
            called.append('first')
            raise OSError('cleanup failed')
        with self.assertRaises(ValueError) as caught:
            try:
                raise primary
            finally:
                cleanup_operations(sys.exc_info()[1], [fail, lambda: called.append('second')])
        self.assertIs(caught.exception, primary)
        self.assertEqual(called, ['first', 'second'])

    def test_foreign_pending_host_ack_cannot_be_hidden_by_a_qualified_native_receipt(self):
        value = dict(online=True, inspectorPID=42, startedWallTimeMS=self.started,
                     wallTimeMS=self.started, session={}, cursor=0)
        process = Mock(pid=12345, returncode=None, poll=Mock(return_value=None))
        def spawn(command, **kwargs):
            kwargs['stdout'].write(b'foreign.bundle: 42\n')
            kwargs['stdout'].flush()
            return process
        with patch('inspector_startup.subprocess.Popen', side_effect=spawn), patch('inspector_startup.reap_group', side_effect=lambda process: setattr(process, 'returncode', -signal.SIGKILL)):
            with self.assertRaisesRegex(RuntimeError, 'acknowledgements conflict'):
                supervise_launch(['xcrun', 'simctl', 'launch'], env={}, log=self.root / 'launch.log',
                                 observe=lambda resume_after=None: dict(value, wallTimeMS=resume_after if resume_after is not None else self.started), bridge_alive=lambda: True,
                                 host_timeout=20, bundle=BUNDLE)

    def test_cancellation_reaps_the_owned_host_group_before_delivering_sigterm(self):
        log = self.root / 'cancel.log'
        script = f'''import os,sys
from pathlib import Path
sys.path.insert(0, {str(Path(__file__).parent)!r})
from inspector_startup import supervise_launch
supervise_launch([sys.executable, '-c', 'import os,time;print(os.getpid(),flush=True);time.sleep(20)'],
    env=dict(os.environ), log=Path({str(log)!r}), observe=lambda **kwargs: None,
    bridge_alive=lambda: True, host_timeout=10)
'''
        supervisor = subprocess.Popen([sys.executable, '-c', script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child = None
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if log.exists() and log.read_text().strip():
                    child = int(log.read_text().strip())
                    break
                time.sleep(.01)
            self.assertIsNotNone(child)
            os.kill(supervisor.pid, signal.SIGTERM)
            self.assertEqual(supervisor.wait(timeout=3), 143)
            with self.assertRaises(ProcessLookupError):
                os.killpg(child, 0)
        finally:
            if supervisor.poll() is None:
                supervisor.kill()
                supervisor.wait(timeout=2)
            if child is not None:
                try:
                    os.killpg(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_signal_setup_and_restoration_faults_restore_both_original_handlers(self):
        real_signal = signal.signal
        original = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        for transition in ('install', 'restore'):
            failed = []
            def fault(number, handler):
                restoring = handler is original[number]
                if number == signal.SIGTERM and not failed and (restoring == (transition == 'restore')):
                    failed.append(True)
                    raise RuntimeError('signal transition failed')
                return real_signal(number, handler)
            try:
                with patch('inspector_startup.signal.signal', side_effect=fault):
                    with self.assertRaisesRegex(RuntimeError, 'signal transition failed'):
                        with deferred_interrupts():
                            pass
                self.assertEqual({number: signal.getsignal(number) for number in original}, original)
            finally:
                for number, handler in original.items():
                    real_signal(number, handler)

    def test_body_failure_survives_a_cancellation_queued_during_reap(self):
        primary = ValueError('original failure')
        process = Mock(pid=12345, returncode=None, poll=Mock(return_value=None))
        def cleanup(process):
            process.returncode = -signal.SIGKILL
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        with patch('inspector_startup.subprocess.Popen', return_value=process), patch('inspector_startup.reap_group', side_effect=cleanup):
            with self.assertRaises(ValueError) as caught:
                supervise_launch(['fake'], env={}, log=self.root / 'launch.log', observe=Mock(side_effect=primary),
                                 bridge_alive=lambda: True, host_timeout=20)
        self.assertIs(caught.exception, primary)

    def test_previous_signal_callback_observes_the_host_group_already_reaped(self):
        events = []
        process = Mock(pid=12345, returncode=None, poll=Mock(return_value=None))
        class Cancelled(Exception):
            pass
        def previous(signum, frame):
            events.append('handler')
            raise Cancelled()
        def observe(**kwargs):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            return None
        def cleanup(process):
            events.append('reaped')
            process.returncode = -signal.SIGKILL
        original = signal.signal(signal.SIGTERM, previous)
        try:
            with patch('inspector_startup.subprocess.Popen', return_value=process), patch('inspector_startup.reap_group', side_effect=cleanup):
                with self.assertRaises(Cancelled):
                    supervise_launch(['fake'], env={}, log=self.root / 'launch.log', observe=observe,
                                     bridge_alive=lambda: True, host_timeout=20)
            self.assertLess(events.index('reaped'), events.index('handler'))
        finally:
            signal.signal(signal.SIGTERM, original)

    def test_primary_survives_a_signal_delivered_during_final_mask_restoration(self):
        primary = ValueError('original body failure')
        class Cancelled(Exception):
            pass
        def previous(signum, frame):
            raise Cancelled()
        real_mask = signal.pthread_sigmask
        original_mask = real_mask(signal.SIG_BLOCK, set())
        original = signal.signal(signal.SIGTERM, previous)
        injected = []
        def restore(how, mask):
            if how == signal.SIG_SETMASK and signal.getsignal(signal.SIGTERM) is previous and not injected:
                injected.append(True)
                os.kill(os.getpid(), signal.SIGTERM)
            return real_mask(how, mask)
        try:
            with patch('inspector_startup.signal.pthread_sigmask', side_effect=restore):
                with self.assertRaises(ValueError) as caught:
                    with deferred_interrupts():
                        raise primary
            self.assertIs(caught.exception, primary)
            self.assertTrue(injected)
        finally:
            signal.signal(signal.SIGTERM, original)
            real_mask(signal.SIG_SETMASK, original_mask)


if __name__ == '__main__':
    unittest.main()
