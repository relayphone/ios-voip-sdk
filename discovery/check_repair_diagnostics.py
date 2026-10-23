#!/usr/bin/env python3
"""Pure repair evidence controls, plus one explicitly opt-in host timeout child."""
import hashlib
import json
import ast
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

import run_repair


TIMEOUT_FIELDS = {'phase', 'timeoutSeconds', 'elapsedSeconds', 'timedOut', 'reapTimedOut',
                  'reaped', 'postCleanupReturnCode', 'outputCapture', 'stdoutBytes', 'stderrBytes',
                  'stdoutSHA256', 'stderrSHA256'}
PRIVATE_MARKER = 'customer-private-argv-env-error-text'


def bind_command(out, process_module, os_module, clock):
    """Compile the real nested command without running main's native setup."""
    path = Path(__file__).with_name('run_repair.py')
    tree = ast.parse(path.read_text())
    main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'main')
    command = next(node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == 'command')
    wrapper = ast.parse('def bind():\n    phase = "fixture-start"\n    receipt = {"steps": []}\n').body[0]
    wrapper.body += [command, ast.parse('return command, receipt').body[0]]
    module = ast.fix_missing_locations(ast.Module(body=[wrapper], type_ignores=[]))
    namespace = dict(vars(run_repair), out=out, subprocess=process_module, os=os_module, time=clock)
    exec(compile(module, str(path), 'exec'), namespace)
    return namespace['bind']()


def timeout_fixture(stdout, stderr, *, reap_timed_out=False, initial_timeout=True, capture_error=False):
    """Only regular-file I/O is real; process lifecycle and clock are mocked."""
    initial = subprocess.TimeoutExpired([PRIVATE_MARKER], 1) if initial_timeout else ValueError(PRIVATE_MARKER)
    reap_error = subprocess.TimeoutExpired([PRIVATE_MARKER], 5)
    process = SimpleNamespace(pid=912347, returncode=None)

    def wait(timeout):
        if process.wait.call_count == 1:
            raise initial
        if reap_timed_out:
            raise reap_error
        process.returncode = -signal.SIGKILL
        return process.returncode

    process.wait = Mock(side_effect=wait)

    def spawn(*args, **kwargs):
        os.write(kwargs['stdout'].fileno(), stdout)
        os.write(kwargs['stderr'].fileno(), stderr)
        return process

    boundary = SimpleNamespace(Popen=Mock(side_effect=spawn), TimeoutExpired=subprocess.TimeoutExpired,
                               CompletedProcess=subprocess.CompletedProcess)
    operating_system = SimpleNamespace(killpg=Mock(), fstat=os.fstat,
        pread=Mock(side_effect=OSError(PRIVATE_MARKER)) if capture_error else os.pread)
    ticks = iter((100.0, 101.25))
    clock = SimpleNamespace(monotonic=lambda: next(ticks, 101.25))
    return boundary, operating_system, clock, process, reap_error if reap_timed_out else initial


class RepairDiagnosticsChecks(unittest.TestCase):
    def test_command_partial_timeout_capture_is_byte_exact_and_private(self):
        for initial_timeout, reap_timed_out in ((True, False), (True, True), (False, True)):
            for sensitive in (False, True):
                with self.subTest(initial_timeout=initial_timeout, reap_timed_out=reap_timed_out, sensitive=sensitive), \
                     tempfile.TemporaryDirectory(prefix='repair-pure-timeout-') as temporary:
                    out = Path(temporary)
                    stdout, stderr = b'partial-stdout-\xff\n', b'partial-stderr-\x80\n'
                    if sensitive:
                        stdout += PRIVATE_MARKER.encode()
                        stderr += PRIVATE_MARKER.encode()
                    boundary, operating_system, clock, process, original = timeout_fixture(
                        stdout, stderr, reap_timed_out=reap_timed_out, initial_timeout=initial_timeout)
                    command, receipt = bind_command(out, boundary, operating_system, clock)
                    message = 'fixture process group did not reap within five seconds' if reap_timed_out \
                        else 'fixture exceeded its bounded deadline'
                    with self.assertRaisesRegex(RuntimeError, '^' + message + '$') as caught:
                        command('fixture', [PRIVATE_MARKER], timeout=1,
                                env={'PRIVATE_FIXTURE_ENV': PRIVATE_MARKER}, sensitive=sensitive)
                    self.assertIs(caught.exception.__cause__, original)
                    self.assertEqual(process.wait.call_args_list, [call(timeout=1), call(timeout=5)])
                    operating_system.killpg.assert_called_once_with(process.pid, signal.SIGKILL)
                    self.assertTrue(boundary.Popen.call_args.kwargs['start_new_session'])
                    expected = dict(phase='fixture', timeoutSeconds=1, elapsedSeconds=1.25,
                        timedOut=initial_timeout, reapTimedOut=reap_timed_out, reaped=not reap_timed_out,
                        postCleanupReturnCode=None if reap_timed_out else -signal.SIGKILL,
                        outputCapture='partial-unreaped' if reap_timed_out else 'partial-reaped',
                        stdoutBytes=len(stdout), stderrBytes=len(stderr),
                        stdoutSHA256=hashlib.sha256(stdout).hexdigest(), stderrSHA256=hashlib.sha256(stderr).hexdigest())
                    self.assertEqual(receipt['steps'], [expected])
                    self.assertEqual(set(receipt['steps'][0]), TIMEOUT_FIELDS)
                    self.assertNotIn(PRIVATE_MARKER, json.dumps(receipt))
                    if sensitive:
                        self.assertEqual(list(out.iterdir()), [])
                    else:
                        self.assertEqual((out / 'fixture.stdout').read_bytes(), stdout)
                        self.assertEqual((out / 'fixture.stderr').read_bytes(), stderr)

    def test_command_diagnostic_io_failure_preserves_original_timeout_refusal(self):
        for reap_timed_out in (False, True):
            with self.subTest(reap_timed_out=reap_timed_out), \
                 tempfile.TemporaryDirectory(prefix='repair-pure-capture-failure-') as temporary:
                out = Path(temporary)
                boundary, operating_system, clock, process, original = timeout_fixture(
                    b'nonsecret-stdout\n', b'nonsecret-stderr\n', reap_timed_out=reap_timed_out, capture_error=True)
                command, receipt = bind_command(out, boundary, operating_system, clock)
                message = 'fixture process group did not reap within five seconds' if reap_timed_out \
                    else 'fixture exceeded its bounded deadline'
                with self.assertRaisesRegex(RuntimeError, '^' + message + '$') as caught:
                    command('fixture', [PRIVATE_MARKER], timeout=1)
                self.assertIs(caught.exception.__cause__, original)
                self.assertEqual(len(receipt['steps']), 1)
                self.assertEqual(receipt['steps'][0]['diagnosticCaptureErrorType'], 'OSError')
                self.assertEqual(receipt['steps'][0]['reapTimedOut'], reap_timed_out)
                self.assertNotIn(PRIVATE_MARKER, json.dumps(receipt))
                self.assertEqual(list(out.iterdir()), [])

    @unittest.skipUnless(os.environ.get('CKSIM_REPAIR_HOST_TIMEOUT_CONTROL') == '1',
                         'opt-in host child; default suite uses only pure process mocks')
    def test_opt_in_host_timeout_retains_flushed_output_and_reaps_child(self):
        # This is the suite's only real subprocess. No simulator/native setup,
        # descendants, inherited secrets, or other fixture processes are used.
        with tempfile.TemporaryDirectory(prefix='repair-host-timeout-') as temporary:
            out = Path(temporary)
            ready = out / 'host-child.ready'
            stdout, stderr = b'host-timeout-safe-stdout\n', b'host-timeout-safe-stderr\n'
            child = ('import pathlib,signal,sys\n'
                     'sys.stdout.buffer.write(b"host-timeout-safe-stdout\\n"); sys.stdout.flush()\n'
                     'sys.stderr.buffer.write(b"host-timeout-safe-stderr\\n"); sys.stderr.flush()\n'
                     'pathlib.Path(sys.argv[1]).write_text("ready\\n")\n'
                     'signal.alarm(3)\n'  # Test-only failsafe if the supervising control fails.
                     'signal.pause()\n')
            children = []

            def spawn(*args, **kwargs):
                process = subprocess.Popen(*args, **kwargs)
                children.append(process)
                return process

            boundary = SimpleNamespace(Popen=spawn, TimeoutExpired=subprocess.TimeoutExpired,
                                       CompletedProcess=subprocess.CompletedProcess)
            command, receipt = bind_command(out, boundary, os, time)
            started = time.monotonic()
            try:
                with self.assertRaisesRegex(RuntimeError, '^host-fixture exceeded its bounded deadline$'):
                    command('host-fixture', [sys.executable, '-I', '-c', child, str(ready)], timeout=1,
                            env={'PATH': '/usr/bin:/bin'})
            finally:
                for process in children:
                    if process.poll() is None:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        # Cleanup also works if the code under test regresses
                        # by failing to create the promised process session.
                        if process.poll() is None:
                            try:
                                process.kill()
                            except ProcessLookupError:
                                pass
                    process.wait(timeout=1)
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 5)
            ready_marker = ready.read_text()
            self.assertEqual(ready_marker, 'ready\n')
            self.assertEqual(len(children), 1)
            self.assertEqual(children[0].returncode, -signal.SIGKILL)
            captured_stdout = (out / 'host-fixture.stdout').read_bytes()
            captured_stderr = (out / 'host-fixture.stderr').read_bytes()
            self.assertEqual(captured_stdout, stdout)
            self.assertEqual(captured_stderr, stderr)
            self.assertEqual(len(receipt['steps']), 1)
            step = receipt['steps'][0]
            self.assertEqual(set(step), TIMEOUT_FIELDS)
            self.assertTrue(step['timedOut'])
            self.assertFalse(step['reapTimedOut'])
            self.assertTrue(step['reaped'])
            self.assertEqual(step['postCleanupReturnCode'], -signal.SIGKILL)
            self.assertEqual(step['outputCapture'], 'partial-reaped')
            self.assertEqual((step['stdoutBytes'], step['stderrBytes']), (len(stdout), len(stderr)))
            self.assertEqual(step['stdoutSHA256'], hashlib.sha256(stdout).hexdigest())
            self.assertEqual(step['stderrSHA256'], hashlib.sha256(stderr).hexdigest())
            print(json.dumps(dict(fixture='host-only synthetic; not native R4 acceptance',
                overallElapsedSeconds=round(elapsed, 3), failedStep=step,
                markerEvidence=dict(ready=ready_marker, stdout=captured_stdout.decode('ascii'),
                    stderr=captured_stderr.decode('ascii'),
                    stdoutSHA256=hashlib.sha256(captured_stdout).hexdigest(),
                    stderrSHA256=hashlib.sha256(captured_stderr).hexdigest())), sort_keys=True))

    def test_cli_journey_rejects_success_status_environment_read_diagnostics(self):
        # The journey has launch side effects at module scope. Compile its real
        # public reader alone and replace only the external process boundary.
        path = Path(__file__).with_name('cli_conformance.py')
        tree = ast.parse(path.read_text())
        reader = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'managed_environment')
        for status, stderr in [(0, ''), (0, 'launchctl read diagnostic\n'), (7, '')]:
            with self.subTest(status=status, stderr=stderr):
                process = SimpleNamespace(run=lambda *args, **kwargs: SimpleNamespace(returncode=status, stdout='', stderr=stderr))
                namespace = dict(subprocess=process, os=SimpleNamespace(environ={}), device='owned-fixture')
                exec(compile(ast.Module(body=[reader], type_ignores=[]), str(path), 'exec'), namespace)
                if status or stderr:
                    with self.assertRaisesRegex(AssertionError, 'cannot inspect managed environment'):
                        namespace['managed_environment']()
                else:
                    self.assertEqual(set(namespace['managed_environment']()), set(run_repair.KEYS))

    def test_missing_loader_is_identifiable_without_inherited_paths(self):
        inherited = '/private/customer-sensitive/Argent.dylib'
        before, loader = '/fixture/before.dylib', '/fixture/CKSimLoader.dylib'
        expected = {key: None for key in run_repair.KEYS}
        expected['DYLD_INSERT_LIBRARIES'] = ':'.join([inherited, before, loader])
        actual = dict(expected, DYLD_INSERT_LIBRARIES=':'.join([inherited, before]))
        evidence = run_repair.environment_diagnostic(actual, expected, {'before': before, 'loader': loader})
        self.assertNotIn(inherited, json.dumps(evidence))
        self.assertFalse(evidence['matchingKeys']['DYLD_INSERT_LIBRARIES'])
        self.assertTrue(evidence['matchingKeys']['CKSIM_PROFILE'])
        self.assertEqual(evidence['actualSHA256']['DYLD_INSERT_LIBRARIES'],
                         hashlib.sha256(actual['DYLD_INSERT_LIBRARIES'].encode()).hexdigest())
        self.assertEqual(evidence['expectedSHA256']['DYLD_INSERT_LIBRARIES'],
                         hashlib.sha256(expected['DYLD_INSERT_LIBRARIES'].encode()).hexdigest())
        self.assertEqual([row['role'] for row in evidence['dyld']['actualEntries']], ['inherited', 'before'])
        self.assertEqual([row['role'] for row in evidence['dyld']['expectedEntries']], ['inherited', 'before', 'loader'])
        self.assertFalse(evidence['dyld']['sameEntryInventory'])

    def test_exact_value_order_duplicates_and_transport_differences_remain_visible(self):
        before, loader = '/fixture/before.dylib', '/fixture/CKSimLoader.dylib'
        original = '/private/customer-sensitive/Argent.dylib'
        expected = {key: None for key in run_repair.KEYS}
        expected['DYLD_INSERT_LIBRARIES'] = ':'.join([original, before, loader])
        fixtures = dict(before=before, loader=loader)
        cases = [
            ('same', expected['DYLD_INSERT_LIBRARIES'], True, True),
            ('reordered', ':'.join([before, original, loader]), False, True),
            ('duplicate', expected['DYLD_INSERT_LIBRARIES']+':'+loader, False, False),
            ('newline', expected['DYLD_INSERT_LIBRARIES']+'\n', False, False),
            ('empty-component', expected['DYLD_INSERT_LIBRARIES']+':', False, False),
            ('path-alias', expected['DYLD_INSERT_LIBRARIES'].replace('/fixture/', '/fixture/./'), False, False),
        ]
        for name, value, ordered, inventory in cases:
            with self.subTest(name=name):
                evidence = run_repair.environment_diagnostic(dict(expected, DYLD_INSERT_LIBRARIES=value), expected, fixtures)
                self.assertEqual(evidence['dyld']['sameEntryOrder'], ordered)
                self.assertEqual(evidence['dyld']['sameEntryInventory'], inventory)
                self.assertEqual(evidence['matchingKeys']['DYLD_INSERT_LIBRARIES'], ordered)
                self.assertNotIn(original, json.dumps(evidence))
        reordered = run_repair.environment_diagnostic(
            dict(expected, DYLD_INSERT_LIBRARIES=':'.join([before, original, loader])), expected, fixtures)
        self.assertEqual([row['expectedIndices'] for row in reordered['dyld']['actualEntries']], [[1], [0], [2]])

    def test_absent_and_empty_values_are_distinct(self):
        expected = {key: None for key in run_repair.KEYS}
        actual = dict(expected, DYLD_INSERT_LIBRARIES='', CKSIM_ENABLED='')
        evidence = run_repair.environment_diagnostic(actual, expected, {})
        self.assertIsNone(evidence['expectedSHA256']['DYLD_INSERT_LIBRARIES'])
        self.assertEqual(evidence['actualSHA256']['DYLD_INSERT_LIBRARIES'], hashlib.sha256(b'').hexdigest())
        self.assertFalse(evidence['dyld']['sameEntryOrder'])
        self.assertFalse(evidence['dyld']['sameEntryInventory'])
        self.assertFalse(evidence['matchingKeys']['CKSIM_ENABLED'])


if __name__ == '__main__':
    unittest.main()
