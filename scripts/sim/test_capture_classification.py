#!/usr/bin/env python3
"""Classification controls retain native transport failures without replay."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import run_scenario as capture

BUNDLE = 'dev.callkitsim.transportfixture'


class CaptureClassificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='sim-capture-transport-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.summary = self.root / 'summary.md'
        self.marker = self.root / 'classified'
        self.environment = patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.summary),
                                      SIM_FAILURE_MARKER=str(self.marker))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop('SIM_STATE', None)

    def classify(self, **changes):
        value = dict(completed=False, success=False, scenario='transport-case', bundleID=BUNDLE,
                     launchExitCodeBeforeCleanup=0, launchExitCode=0,
                     error='launcher exited before terminal done event',
                     cleanupExitCode=3, cleanupStdout='', cleanupStderr=sim.not_running_error(BUNDLE))
        value.update(changes)
        capture.report_capture_failure(value, b'', 3, capture_failure=True)
        self.assertTrue(self.marker.is_file())
        return self.summary.read_text()

    def test_known_signal_before_app_entry_is_only_launch_infrastructure(self):
        for status in (-signal.SIGALRM, 128 + signal.SIGALRM):
            with self.subTest(status=status):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(launchExitCodeBeforeCleanup=status, launchExitCode=status)
                self.assertIn('infra:launch', labels)
                self.assertNotIn('product:', labels)
                self.assertNotIn('infra:terminate', labels)

    def test_known_supervisor_deadline_without_app_evidence_is_infrastructure(self):
        labels = self.classify(launchExitCodeBeforeCleanup=None, launchExitCode=-signal.SIGTERM,
                               error='deadline before terminal done event')
        self.assertIn('infra:launch', labels)
        self.assertNotIn('product:', labels)

    def test_native_alarm_after_an_unknown_precleanup_poll_is_still_transport(self):
        labels = self.classify(launchExitCodeBeforeCleanup=None, launchExitCode=142)
        self.assertIn('infra:launch', labels)
        self.assertNotIn('product:', labels)

    def test_transport_primary_retains_independent_cleanup_failure(self):
        labels = self.classify(launchExitCodeBeforeCleanup=142, launchExitCode=142,
                               cleanupExitCode=7, cleanupStderr='independent cleanup refusal')
        self.assertIn('infra:launch', labels)
        self.assertIn('infra:terminate', labels)
        self.assertNotIn('product:', labels)

    def test_cleanup_signal_is_not_inferred_to_be_the_primary_transport_failure(self):
        labels = self.classify(launchExitCodeBeforeCleanup=None, launchExitCode=-signal.SIGTERM,
                               error='synthetic product assertion', cleanupExitCode=7)
        self.assertIn('product:transport-case', labels)
        self.assertIn('infra:terminate', labels)
        self.assertNotIn('infra:launch', labels)

    def test_app_evidence_preserves_product_failure_even_with_signal_or_deadline(self):
        for evidence in ({'appPID': 7001}, {'launcherAppPID': 7001},
                         {'appEntryObserved': True}, {'lastProbeEvent': 'app.entry'}):
            with self.subTest(evidence=evidence):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(launchExitCodeBeforeCleanup=142, launchExitCode=142,
                    error='deadline before terminal done event', cleanupExitCode=7, **evidence)
                self.assertIn('product:transport-case', labels)
                self.assertIn('infra:terminate', labels)
                self.assertNotIn('infra:launch', labels)

    def test_ordinary_product_status_is_not_transport(self):
        for status in (1, 7, 124, 127):
            with self.subTest(status=status):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(launchExitCodeBeforeCleanup=status, launchExitCode=status)
                self.assertIn('product:transport-case', labels)
                self.assertNotIn('infra:launch', labels)

    def test_reconstructed_native_signal_exits_preserve_receipt_and_never_replay(self):
        for name, source, expected in (
                ('wrapped', 'import sys\nsys.exit(142)\n', 142),
                ('signal', 'import os, signal\nos.kill(os.getpid(), signal.SIGALRM)\n', -signal.SIGALRM)):
            with self.subTest(name=name):
                self.summary.unlink(missing_ok=True)
                launch, stop = self.root / ('launch-' + name + '.py'), self.root / 'stop.py'
                launch.write_text(source)
                stop.write_text('import sys\nsys.stderr.write(' + repr(sim.not_running_error(BUNDLE)) + ')\nsys.exit(3)\n')
                output, receipt = self.root / (name + '.log'), self.root / (name + '.receipt.json')
                launched = []
                status = capture.run([sys.executable, str(launch)], [sys.executable, str(stop)],
                    output, receipt, 3, dict(bundleID=BUNDLE, scenario='transport-case'),
                    console_launcher_stop=True, launched=launched.append)
                self.assertEqual(status, 1)
                self.assertEqual(len(launched), 1)
                value = json.loads(receipt.read_text())
                self.assertEqual(value['launchExitCodeBeforeCleanup'], expected)
                self.assertEqual(value['launchExitCode'], expected)
                self.assertEqual(value['traceSHA256'], hashlib.sha256(output.read_bytes()).hexdigest())
                self.assertFalse(any(field in value for field in
                    ('appPID', 'launcherAppPID', 'appEntryObserved', 'lastProbeEvent')))
                labels = self.summary.read_text()
                self.assertIn('infra:launch', labels)
                self.assertNotIn('product:', labels)


if __name__ == '__main__':
    unittest.main()
