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

    def classify(self, trace=b'', **changes):
        value = dict(completed=False, success=False, scenario='transport-case', bundleID=BUNDLE,
                     launchExitCodeBeforeCleanup=0, launchExitCode=0,
                     error='launcher exited before terminal done event',
                     cleanupExitCode=3, cleanupStdout='', cleanupStderr=sim.not_running_error(BUNDLE))
        value.update(changes)
        capture.report_capture_failure(value, trace, 3, capture_failure=True)
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

    def test_known_launcher_signal_after_valid_entry_is_transport(self):
        trace = ((BUNDLE + ': 7001\n').encode() +
                 b'PROBE {"event":"app.entry","t_ms":0}\nPROBE {"event":"launch","pid":7001,"t_ms":1}\n')
        for status in (-signal.SIGALRM, 128 + signal.SIGALRM):
            with self.subTest(status=status):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=status,
                    launchExitCode=status, appEntryObserved=True, appPID=7001,
                    launcherAppPID=7001, lastProbeEvent='launch', cleanupExitCode=7)
                self.assertIn('infra:launch', labels)
                self.assertIn('infra:terminate', labels)
                self.assertNotIn('product:', labels)

    def test_entry_signal_does_not_replace_malformed_identity_or_product_failure(self):
        valid = ((BUNDLE + ': 7001\n').encode() +
                 b'PROBE {"event":"app.entry","t_ms":0}\nPROBE {"event":"launch","pid":7001,"t_ms":1}\n')
        cases = ((valid + b'PROBE malformed-product-json\n', {}),
                 (valid + b'PROBE []\n', {}),
                 (valid + (BUNDLE + ': 7002\n').encode(), {}),
                 (valid + (BUNDLE + ': 7002\n').encode(),
                  {'identityError': 'require one launcher app PID acknowledgement; got 2'}),
                 (valid, {'error': 'synthetic product assertion'}),
                 (valid, {'error': 'deadline before terminal done event'}))
        for trace, changes in cases:
            with self.subTest(trace=trace, changes=changes):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=142,
                    launchExitCode=142, appEntryObserved=True, appPID=7001,
                    launcherAppPID=7001, lastProbeEvent='launch', **changes)
                self.assertIn('product:transport-case', labels)
                self.assertNotIn('infra:launch', labels)

    def test_entered_signal_preserves_invalid_records_and_overwritten_launch_pid(self):
        prefix = (BUNDLE + ': 7001\n').encode() + b'PROBE {"event":"app.entry","t_ms":0}\n'
        launch = b'PROBE {"event":"launch","pid":7001,"t_ms":1}\n'
        cases = (prefix + launch + b'PROBE {}\n',
                 prefix + launch + b'PROBE {"event":7,"t_ms":2}\n',
                 prefix + launch + b'PROBE {"event":"snapshot"}\n',
                 prefix + launch + b'PROBE {"event":"snapshot","t_ms":true}\n',
                 prefix + launch + b'PROBE {"event":"snapshot","t_ms":-1}\n',
                 prefix + b'PROBE {"event":"launch","pid":7002,"t_ms":0}\n' + launch)
        for trace in cases:
            with self.subTest(trace=trace):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=142,
                    launchExitCode=142, appEntryObserved=True, appPID=7001,
                    launcherAppPID=7001, lastProbeEvent='launch')
                self.assertIn('product:transport-case', labels)
                self.assertNotIn('infra:launch', labels)

    def test_provided_raw_identity_must_match_the_bound_capture(self):
        identity = dict(pid=7001, runID='host-run', simulatorID='owned-simulator', bundleID=BUNDLE)
        for key, wrong in ((None, None), ('pid', 7002), ('runID', 'foreign-run'),
                           ('simulatorID', 'foreign-simulator'), ('bundleID', 'foreign-bundle')):
            with self.subTest(key=key):
                self.summary.unlink(missing_ok=True)
                row = dict(event='app.entry', t_ms=0, **identity)
                if key is not None:
                    row[key] = wrong
                trace = ((BUNDLE + ': 7001\nPROBE ' + json.dumps(row) + '\n').encode() +
                         b'PROBE {"event":"launch","pid":7001,"t_ms":1}\n')
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=142,
                    launchExitCode=142, appEntryObserved=True, appPID=7001,
                    launcherAppPID=7001, lastProbeEvent='launch',
                    runID=identity['runID'], simulatorID=identity['simulatorID'])
                self.assertIn('infra:launch' if key is None else 'product:transport-case', labels)
                self.assertNotIn('product:' if key is None else 'infra:launch', labels)

    def test_probe_payload_encoding_must_match_utf8_text_conformance(self):
        valid = ((BUNDLE + ': 7001\n').encode() +
                 b'PROBE {"event":"app.entry","t_ms":0}\nPROBE {"event":"launch","pid":7001,"t_ms":1}\n')
        for encoding in ('utf-8-sig', 'utf-16', 'utf-16-le', 'utf-32', 'utf-32-le'):
            with self.subTest(encoding=encoding):
                self.summary.unlink(missing_ok=True)
                trace = valid + b'PROBE ' + '{"event":"snapshot","t_ms":2}'.encode(encoding) + b'\n'
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=142,
                    launchExitCode=142, appEntryObserved=True, appPID=7001,
                    launcherAppPID=7001, lastProbeEvent='launch')
                self.assertIn('product:transport-case', labels)
                self.assertNotIn('infra:launch', labels)

    def test_cleanup_signal_is_not_inferred_to_be_the_primary_transport_failure(self):
        labels = self.classify(launchExitCodeBeforeCleanup=None, launchExitCode=-signal.SIGTERM,
                               error='synthetic product assertion', cleanupExitCode=7)
        self.assertIn('product:transport-case', labels)
        self.assertIn('infra:terminate', labels)
        self.assertNotIn('infra:launch', labels)

    def test_cleanup_signal_after_entered_eof_is_not_host_transport_evidence(self):
        trace = ((BUNDLE + ': 7001\n').encode() +
                 b'PROBE {"event":"app.entry","t_ms":0}\nPROBE {"event":"launch","pid":7001,"t_ms":1}\n')
        for status in (-signal.SIGTERM, 128 + signal.SIGTERM,
                       -signal.SIGKILL, 128 + signal.SIGKILL):
            with self.subTest(status=status):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=None,
                    launchExitCode=status, appEntryObserved=True, appPID=7001,
                    launcherAppPID=7001, lastProbeEvent='launch', cleanupExitCode=7)
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

    def test_raw_probe_or_pid_evidence_preserves_product_failure_without_receipt_fields(self):
        for trace in (b'PROBE malformed-product-json\n', (BUNDLE + ': 7001\n').encode(),
                      (BUNDLE + ': 7001\n' + BUNDLE + ': 7002\n').encode()):
            with self.subTest(trace=trace):
                self.summary.unlink(missing_ok=True)
                labels = self.classify(trace=trace, launchExitCodeBeforeCleanup=142,
                                       launchExitCode=142, cleanupExitCode=7)
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

    def test_reconstructed_launcher_signal_after_entry_keeps_receipt_and_does_not_replay(self):
        for name, ending, expected in (
                ('wrapped', 'sys.exit(142)', 142),
                ('signal', 'os.kill(os.getpid(), signal.SIGALRM)', -signal.SIGALRM)):
            with self.subTest(name=name):
                self.summary.unlink(missing_ok=True)
                launch, stop = self.root / ('entered-' + name + '.py'), self.root / 'stop.py'
                launch.write_text('import json, os, signal, sys\npid = os.getpid()\n' +
                    'print(' + repr(BUNDLE + ': ') + ' + str(pid), flush=True)\n' +
                    'for row in ({"event":"app.entry","t_ms":0}, {"event":"launch","pid":pid,"t_ms":1}):\n' +
                    ' print("PROBE " + json.dumps(row), flush=True)\n' + ending + '\n')
                stop.write_text('import sys\nsys.stderr.write(' + repr(sim.not_running_error(BUNDLE)) + ')\nsys.exit(3)\n')
                output, receipt = self.root / (name + '.log'), self.root / (name + '.json')
                launched = []
                status = capture.run([sys.executable, str(launch)], [sys.executable, str(stop)],
                    output, receipt, 3, dict(bundleID=BUNDLE, scenario='transport-case'),
                    console_launcher_stop=True, launched=launched.append)
                self.assertEqual(status, 1)
                self.assertEqual(len(launched), 1)
                value = json.loads(receipt.read_text())
                self.assertEqual(value['error'], 'launcher exited before terminal done event')
                self.assertEqual(value['launchExitCodeBeforeCleanup'], expected)
                self.assertEqual(value['launchExitCode'], expected)
                self.assertTrue(value['appEntryObserved'])
                self.assertEqual(value['appPID'], value['launcherAppPID'])
                self.assertEqual(value['traceSHA256'], hashlib.sha256(output.read_bytes()).hexdigest())
                labels = self.summary.read_text()
                self.assertIn('infra:launch', labels)
                self.assertNotIn('product:', labels)


if __name__ == '__main__':
    unittest.main()
