#!/usr/bin/env python3
"""Pure opt-in supervisor controls; every process/query/signal API is mocked."""
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import signal
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch
import tempfile

import run_scenario as supervisor
from sim import Result

BUNDLE = 'dev.iosvoipsdk.example'
SUPERVISOR, LAUNCHER, APP = 7001, 7002, 7003


class InheritedGroupControls(unittest.TestCase):
    def setUp(self):
        def mocked(owner, name, **options):
            patcher = patch.object(owner, name, **options)
            value = patcher.start(); self.addCleanup(patcher.stop); return value
        self.popen = mocked(supervisor.subprocess, 'Popen')
        self.command = mocked(supervisor, 'bounded', side_effect=lambda command, timeout: Result(command, 0))
        self.getpid = mocked(supervisor.os, 'getpid', return_value=SUPERVISOR)
        self.getpgid = mocked(supervisor.os, 'getpgid', return_value=SUPERVISOR)
        self.getsid = mocked(supervisor.os, 'getsid', return_value=SUPERVISOR)
        def kill(pid, signum):
            if (pid, signum) == (APP, 0):
                raise ProcessLookupError
        self.kill = mocked(supervisor.os, 'kill', side_effect=kill)
        self.killpg = mocked(supervisor.os, 'killpg')
        self.signals = mocked(supervisor.signal, 'signal')
        self.buffers = {}
        mocked(supervisor.os, 'openpty', return_value=(7004, 7005))
        original_close = supervisor.os.close
        mocked(supervisor.os, 'close', side_effect=lambda fd:
               None if fd in (7004, 7005) else original_close(fd))
        mocked(supervisor.tty, 'setraw')
        mocked(supervisor.select, 'select', side_effect=lambda read, *_: (sorted(read), [], []))
        mocked(supervisor.os, 'read', side_effect=lambda fd, _: self.buffers[fd].pop(0))
        mocked(supervisor.threading, 'Thread', side_effect=lambda target, daemon: SimpleNamespace(
            start=target, ident=1, join=lambda timeout: None, is_alive=lambda: False))

    def invoke(self, console=True, inherited=None):
        process = Mock(); process.pid = LAUNCHER; process.returncode = None
        rows = [dict(event='app.entry'), dict(event='launch', pid=APP), dict(event='done', t_ms=1)]
        probe = ''.join('PROBE ' + json.dumps(row) + '\n' for row in rows).encode()
        header = (BUNDLE + ': ' + str(APP) + '\n').encode()
        self.buffers = {7004: [header, b''], 7006: [probe if console else header + probe, b'']}
        process.stdout = None if console else SimpleNamespace(fileno=lambda: 7006, close=lambda: None)
        process.stderr = SimpleNamespace(fileno=lambda: 7006, close=lambda: None) if console else None
        process.poll.side_effect = lambda: process.returncode
        def wait(timeout): process.returncode = 0; return 0
        process.wait.side_effect = wait
        self.popen.return_value = process
        with tempfile.TemporaryDirectory(prefix='supervisor-group-pure-') as temporary:
            root = Path(temporary)
            options = {} if inherited is None else dict(inherit_launcher_group=inherited)
            code = supervisor.run(['synthetic-launch'], ['synthetic-stop'], root / 'output.log', root / 'receipt.json',
                                  2, dict(bundleID=BUNDLE), console_launcher_stop=console, **options)
            return code, json.loads((root / 'receipt.json').read_text())

    def test_default_launcher_stays_in_its_own_session(self):
        for console in (False, True):
            with self.subTest(console=console):
                code, receipt = self.invoke(console=console)
                self.assertEqual(code, 0); self.assertTrue(receipt['success'])
                self.assertIs(self.popen.call_args.kwargs['start_new_session'], True)
                self.assertNotIn('inheritLauncherGroup', receipt)
                self.getpgid.assert_not_called(); self.getsid.assert_not_called()
                self.killpg.assert_not_called()

    def test_opt_in_inherits_only_verified_private_group_and_binds_actual_child(self):
        code, receipt = self.invoke(inherited=True)
        self.assertEqual(code, 0); self.assertTrue(receipt['success'])
        self.assertIs(self.popen.call_args.kwargs['start_new_session'], False)
        self.assertIs(receipt['inheritLauncherGroup'], True)
        self.assertEqual({key: receipt[key] for key in ('supervisorPID', 'supervisorPGID', 'supervisorSID', 'launcherPGID')},
                         dict.fromkeys(('supervisorPID', 'supervisorPGID', 'supervisorSID', 'launcherPGID'), SUPERVISOR))
        self.assertEqual((receipt['launcherPID'], receipt['appPID'], receipt['launcherAppPID']), (LAUNCHER, APP, APP))
        self.assertEqual(self.getpgid.call_args_list, [call(0), call(LAUNCHER)])
        self.getsid.assert_called_once_with(0)
        self.assertEqual(self.kill.call_args_list, [call(LAUNCHER, signal.SIGTERM), call(APP, 0)])
        self.command.assert_not_called(); self.killpg.assert_not_called()

    def test_opt_in_refuses_bad_group_session_or_nonconsole_before_popen(self):
        for fault in ('group', 'session', 'nonconsole'):
            with self.subTest(fault=fault):
                self.popen.reset_mock(); self.command.reset_mock(); self.kill.reset_mock()
                self.getpgid.return_value = 7999 if fault == 'group' else SUPERVISOR
                self.getsid.return_value = 7999 if fault == 'session' else SUPERVISOR
                code, receipt = self.invoke(console=fault != 'nonconsole', inherited=True)
                self.assertEqual(code, 1); self.assertFalse(receipt['success'])
                self.popen.assert_not_called(); self.command.assert_not_called()
                self.kill.assert_not_called(); self.killpg.assert_not_called()

    def test_child_group_is_observed_instead_of_assumed(self):
        self.getpgid.side_effect = [SUPERVISOR, 7999]
        code, receipt = self.invoke(inherited=True)
        self.assertEqual(code, 1); self.assertFalse(receipt['success'])
        self.assertEqual(receipt['launcherPGID'], 7999)
        self.assertIn('did not inherit', receipt['error'])
        self.assertEqual(self.getpgid.call_args_list, [call(0), call(LAUNCHER)])
        self.kill.assert_not_called(); self.killpg.assert_not_called()

    def test_cli_parses_opt_in_and_refuses_nonconsole(self):
        with tempfile.TemporaryDirectory(prefix='supervisor-group-cli-pure-') as temporary:
            root = Path(temporary)
            for console, inherited in ((True, True), (True, False), (False, True)):
                with self.subTest(console=console, inherited=inherited):
                    args = ['run_scenario.py', '--output', str(root / 'output.log'), '--receipt', str(root / 'receipt.json'), '--bundle-id', BUNDLE]
                    if console: args.append('--console-launcher-stop')
                    if inherited: args.append('--inherit-launcher-group')
                    args += ['--terminate-command', 'synthetic-stop', '--launch-command', 'synthetic-launch']
                    with patch.object(sys, 'argv', args), patch.object(supervisor, 'run', return_value=0) as run, redirect_stderr(io.StringIO()):
                        if not console:
                            with self.assertRaises(SystemExit) as error: supervisor.main()
                            self.assertEqual(error.exception.code, 2); run.assert_not_called()
                        else:
                            self.assertEqual(supervisor.main(), 0)
                            self.assertIs(run.call_args.kwargs['console_launcher_stop'], True)
                            self.assertIs(run.call_args.kwargs['inherit_launcher_group'], inherited)
            self.popen.assert_not_called(); self.command.assert_not_called()
            self.kill.assert_not_called(); self.killpg.assert_not_called()


if __name__ == '__main__':
    unittest.main()
