#!/usr/bin/env python3
"""SDK control transport failures retain their identity and independent labels."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import sim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_sdk_system as runner
import sdk_system_conformance as gate


class ControlClassificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='sim-control-labels-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.package, self.container = self.root / 'package', self.root / 'container'
        self.package.mkdir(); self.container.mkdir()
        (self.package / 'fixture').write_text('inert host package')
        self.summary, self.marker = self.root / 'summary.md', self.root / 'classified'
        self.args = SimpleNamespace(package=self.package, output=self.root / 'output',
            simulator='host-owned', run_id='host-run', data_container=self.container)
        environment = patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.summary),
                                 SIM_FAILURE_MARKER=str(self.marker))
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop('SIM_STATE', None)

    def labels(self):
        return self.summary.read_text() if self.summary.exists() else ''

    def journey(self, name='case'):
        return runner.Journey(self.args, self.root / name, 'answer-end', self.container)

    def assert_command(self, transport):
        transport.assert_called_once()
        command = transport.call_args.args[0]
        self.assertEqual(command[0], str(self.package / 'cksim'))
        self.assertEqual(command[-1], 'host-argument')
        self.assertEqual(transport.call_args.kwargs, {'capture_output': True, 'timeout': 75})

    def test_cli_timeout_is_infrastructure_without_replacing_the_exception(self):
        journey = self.journey()
        error = subprocess.TimeoutExpired(['private-argv-sentinel'], 75,
                                          output=b'private-output-sentinel')
        with patch.object(runner.subprocess, 'run', side_effect=error) as transport:
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                journey.cli('push', 'host-argument')
        self.assertIs(raised.exception, error)
        self.assert_command(transport)
        self.assertIn('infra:control', self.labels())
        self.assertNotIn('product:', self.labels())
        self.assertNotIn('private-', self.labels())
        self.assertTrue(self.marker.exists())
        self.assertEqual(journey.controls, [])

    def test_cli_spawn_failure_is_infrastructure_without_replacing_the_exception(self):
        journey = self.journey()
        error = FileNotFoundError('private-host-path-sentinel')
        with patch.object(runner.subprocess, 'run', side_effect=error) as transport:
            with self.assertRaises(FileNotFoundError) as raised:
                journey.cli('push', 'host-argument')
        self.assertIs(raised.exception, error)
        self.assert_command(transport)
        self.assertIn('infra:control', self.labels())
        self.assertNotIn('product:', self.labels())
        self.assertNotIn('private-', self.labels())
        self.assertTrue(self.marker.exists())

    def test_closed_diagnostic_stream_preserves_the_control_exception(self):
        journey = self.journey()
        error = subprocess.TimeoutExpired(['private-control-sentinel'], 75)
        closed = io.StringIO()
        closed.close()
        with patch.object(runner.subprocess, 'run', side_effect=error), \
             patch.object(sim.sys, 'stderr', closed):
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                journey.cli('push', 'host-argument')
        self.assertIs(raised.exception, error)
        self.assertTrue(self.marker.exists())
        self.assertIn('infra:control', self.labels())
        self.assertNotIn('product:', self.labels())

    def test_expected_control_refusal_is_preserved_without_a_failure_label(self):
        journey = self.journey()
        value = {'success': False, 'error': 'expected reset refusal'}
        completed = subprocess.CompletedProcess(['host-control'], 1, json.dumps(value).encode(), b'')
        with patch.object(runner.subprocess, 'run', return_value=completed) as transport:
            self.assertEqual(journey.cli('reset', 'host-argument', expected_error='reset refusal'), value)
        self.assert_command(transport)
        self.assertEqual(journey.controls, ['control-00.json'])
        self.assertEqual(self.labels(), '')
        self.assertFalse(self.marker.exists())

    def test_returned_signal_is_classified_before_json_and_retains_status_and_bytes(self):
        for status in (-signal.SIGALRM, 128 + signal.SIGALRM):
            with self.subTest(status=status):
                self.summary.unlink(missing_ok=True)
                self.marker.unlink(missing_ok=True)
                journey = self.journey(str(status))
                completed = subprocess.CompletedProcess(['host-control'], status,
                    b'private-malformed-json-output', b'private-control-error')
                with patch.object(runner.subprocess, 'run', return_value=completed) as transport:
                    with self.assertRaises(subprocess.CalledProcessError) as raised:
                        journey.cli('push', 'host-argument')
                self.assertIs(raised.exception, journey.control_transport_error)
                self.assertEqual(raised.exception.returncode, status)
                self.assertIs(raised.exception.output, completed.stdout)
                self.assertIs(raised.exception.stderr, completed.stderr)
                self.assertIs(raised.exception.cmd, transport.call_args.args[0])
                self.assert_command(transport)
                self.assertEqual(journey.controls, ['control-00.json'])
                self.assertEqual((journey.root / 'control-00.json.stdout').read_bytes(), completed.stdout)
                self.assertEqual((journey.root / 'control-00.json.stderr').read_bytes(), completed.stderr)
                self.assertIn('infra:control', self.labels())
                self.assertNotIn('product:', self.labels())
                self.assertNotIn('private-', self.labels())

    def test_successful_control_result_is_unchanged(self):
        journey = self.journey()
        value = {'success': True, 'id': 'host-control-id'}
        completed = subprocess.CompletedProcess(['host-control'], 0, json.dumps(value).encode(), b'')
        with patch.object(runner.subprocess, 'run', return_value=completed) as transport:
            self.assertEqual(journey.cli('push', 'host-argument'), value)
        self.assert_command(transport)
        self.assertIsNone(journey.control_transport_error)
        self.assertEqual(self.labels(), '')
        self.assertFalse(self.marker.exists())

    def invoke(self, primary=None, *, earlier_control=False, clear_marker=False,
               cleanup_failure=False, returned=None):
        self.summary.unlink(missing_ok=True)
        self.marker.unlink(missing_ok=True)
        self.args.output = self.root / ('output-' + str(len(list(self.root.glob('output-*')))))
        owner, waits, starts, observed = 7001, [], [], []
        class Process:
            pid = owner
            alive = True
            def poll(self): return None if self.alive else 0
            def wait(self, timeout):
                waits.append(timeout)
                self.alive = False
                return 0
        process = Process()
        previous = subprocess.TimeoutExpired(['private-control-sentinel'], 75)
        def start(journey, *_):
            starts.append(journey)
            journey.process = process
            journey.runtime.parent.mkdir(parents=True, exist_ok=True)
            (journey.runtime.parent / 'session.json').write_text(json.dumps(
                dict(runID=self.args.run_id, pid=7003, bundleID=runner.BUNDLE)) + '\n')
            if earlier_control:
                try:
                    journey.cli('synthetic-earlier-control', 'host-argument')
                except subprocess.TimeoutExpired as caught:
                    self.assertIs(caught, previous)
                if clear_marker:
                    sim.clear_failure_marker()
            return dict(pid=7003)
        def push(journey, _role):
            if earlier_control:
                raise primary
            try:
                return journey.cli('push', 'host-argument')
            except Exception as error:
                observed.append(error)
                raise
        failure = previous if earlier_control else primary
        transport_patch = (patch.object(runner.subprocess, 'run', return_value=returned) if returned is not None else
                           patch.object(runner.subprocess, 'run', side_effect=failure))
        returned_transport = returned is not None and returned.returncode in (-signal.SIGALRM, 128 + signal.SIGALRM)
        if returned is not None:
            expected_type = subprocess.CalledProcessError if returned_transport else gate.EvidenceError
        else:
            expected_type = type(primary)
        with patch.object(runner.m0, 'source_identity', return_value={}), \
             patch.object(gate, 'package_check'), patch.object(runner, 'CASES', ('answer-end',)), \
             patch.object(runner.Journey, 'start', new=start), \
             patch.object(runner.Journey, 'push', new=push), \
             patch.object(runner.Journey, 'sim', side_effect=(RuntimeError('independent cleanup failure')
                 if cleanup_failure else None)) as stop, \
             transport_patch as transport, \
             patch.object(runner.subprocess, 'Popen', side_effect=AssertionError('unexpected native launch')), \
             patch.object(runner.signal, 'signal'), \
             patch.object(runner.os, 'killpg', side_effect=ProcessLookupError) as group:
            with self.assertRaises(expected_type) as raised:
                runner.run(self.args)
        if returned is not None:
            self.assertIs(raised.exception, observed[0])
            if returned_transport:
                self.assertIs(raised.exception, starts[0].control_transport_error)
                self.assertEqual(raised.exception.returncode, returned.returncode)
                self.assertIs(raised.exception.output, returned.stdout)
                self.assertIs(raised.exception.stderr, returned.stderr)
                self.assertIs(raised.exception.cmd, transport.call_args.args[0])
            else:
                self.assertIsNone(starts[0].control_transport_error)
        else:
            self.assertIs(raised.exception, primary)
        self.assertEqual(len(starts), 1)
        self.assertEqual(waits, [25])
        self.assert_command(transport)
        stop.assert_called_once_with('terminate', 'host-owned', runner.BUNDLE, timeout=10)
        group.assert_called_once_with(owner, 0)
        self.assertTrue(self.marker.exists())
        return self.labels()

    def test_journey_timeout_has_no_product_duplicate_and_retains_cleanup_label(self):
        for cleanup in (False, True):
            with self.subTest(cleanup=cleanup):
                error = subprocess.TimeoutExpired(['private-control-sentinel'], 75)
                labels = self.invoke(error, cleanup_failure=cleanup)
                self.assertEqual(labels.count('infra:control'), 1)
                self.assertNotIn('product:', labels)
                self.assertEqual('infra:terminate' in labels, cleanup)

    def test_journey_spawn_failure_has_no_product_duplicate(self):
        labels = self.invoke(FileNotFoundError('private-host-path-sentinel'), cleanup_failure=True)
        self.assertEqual(labels.count('infra:control'), 1)
        self.assertIn('infra:terminate', labels)
        self.assertNotIn('product:', labels)
        self.assertNotIn('private-', labels)

    def test_returned_signals_keep_the_same_exception_through_native_fallback_and_cleanup(self):
        for status in (-signal.SIGALRM, 128 + signal.SIGALRM):
            for cleanup in (False, True):
                with self.subTest(status=status, cleanup=cleanup), \
                     patch.object(runner, 'failure_is_classified', return_value=False):
                    completed = subprocess.CompletedProcess(['host-control'], status,
                        b'private-malformed-json-output', b'private-control-error')
                    labels = self.invoke(returned=completed, cleanup_failure=cleanup)
                    self.assertEqual(labels.count('infra:control'), 1)
                    self.assertNotIn('product:', labels)
                    self.assertEqual('infra:terminate' in labels, cleanup)
                    self.assertNotIn('private-', labels)

    def test_ordinary_control_refusal_remains_product_with_independent_cleanup(self):
        for status in (1, 73):
            with self.subTest(status=status):
                completed = subprocess.CompletedProcess(['host-control'], status,
                    b'{"success":false,"error":"unexpected refusal"}', b'')
                labels = self.invoke(returned=completed, cleanup_failure=True)
                self.assertIn('product:sdk-system-answer-end', labels)
                self.assertIn('infra:terminate', labels)
                self.assertNotIn('infra:control', labels)

    def test_unavailable_marker_cannot_add_product_for_the_same_control_exception(self):
        error = subprocess.TimeoutExpired(['private-control-sentinel'], 75)
        with patch.object(runner, 'failure_is_classified', return_value=False):
            labels = self.invoke(error)
        self.assertEqual(labels.count('infra:control'), 1)
        self.assertNotIn('product:', labels)

    def test_real_product_after_prior_transport_failure_is_not_hidden_by_its_marker(self):
        primary = RuntimeError('synthetic product assertion')
        labels = self.invoke(primary, earlier_control=True, cleanup_failure=True)
        self.assertEqual(labels.count('infra:control'), 1)
        self.assertEqual(labels.count('product:sdk-system-answer-end'), 1)
        self.assertEqual(labels.count('infra:terminate'), 1)
        self.assertLess(labels.index('product:'), labels.index('infra:terminate'))

    def test_product_failure_after_recovered_control_still_classifies(self):
        labels = self.invoke(RuntimeError('synthetic product assertion'), earlier_control=True,
                             clear_marker=True)
        self.assertEqual(labels.count('infra:control'), 1)
        self.assertEqual(labels.count('product:sdk-system-answer-end'), 1)
        self.assertNotIn('infra:terminate', labels)

    def test_unrelated_oserror_remains_a_product_primary(self):
        labels = self.invoke(OSError('synthetic assertion filesystem error'), earlier_control=True)
        self.assertIn('infra:control', labels)
        self.assertIn('product:sdk-system-answer-end', labels)


if __name__ == '__main__':
    unittest.main()
