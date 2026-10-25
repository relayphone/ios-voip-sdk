#!/usr/bin/env python3
"""Transport classifications remain separate from retry and product policy."""
from contextlib import redirect_stderr
import io
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sim
from test_shared_budget import DEVICE, FakeNative


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/sim/sim.py'
BUNDLE = 'dev.sim.transport.fixture'


class TransportClassificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sim-transport-labels-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'state.json'
        self.marker = self.root / 'classified'
        self.summary = self.root / 'summary.md'
        self.environment = patch.dict(os.environ, SIM_FAILURE_MARKER=str(self.marker),
                                      GITHUB_STEP_SUMMARY=str(self.summary), SIM_STATE='')
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop('SIM_STATE', None)

    def session(self, native=None):
        native = native or FakeNative()
        session = sim.Session(self.state, runner=native)
        self.assertEqual(session.call(['xcrun', 'simctl', 'create', 'owned', 'device', 'runtime'], 1).returncode, 0)
        return session, native

    def test_transport_proof_excludes_ordinary_or_unknown_exit_statuses(self):
        for result in (sim.Result([], 124, timed_out=True), sim.Result([], -signal.SIGALRM),
                       sim.Result([], 128 + signal.SIGALRM), sim.Result([], -signal.SIGTERM)):
            with self.subTest(result=result):
                self.assertTrue(sim.transport_failure(result))
        for status in (None, False, 0, 1, 3, 7, 124, 127, 128, 999, -999):
            with self.subTest(status=status):
                self.assertFalse(sim.transport_failure(sim.Result([], status)))

    def test_post_checkpoint_launch_transport_is_only_infrastructure_and_never_replayed(self):
        for index, response in enumerate((sim.Result([], 124, timed_out=True),
                sim.Result([], -signal.SIGALRM), sim.Result([], 128 + signal.SIGALRM))):
            with self.subTest(response=response), redirect_stderr(io.StringIO()):
                self.state = self.root / ('state-' + str(index) + '.json')
                self.summary.unlink(missing_ok=True)
                self.marker.unlink(missing_ok=True)
                session, native = self.session()
                session.checkpoint()
                calls = []
                def launch(command, timeout):
                    calls.append((command, timeout))
                    return response
                session.runner = launch
                returned = session.call(['xcrun', 'simctl', 'launch', DEVICE, BUNDLE], 8)
                self.assertIs(returned, response)
                self.assertTrue(returned.failure_classified)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][1], 8)
                self.assertFalse(session.state['retry_used'])
                self.assertEqual(native.count('create'), 1)
                labels = self.summary.read_text()
                self.assertIn('infra:launch', labels)
                self.assertNotIn('product:', labels)
                self.assertNotIn('scheduled', labels)
                self.assertTrue(self.marker.exists())

    def test_post_checkpoint_ordinary_launch_failure_keeps_product_classification(self):
        session, _ = self.session()
        session.checkpoint()
        response = sim.Result([], 7)
        session.runner = lambda command, timeout: response
        with redirect_stderr(io.StringIO()):
            self.assertIs(session.call(['xcrun', 'simctl', 'launch', DEVICE, BUNDLE], 8), response)
        self.assertTrue(response.failure_classified)
        self.assertIn('product:launch', self.summary.read_text())
        self.assertNotIn('infra:', self.summary.read_text())
        self.assertTrue(self.marker.exists())
        self.assertFalse(session.state['retry_used'])

    def test_recovered_preparation_and_cleanup_warning_are_not_terminal_markers(self):
        native = FakeNative()
        session, _ = self.session(native)
        native.failures.update(install=1, shutdown=1)
        with redirect_stderr(io.StringIO()):
            result = session.call(['xcrun', 'simctl', 'install', DEVICE, 'fixture.app'], 8)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(result.failure_classified)
        self.assertEqual(native.count('install'), 2)
        self.assertIn('infra:shutdown', self.summary.read_text())
        self.assertIn('recovered', self.summary.read_text())
        self.assertFalse(self.marker.exists())

    def test_product_primary_survives_independent_cleanup_warning(self):
        session, native = self.session()
        session.checkpoint()
        session.runner = lambda command, timeout: sim.Result(command, 7)
        with redirect_stderr(io.StringIO()):
            session.call(['xcrun', 'simctl', 'launch', DEVICE, BUNDLE], 8)
        self.marker.write_text('retained product failure')
        native.failures['delete'] = 1
        session.runner = native
        with redirect_stderr(io.StringIO()):
            self.assertNotEqual(session.cleanup(timeout=1).returncode, 0)
        labels = self.summary.read_text()
        self.assertIn('product:launch', labels)
        self.assertIn('infra:delete', labels)
        self.assertEqual(self.marker.read_text(), 'retained product failure')

    def shell(self, command, *, seconds=1, accepted=False, source_first=False, external=None):
        self.session()
        shell_marker = Path(str(self.state) + '.failure')
        setup = 'SIM_STATE=' + shlex.quote(str(self.state)) + '\nsource scripts/sim/sim.sh\n'
        if source_first:
            setup = 'source scripts/sim/sim.sh\nSIM_STATE=' + shlex.quote(str(self.state)) + '\n'
        script = 'set -u\n' + setup + '\n'
        if accepted:
            script += 'SIM_ACCEPTED_STATUS=1 '
        script += 'sim_limit ' + str(seconds) + ' ' + shlex.join(command) + '\nstatus=$?\n'
        script += 'if [[ -f "$SIM_STATE.failure" ]]; then printf marked; else printf unmarked; fi > ' + shlex.quote(str(self.root / 'before-fallback')) + '\n'
        if not accepted:
            script += 'if [[ "$status" -ne 0 && ! -f "$SIM_STATE.failure" ]]; then python3 "$SIM_HELPER" product shell-check; fi\n'
        script += 'exit "$status"\n'
        environment = dict(os.environ)
        environment.pop('SIM_FAILURE_MARKER', None)
        if external is not None:
            environment['SIM_FAILURE_MARKER'] = str(external)
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=environment,
                                capture_output=True, text=True, timeout=10)
        return result, shell_marker, (self.root / 'before-fallback').read_text()

    def test_unclassified_generic_exit_keeps_shell_product_fallback_available(self):
        for source_first in (False, True):
            with self.subTest(source_first=source_first):
                self.state = self.root / ('source-' + str(source_first) + '.json')
                self.summary.unlink(missing_ok=True)
                result, marker, observed = self.shell([sys.executable, '-c', 'import sys;sys.exit(7)'],
                                                      source_first=source_first)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(observed, 'unmarked')
                self.assertIn('product:shell-check', self.summary.read_text())
                self.assertNotIn('infra:', self.summary.read_text())

    def test_generic_timeout_is_classified_without_argument_or_environment_values(self):
        sentinel = 'classification-must-not-contain-this-value'
        with patch.dict(os.environ, PRIVATE_HOST_TOKEN=sentinel):
            result, marker, observed = self.shell([sys.executable, '-c', 'import time;time.sleep(30)', sentinel], seconds=.15)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(observed, 'marked')
        self.assertTrue(marker.exists())
        labels = self.summary.read_text()
        self.assertIn('infra:host', labels)
        self.assertNotIn('product:', labels)
        self.assertNotIn(sentinel, labels)
        self.assertNotIn('time.sleep', labels)

    def test_generic_signal_is_infrastructure_with_original_status_and_no_replay(self):
        count = self.root / 'host-launches'
        source = 'import os,pathlib,signal;pathlib.Path(' + repr(str(count)) + ').open("a").write("once\\n");os.kill(os.getpid(),signal.SIGALRM)'
        result, marker, observed = self.shell([sys.executable, '-c', source])
        self.assertEqual(result.returncode, 128 + signal.SIGALRM, result.stderr)
        self.assertEqual(count.read_text(), 'once\n')
        self.assertEqual(observed, 'marked')
        self.assertIn('infra:host', self.summary.read_text())
        self.assertNotIn('product:', self.summary.read_text())

    def test_expected_stateless_status_one_has_no_terminal_label_or_marker(self):
        binary = self.root / 'bin'
        binary.mkdir()
        executable = binary / 'xcrun'
        executable.write_text('#!' + sys.executable + '\nimport sys\nsys.exit(1)\n')
        executable.chmod(0o755)
        with patch.dict(os.environ, PATH=str(binary) + os.pathsep + os.environ.get('PATH', '')):
            result, marker, observed = self.shell(['xcrun', 'simctl', 'spawn', DEVICE, 'launchctl', 'getenv', 'SYNTHETIC_KEY'], accepted=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(observed, 'unmarked')
        self.assertFalse(marker.exists())
        self.assertFalse(self.summary.exists())

    def test_reports_honor_external_marker_and_also_mark_shell_owned_state(self):
        internal = Path(str(self.state) + '.failure')
        with patch.dict(os.environ, SIM_STATE=str(self.state)), redirect_stderr(io.StringIO()):
            sim.summary('infra:launch', 'scheduled')
            self.assertFalse(self.marker.exists())
            self.assertFalse(internal.exists())
            sim.report_failure('infra:launch')
            self.assertTrue(self.marker.exists())
            self.assertTrue(internal.exists())
            self.assertTrue(sim.failure_is_classified())
            sim.clear_failure_marker()
            self.assertFalse(self.marker.exists())
            self.assertFalse(internal.exists())

    def test_shell_keeps_external_primary_through_unrelated_success_and_failure(self):
        for index, status in enumerate((0, 7)):
            with self.subTest(status=status):
                self.state = self.root / ('sticky-' + str(index) + '.json')
                internal = Path(str(self.state) + '.failure')
                external = self.root / ('workflow-' + str(index) + '.failure')
                external.write_text('workflow primary')
                internal.write_text('shell primary')
                result, marker, observed = self.shell([sys.executable, '-c', 'import sys;sys.exit(' + str(status) + ')'],
                                                      external=external, source_first=bool(index))
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(observed, 'marked')
                self.assertEqual(external.read_text(), 'workflow primary')
                self.assertEqual(marker.read_text(), 'shell primary')
                self.assertFalse(self.summary.exists())

    def test_shell_transport_classification_keeps_the_external_marker_path(self):
        external = self.root / 'workflow-terminal'
        result, internal, observed = self.shell([sys.executable, '-c', 'import os,signal;os.kill(os.getpid(),signal.SIGALRM)'],
                                              external=external, source_first=True)
        self.assertEqual(result.returncode, 128 + signal.SIGALRM, result.stderr)
        self.assertTrue(external.is_file())
        self.assertTrue(internal.is_file())
        self.assertEqual(observed, 'marked')
        self.assertIn('infra:host', self.summary.read_text())
        self.assertNotIn('product:', self.summary.read_text())

    def test_reporting_io_failures_never_replace_the_original_result(self):
        session, _ = self.session()
        session.checkpoint()
        response = sim.Result([], 124, timed_out=True)
        session.runner = lambda command, timeout: response
        with patch.object(sim, 'summary', side_effect=OSError('unwritable summary')), \
             patch.object(Path, 'touch', side_effect=OSError('unwritable marker')):
            self.assertIs(session.call(['xcrun', 'simctl', 'launch', DEVICE, BUNDLE], 8), response)
        self.assertTrue(response.failure_classified)
        self.assertFalse(session.state['retry_used'])

    def test_closed_diagnostic_stream_preserves_the_original_result(self):
        session, _ = self.session()
        session.checkpoint()
        response = sim.Result([], 124, timed_out=True)
        session.runner = lambda command, timeout: response
        closed = io.StringIO()
        closed.close()
        with patch.object(sim.sys, 'stderr', closed):
            self.assertIs(session.call(['xcrun', 'simctl', 'launch', DEVICE, BUNDLE], 8), response)
        self.assertTrue(response.failure_classified)
        self.assertTrue(self.marker.exists())
        self.assertIn('infra:launch', self.summary.read_text())
        self.assertFalse(session.state['retry_used'])

    def test_classification_flag_belongs_only_to_the_exact_failed_generic_outcome(self):
        session, _ = self.session()
        for status in (0, 1, 7, 127, 128 + signal.SIGALRM):
            with self.subTest(status=status), redirect_stderr(io.StringIO()):
                response = sim.Result([], status)
                session.runner = lambda command, timeout: response
                self.assertIs(session.call(['host-fixture'], 8), response)
                self.assertEqual(response.failure_classified, status == 128 + signal.SIGALRM)

    def test_replacement_failure_marks_its_exact_result_without_another_retry(self):
        session, native = self.session()
        session.call(['xcrun', 'simctl', 'boot', DEVICE], 8)
        native.failures.update(install=1, boot=1)
        observed = []
        def execute(command, timeout):
            result = native(command, timeout)
            observed.append((command, result))
            return result
        session.runner = execute
        with redirect_stderr(io.StringIO()):
            result = session.call(['xcrun', 'simctl', 'install', DEVICE, 'fixture.app'], 8)
        self.assertIs(result, observed[-1][1])
        self.assertEqual(observed[-1][0][2], 'boot')
        self.assertTrue(result.failure_classified)
        self.assertFalse(observed[0][1].failure_classified)
        self.assertEqual(native.count('install'), 1)
        self.assertEqual(native.count('boot'), 2)
        self.assertIn('infra:install', self.summary.read_text())

    def test_summary_and_marker_io_are_best_effort(self):
        class BrokenStream:
            def write(self, value): raise OSError('closed diagnostic pipe')
            def flush(self): pass
        with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.root)), \
             patch.object(sim.sys, 'stderr', BrokenStream()), \
             patch.object(Path, 'touch', side_effect=PermissionError('unwritable marker')):
            sim.summary('infra:host', 'never retried')
            sim.report_failure('infra:host')
        self.marker.touch()
        with patch.object(Path, 'unlink', side_effect=PermissionError('retained marker')):
            sim.clear_failure_marker()
        self.assertTrue(self.marker.exists())
        with patch.object(Path, 'is_file', side_effect=OSError('unreadable marker')):
            self.assertFalse(sim.failure_is_classified())


if __name__ == '__main__':
    unittest.main()
