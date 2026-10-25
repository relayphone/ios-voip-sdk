#!/usr/bin/env python3
"""SDK control transport failures retain their identity and independent labels."""
import io
import json
import os
from pathlib import Path
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

    def journey(self):
        return runner.Journey(self.args, self.root / 'case', 'answer-end', self.container)

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

    def invoke(self, primary, *, earlier_control=False, clear_marker=False, cleanup_failure=False):
        self.summary.unlink(missing_ok=True)
        self.marker.unlink(missing_ok=True)
        self.args.output = self.root / ('output-' + str(len(list(self.root.glob('output-*')))))
        owner, waits, starts = 7001, [], []
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
            return journey.cli('push', 'host-argument')
        failure = previous if earlier_control else primary
        with patch.object(runner.m0, 'source_identity', return_value={}), \
             patch.object(gate, 'package_check'), patch.object(runner, 'CASES', ('answer-end',)), \
             patch.object(runner.Journey, 'start', new=start), \
             patch.object(runner.Journey, 'push', new=push), \
             patch.object(runner.Journey, 'sim', side_effect=(RuntimeError('independent cleanup failure')
                 if cleanup_failure else None)) as stop, \
             patch.object(runner.subprocess, 'run', side_effect=failure) as transport, \
             patch.object(runner.subprocess, 'Popen', side_effect=AssertionError('unexpected native launch')), \
             patch.object(runner.signal, 'signal'), \
             patch.object(runner.os, 'killpg', side_effect=ProcessLookupError) as group:
            with self.assertRaises(type(primary)) as raised:
                runner.run(self.args)
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
