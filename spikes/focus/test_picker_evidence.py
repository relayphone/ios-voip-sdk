"""Failure evidence is bounded, validated, and never copies raw UI descriptions."""
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

import morning_batch

from runner import Run, extract_picker_evidence, validate_picker_evidence


class PickerEvidenceTests(unittest.TestCase):
    def test_closed_vocabulary_and_stale_evidence(self):
        run_id = str(uuid.uuid4())
        good = {"runID": run_id, "available": True, "truncated": False, "nodes": [
            {"type": "cell", "label": "Everybody", "selected": False, "parent": -1},
            {"type": "text", "label": "Allowed People Only", "selected": True, "parent": 0},
        ]}
        self.assertEqual(validate_picker_evidence(good, run_id), good)
        self.assertIsNone(validate_picker_evidence(good, str(uuid.uuid4())))
        for text in ["Alice Example", "+15555550199", "com.apple.Preferences", "Contacts Alice"]:
            bad = {**good, "nodes": [{"type": "cell", "label": text, "selected": False, "parent": -1}]}
            self.assertIsNone(validate_picker_evidence(bad, run_id))
        self.assertIsNone(validate_picker_evidence({**good, "debugDescription": "private"}, run_id))
        self.assertIsNone(validate_picker_evidence({**good, "nodes": [{"type": [], "label": "", "selected": False, "parent": -1}]}, run_id))
        self.assertIsNone(validate_picker_evidence({**good, "available": False}, run_id))

    def test_export_selects_only_valid_attachment_and_erases_temporary_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "picker.json"
            run_id = str(uuid.uuid4())
            good = {"runID": run_id, "available": True, "truncated": False, "nodes": [
                {"type": "button", "label": "Everyone", "selected": False, "parent": -1}]}
            exported_roots = []
            def fake_export(argv, **kwargs):
                target = Path(argv[argv.index("--output-path") + 1])
                target.mkdir()
                exported_roots.append(target.parent)
                (target / "manifest.json").write_text('[{"deviceName":"private"}]')
                (target / "capture.json").write_text(json.dumps(good))
                (target / "screenshot.png").write_bytes(b"private image")
                return subprocess.CompletedProcess(argv, 0)
            with patch("runner.subprocess.run", side_effect=fake_export):
                extract_picker_evidence(root / "test.xcresult", run_id, destination)
            self.assertEqual(json.loads(destination.read_text()), good)
            self.assertEqual([path.name for path in root.iterdir()], ["picker.json"])
            self.assertTrue(all(not path.exists() for path in exported_roots))

    def test_failed_ui_leaves_evidence_for_supervisor_after_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = root / "F15-example"
            row.mkdir()
            run = Run.__new__(Run)
            run.p = {"callerValue": "+15555550199"}
            run.work, run.folder = root, row
            run.journal = root / "journal.json"
            run.source = root / "test.xctestrun"
            run.source.write_bytes(plistlib.dumps({"test": {"IsUITestBundle": True}}))
            run.device, run.invitation, run.run_id, run.counter = "device", "invitation", str(uuid.uuid4()), 0
            run.unsafe_observer, run.usb_verified, run.journal_fresh = False, False, True
            recoveries = []
            run.recover = lambda **kwargs: recoveries.append(kwargs)
            def failed_command(argv, **kwargs):
                self.assertEqual(argv[0], "xcodebuild")
                self.assertIn("-resultBundlePath", argv)
                run.unsafe_observer = True
                raise RuntimeError("test failed")
            run.command = failed_command
            with self.assertRaises(RuntimeError):
                run.ui(["calls:Everyone"])
            raw = root / ".picker-results" / run.run_id
            self.assertEqual(len(list(raw.glob("*.failed"))), 1)
            self.assertEqual(recoveries, [{"required": False}])
            with patch("runner.extract_picker_evidence") as extract:
                morning_batch.finalize_picker_results(root, run.run_id)
                self.assertEqual(extract.call_count, 1)
                self.assertEqual(extract.call_args.args[1], run.run_id)
            self.assertFalse(raw.exists())

    def test_supervisor_cleans_after_pause_but_not_unverified_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {"FOCUS_WORK": str(root)}
            process = Mock()
            process.poll.return_value = None
            with patch("morning_batch.subprocess.Popen", return_value=process), \
                 patch("morning_batch.stop_process_group") as stop, \
                 patch("morning_batch.finalize_picker_results") as finish:
                with self.assertRaises(morning_batch.BatchPaused):
                    morning_batch.command([str(morning_batch.RUNNER), "F15"], env, root / "log", 5, lambda: True)
                stop.assert_called_once_with(process)
                self.assertEqual(finish.call_count, 1)
            with patch("morning_batch.subprocess.Popen", return_value=process), \
                 patch("morning_batch.stop_process_group", side_effect=morning_batch.ProcessGroupCleanupError("still running")), \
                 patch("morning_batch.finalize_picker_results") as finish:
                with self.assertRaises(morning_batch.ProcessGroupCleanupError):
                    morning_batch.command([str(morning_batch.RUNNER), "F15"], env, root / "log", 5, lambda: True)
                finish.assert_not_called()

    def test_background_failure_marker_has_no_ui_data(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Run.__new__(Run)
            run.folder, run.run_id = Path(directory), str(uuid.uuid4())
            run.picker_unavailable()
            files = list(run.folder.iterdir())
            self.assertEqual(len(files), 1)
            self.assertEqual(json.loads(files[0].read_text()),
                             {"runID": run.run_id, "available": False, "truncated": False, "nodes": []})

    def test_missing_stale_or_unsafe_export_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "picker.json"
            run_id = str(uuid.uuid4())
            for payload in [None,
                            {"runID": str(uuid.uuid4()), "available": True, "truncated": False, "nodes": []},
                            {"runID": run_id, "available": True, "truncated": False, "nodes": [
                                {"type": "cell", "label": "private name", "selected": False, "parent": -1}]}]:
                def fake_export(argv, **kwargs):
                    if payload is None:
                        raise subprocess.CalledProcessError(1, argv)
                    target = Path(argv[argv.index("--output-path") + 1])
                    target.mkdir()
                    (target / "capture.json").write_text(json.dumps(payload))
                    return subprocess.CompletedProcess(argv, 0)
                with patch("runner.subprocess.run", side_effect=fake_export):
                    extract_picker_evidence(root / "missing.xcresult", run_id, destination)
                self.assertEqual(json.loads(destination.read_text()),
                                 {"runID": run_id, "available": False, "truncated": False, "nodes": []})


if __name__ == "__main__":
    unittest.main()
