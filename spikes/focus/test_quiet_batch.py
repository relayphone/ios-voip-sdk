"""Host-only tests for quiet scheduling and recovery ordering."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import morning_batch as batch
import work_path
from activity_rows import ActivityScenario, run_activity_case
from work_path import default_work

DEVICE = "00008110-0011223344556677"


class QuietBatchTests(unittest.TestCase):
    def test_archive_is_noop_if_restore_removed_the_legacy_journal(self):
        with tempfile.TemporaryDirectory() as root:
            with mock.patch.object(batch, "legacy_dir", return_value=Path(root)):
                self.assertIsNone(batch.archive_legacy())

    def test_quiet_plan_skips_alert_and_microphone_rows_but_keeps_visual_controls(self):
        plan = batch.make_plan(batch.DEFAULT_UNKNOWN, quiet=True)
        skipped = [item for item in plan if item.get("skip")]
        self.assertEqual([item["row"] for item in skipped], ["L15", "L15", "C00"])
        self.assertTrue(all(item["skip"] == "skipped: quiet" for item in skipped))
        self.assertTrue(all("--listen" not in item["args"] and "--quiet" in item["args"] for item in plan))
        self.assertTrue(any(item["row"] == "C00" and not item.get("skip") for item in plan))
        self.assertTrue(all(not item.get("skip") for item in plan if item["row"] in ("L01", "L02")))

    def test_quiet_audio_helpers_never_execute_or_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = mock.Mock()
            fake.p = {"row": "L01", "quiet": True}
            fake.folder = fake.work = Path(directory)
            scenario = ActivityScenario(fake, {})
            self.assertEqual(scenario.begin_audio(90)[0], None)
            fake.command.assert_not_called()
            self.assertEqual(scenario.coverage["acousticEnvelope"]["status"], "skipped: quiet")
            fake.p["row"] = "L15"
            scenario = ActivityScenario(fake, {})
            run_activity_case(scenario)
            fake.ui.assert_not_called()
            fake.command.assert_not_called()
            self.assertEqual(scenario.coverage["alertSoundAndWake"]["status"], "skipped: quiet")

    def test_quiet_dry_run_prints_skips_without_planning_alert_or_microphone(self):
        plan = batch.make_plan(batch.DEFAULT_UNKNOWN, quiet=True)
        def fake(argv, env, timeout=25):
            return {"row": argv[1], "steps": []}
        with mock.patch.object(batch, "run_json", side_effect=fake) as caller, contextlib.redirect_stdout(io.StringIO()) as output:
            batch.dry_run(plan, batch.DEFAULT_UNKNOWN, quiet=True)
        values = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(sum(value.get("status") == "skipped: quiet" for value in values), 3)
        self.assertEqual(values[0]["microphonePreflight"], "skipped: quiet")
        self.assertFalse(any("--listen" in c.args[0] or c.args[0][1] == "L15" for c in caller.call_args_list))

    def test_persistent_default_and_legacy_recovery_detection(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            with mock.patch.object(Path, "home", return_value=root):
                work = default_work()
                self.assertEqual(work, root / "Library" / "Application Support" / "FocusProbe124")
                self.assertFalse(work.is_relative_to(Path(tempfile.gettempdir()) / "some-session"))
            legacy = root / "spike" / "out"
            legacy.mkdir(parents=True)
            (legacy / "restore-state.json").write_text("{}")
            with mock.patch("work_path.__file__", str(root / "spike" / "work_path.py")):
                with self.assertRaisesRegex(ValueError, "FOCUS_WORK"):
                    default_work()

    def test_legacy_archive_requires_clean_state_and_retains_originals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); legacy = root / "spike" / "out"; legacy.mkdir(parents=True)
            checkpoint = {"version": 1, "device": DEVICE, "dirty": False, "inFlight": None,
                          "planHash": "a" * 64, "completed": {"uncertain": {"status": "unqualified-interrupted"}}}
            journal = {"captured": False, "ownsFocus": False, "ownsContact": False,
                       "requiresProbeUninstall": False, "ownsFavorite": False}
            def save():
                (legacy / "morning-checkpoint.json").write_text(json.dumps(checkpoint))
                (legacy / "restore-state.json").write_text(json.dumps(journal))
            save()
            with mock.patch("work_path.__file__", str(root / "spike" / "work_path.py")), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(ValueError, "Prior Focus work"):
                    default_work()
                archive = batch.archive_legacy()
                self.assertEqual(default_work(), root / "Library" / "Application Support" / "FocusProbe124")
                self.assertEqual(json.loads((archive / "morning-checkpoint.json").read_text()), checkpoint)
                self.assertEqual(json.loads((legacy / "morning-checkpoint.json").read_text()), checkpoint)
                self.assertEqual(json.loads((archive / "restore-state.json").read_text()), journal)
                self.assertFalse((root / ".device-locks" / (DEVICE + ".lock")).exists())
                (archive / "restore-state.json").unlink()
                with self.assertRaisesRegex(ValueError, "Prior Focus work"):
                    default_work()
                archive = batch.archive_legacy()
                self.assertEqual(default_work(), root / "Library" / "Application Support" / "FocusProbe124")
                # A resumed or modified legacy run invalidates the receipt.
                checkpoint["dirty"] = True; save()
                with self.assertRaisesRegex(ValueError, "Prior Focus work"):
                    default_work()
                with self.assertRaises(ValueError):
                    batch.archive_legacy()

    def test_legacy_archive_rejects_ambiguous_or_pending_journals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); legacy = root / "spike" / "out"; legacy.mkdir(parents=True)
            checkpoint = {"version": 1, "device": DEVICE, "dirty": False, "inFlight": None,
                          "planHash": "a" * 64, "completed": {}}
            (legacy / "morning-checkpoint.json").write_text(json.dumps(checkpoint))
            journal = legacy / "restore-state.json"
            with mock.patch("work_path.__file__", str(root / "spike" / "work_path.py")), \
                 mock.patch.object(Path, "home", return_value=root):
                for value in ["{", json.dumps({"captured": False, "ownsFocus": False, "ownsContact": False,
                                                "autoLock": "30 Seconds"}),
                              json.dumps({"captured": False, "ownsFocus": False, "ownsContact": False,
                                          "futureSetting": "pending"})]:
                    journal.write_text(value)
                    with self.assertRaises(ValueError):
                        batch.archive_legacy()
                    with self.assertRaisesRegex(ValueError, "Prior Focus work"):
                        default_work()

    def test_legacy_archive_refuses_a_live_device_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); legacy = root / "spike" / "out"; legacy.mkdir(parents=True)
            checkpoint = {"version": 1, "device": DEVICE, "dirty": False, "inFlight": None,
                          "planHash": "a" * 64, "completed": {}}
            (legacy / "morning-checkpoint.json").write_text(json.dumps(checkpoint))
            with mock.patch("work_path.__file__", str(root / "spike" / "work_path.py")), \
                 mock.patch.object(Path, "home", return_value=root):
                owner = batch.DeviceLock(root / ".device-locks", DEVICE)
                owner.acquire()
                try:
                    with self.assertRaisesRegex(RuntimeError, "lock occupied"):
                        batch.archive_legacy()
                    self.assertFalse((legacy / "legacy-archive-receipt.json").exists())
                finally:
                    owner.release()

    def test_journal_only_archive_requires_verified_restore_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); legacy = root / "spike" / "out"; legacy.mkdir(parents=True)
            product = root / "signed.xctestrun"; product.write_bytes(b"signed")
            journal = legacy / "restore-state.json"
            clean = {"captured": False, "ownsFocus": False, "ownsContact": False,
                     "requiresProbeUninstall": False, "ownsFavorite": False}
            journal.write_text(json.dumps(clean))
            env = {"FOCUS_DEVICE": DEVICE, "FOCUS_WORK": str(legacy), "FOCUS_XCTESTRUN": str(product)}
            with mock.patch("work_path.__file__", str(root / "spike" / "work_path.py")), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "command") as command:
                with self.assertRaisesRegex(ValueError, "supervised restore receipt"):
                    batch.archive_legacy()
                batch.supervised_restore()
                self.assertEqual([c.args[0][1] for c in command.call_args_list], ["preflight", "restore-all"])
                receipt_path = legacy / work_path.LEGACY_RESTORE_RECEIPT
                receipt = json.loads(receipt_path.read_text())
                self.assertEqual(receipt["device"], DEVICE)
                self.assertEqual(receipt["journalHash"], hashlib.sha256(journal.read_bytes()).hexdigest())
                archived = batch.archive_legacy()
                self.assertTrue((archived / work_path.LEGACY_RESTORE_RECEIPT).is_file())
                self.assertEqual(default_work(), root / "Library" / "Application Support" / "FocusProbe124")
                # A modified journal or device binding invalidates the archive.
                journal.write_text(json.dumps({**clean, "ownsFocus": True}))
                with self.assertRaisesRegex(ValueError, "Prior Focus work"):
                    default_work()
                with self.assertRaises(ValueError):
                    batch.archive_legacy()
                journal.write_text(json.dumps(clean))
                receipt["device"] = "00008110-1111111111111111"
                receipt_path.write_text(json.dumps(receipt))
                with self.assertRaises(ValueError):
                    batch.archive_legacy()
                with self.assertRaisesRegex(ValueError, "Prior Focus work"):
                    default_work()

    def test_failed_quiet_setup_restores_and_never_runs_a_ringing_row(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); work = root / "work"
            product = root / "signed.xctestrun"; product.write_bytes(b"signed")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN, quiet=True)[:1]
            calls = []
            def command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1:])
                if argv[1] == "preflight" and "--quiet" in argv:
                    self.assertTrue(json.loads((work / "morning-checkpoint.json").read_text())["dirty"])
                    raise RuntimeError("volume setup failed")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": DEVICE, "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", side_effect=AssertionError("quiet must not access mic")), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=command), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, SimpleNamespace(quiet=True, unknown_caller=batch.DEFAULT_UNKNOWN))
            self.assertEqual([call[0] for call in calls], ["preflight", "preflight", "restore-all"])
            self.assertFalse(json.loads((work / "morning-checkpoint.json").read_text())["dirty"])

    def test_quiet_preflight_occurs_after_recovery_before_first_row_and_restores(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); work = root / "work"; work.mkdir()
            product = root / "signed.xctestrun"; product.write_bytes(b"signed")
            original = batch.make_plan(batch.DEFAULT_UNKNOWN)
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN, quiet=True)
            state = {"device": DEVICE, "planHash": batch.checkpoint_id(original), "completed": {},
                     "build": str(product), "buildHash": hashlib.sha256(product.read_bytes()).hexdigest(),
                     "inFlight": plan[0]["id"], "dirty": True}
            batch.atomic_json(work / "morning-checkpoint.json", state)
            # End after one resumed sample; this exercises actual checkpoint migration.
            calls = []
            def command(argv, env, log, timeout, should_pause=None):
                calls.append(list(argv[1:]))
                if argv[1] == "preflight" and "--quiet" in argv:
                    checkpoint = json.loads((work / "morning-checkpoint.json").read_text())
                    self.assertTrue(checkpoint["dirty"])
                    self.assertNotIn("FOCUS_REQUIRE_DEVICE_JOURNAL", env)
                if argv[1] == "C01":
                    result = work / "fresh-result.json"
                    result.write_text(json.dumps({"row": "C01", "status": "recorded", "restored": "focus-off"}))
                    log.write_text(json.dumps({"status": "recorded", "result": str(result)}) + "\n")
                    (work / "PAUSE").touch()
            args = SimpleNamespace(quiet=True, unknown_caller=batch.DEFAULT_UNKNOWN)
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": DEVICE, "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", side_effect=AssertionError("quiet must not access mic")), \
                 mock.patch.object(batch, "command", side_effect=command), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, args), 75)
            self.assertEqual([call[0] for call in calls], ["preflight", "restore-all", "preflight", "C01", "restore-all"])
            self.assertIn("--quiet", calls[2])
            checkpoint = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertEqual(checkpoint["completed"][plan[0]["id"]]["status"], "unqualified-interrupted")
            self.assertEqual(checkpoint["microphoneAuthorization"], "skipped: quiet")
            self.assertEqual(checkpoint["planHash"], batch.checkpoint_id(plan))
            self.assertFalse(checkpoint["dirty"])

    def test_returning_to_normal_requeues_only_quiet_skips(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); work = root / "work"; work.mkdir()
            product = root / "signed.xctestrun"; product.write_bytes(b"signed")
            quiet_plan = batch.make_plan(batch.DEFAULT_UNKNOWN, quiet=True)
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)
            skips = [item["id"] for item in quiet_plan if item.get("skip")]
            completed = {name: {"status": "skipped: quiet", "result": None} for name in skips}
            completed[plan[0]["id"]] = {"status": "recorded", "result": "prior"}
            completed[plan[1]["id"]] = {"status": "unqualified-interrupted", "result": None}
            state = {"device": DEVICE, "planHash": batch.checkpoint_id(quiet_plan), "completed": completed,
                     "build": str(product), "buildHash": hashlib.sha256(product.read_bytes()).hexdigest(),
                     "inFlight": None, "dirty": False}
            batch.atomic_json(work / "morning-checkpoint.json", state)
            def authorize(workdir, _pause):
                (workdir / "PAUSE").touch()
                return "authorized"
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": DEVICE, "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", side_effect=authorize), \
                 mock.patch.object(batch, "command"), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, SimpleNamespace(quiet=False, unknown_caller=batch.DEFAULT_UNKNOWN)), 75)
            result = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertTrue(all(name not in result["completed"] for name in skips))
            self.assertEqual(result["completed"][plan[0]["id"]]["status"], "recorded")
            self.assertEqual(result["completed"][plan[1]["id"]]["status"], "unqualified-interrupted")


if __name__ == "__main__":
    unittest.main()
