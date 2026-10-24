import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run


class RunnerTests(unittest.TestCase):
    def test_runtime_selection_matches_sdk_numeric_latest_available_ios(self):
        def runtime(version, available=True, platform='iOS'):
            return dict(identifier=version, version=version, name=platform+' '+version,
                        isAvailable=available, platform=platform)
        rows = [runtime('26.2'), runtime('26.5'), runtime('26.10'),
                runtime('27.0', available=False), runtime('28.0', platform='tvOS')]
        self.assertEqual(run.latest_runtime(rows), '26.10')
        with self.assertRaisesRegex(RuntimeError, 'No available iOS'):
            run.latest_runtime(rows[-2:])

    def test_cold_boot_timeout_is_explicit_and_keeps_diagnostics(self):
        failure = subprocess.TimeoutExpired(['simctl'], 300, output=b'Waiting for SpringBoard')
        with patch.object(run.subprocess, 'run', side_effect=failure) as process:
            with self.assertRaisesRegex(RuntimeError, 'Waiting for SpringBoard'):
                run.run('xcrun', 'simctl', 'bootstatus', 'owned', '-b', timeout=300)
        self.assertEqual(process.call_args.kwargs['timeout'], 300)

    def test_required_runtime_never_falls_back_to_another_os(self):
        rows = [dict(identifier='ios-27', version='27.0', platform='iOS', isAvailable=True),
                dict(identifier='ios-28', version='28.0', platform='iOS', isAvailable=True)]
        self.assertEqual(run.latest_runtime(rows, 'ios-27'), 'ios-27')
        with self.assertRaisesRegex(RuntimeError, 'ios-26'):
            run.latest_runtime(rows, 'ios-26')
        rows[0]['isAvailable'] = False
        with self.assertRaisesRegex(RuntimeError, 'ios-27'):
            run.latest_runtime(rows, 'ios-27')

    def test_failure_keeps_partial_journal_even_when_log_collection_times_out(self):
        with tempfile.TemporaryDirectory() as work:
            container = Path(work) / 'container'
            channel = container / 'Documents/.callkit-simulator'
            (channel / 'run').mkdir(parents=True)
            (channel / 'session.json').write_text(json.dumps(dict(runID='run')))
            raw = b'{"sequence":1}\n{"partial":'
            (channel / 'run/events.jsonl').write_bytes(raw)
            out = Path(work) / 'diagnostics'
            with patch.object(run, 'run', side_effect=[str(container), '', RuntimeError('log timeout')]) as process:
                run.capture_diagnostics(out, 'owned', failed=True)
            self.assertEqual((out / 'runtime-journal/run/events.jsonl').read_bytes(), raw)
            self.assertEqual(json.loads((out / 'runtime-journal/session.json').read_text())['runID'], 'run')
            self.assertIn('log timeout', (out / 'diagnostic-errors.txt').read_text())
            self.assertTrue(all(call.kwargs['timeout'] == 20 for call in process.call_args_list))

    def test_missing_container_does_not_hide_failure_or_skip_other_diagnostics(self):
        with tempfile.TemporaryDirectory() as work:
            out = Path(work)
            with patch.object(run, 'run', side_effect=[RuntimeError('app never installed'), '', 'fixture log']) as process:
                run.capture_diagnostics(out, 'owned', failed=True)
            self.assertEqual(process.call_count, 3)
            self.assertIn('app never installed', (out / 'diagnostic-errors.txt').read_text())
            self.assertEqual((out / 'simulator.log').read_text(), 'fixture log\n')

    def test_known_channel_is_copied_without_contacting_a_stuck_simulator(self):
        with tempfile.TemporaryDirectory() as work:
            channel = Path(work) / 'channel'
            channel.mkdir()
            (channel / 'session.json').write_text('{}')
            out = Path(work) / 'out'
            with patch.object(run, 'run', side_effect=RuntimeError('simctl stuck')) as process:
                run.capture_diagnostics(out, 'owned', channel=channel, failed=True)
            self.assertEqual((out / 'runtime-journal/session.json').read_text(), '{}')
            self.assertEqual(process.call_count, 2, 'only screenshot and logs use simctl')

    def test_full_disk_cannot_replace_the_journey_failure_or_prevent_cleanup(self):
        for failing_method in ('mkdir', 'write_text'):
            with self.subTest(failing_method=failing_method), tempfile.TemporaryDirectory() as work:
                with patch.object(Path, failing_method, side_effect=OSError('No space left on device')):
                    with patch.object(run, 'run', side_effect=RuntimeError('no container')):
                        with contextlib.redirect_stderr(io.StringIO()) as output:
                            with self.assertRaisesRegex(ValueError, 'journey failed'):
                                try:
                                    raise ValueError('journey failed')
                                finally:
                                    run.capture_diagnostics(Path(work), 'owned', failed=True)
                            self.assertIn('No space left on device', output.getvalue())

    def test_delete_is_attempted_after_shutdown_fails(self):
        with patch.object(run, 'run', side_effect=[RuntimeError('shutdown timed out'), '']) as process:
            with self.assertRaisesRegex(RuntimeError, 'shutdown timed out'):
                run.remove_simulators(['owned'])
        self.assertEqual([call.args[2] for call in process.call_args_list], ['shutdown', 'delete'])
        self.assertTrue(all(call.kwargs['timeout'] == 30 for call in process.call_args_list))

    def test_cleanup_keeps_the_original_failure(self):
        with patch.object(run, 'run', side_effect=RuntimeError('cleanup failed')) as process:
            with contextlib.redirect_stderr(io.StringIO()) as output:
                with self.assertRaisesRegex(ValueError, 'original failure'):
                    try:
                        raise ValueError('original failure')
                    finally:
                        run.remove_simulators(['owned'])
        self.assertEqual(process.call_count, 2)
        self.assertIn('cleanup failed', output.getvalue())


if __name__ == '__main__':
    unittest.main()
