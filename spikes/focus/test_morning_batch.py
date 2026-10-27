import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import morning_batch as batch


class MorningPlanTests(unittest.TestCase):
    def test_matrix_order_counts_and_unknown_controls(self):
        plan = batch.make_plan(batch.DEFAULT_UNKNOWN)
        self.assertEqual([x["row"] for x in plan[:3]], ["C06", "C01", "C05"])
        self.assertEqual((plan[-1]["row"], plan[-1]["args"]), ("C00", ["--listen", "--keep-setup"]))
        groups = {}
        for item in plan:
            name = item["id"].rsplit("-", 1)[0]
            groups.setdefault(name, []).append(item)
        for name in ["ck-matrix-f13", "ck-dnd-unknown", "callkit-repeat-off", "callkit-repeat-on",
                     "lck-repeat-off", "lck-repeat-on", "callkit-contacts-only-unknown",
                     "lck-everyone-contact", "lck-favorite-yes", "callkit-handle-generic",
                     "callkit-answer", "lck-answer", "callkit-dnd-answer"]:
            self.assertEqual(len(groups[name]), 3, name)
        self.assertEqual([x["row"] for x in plan if x["id"].startswith("activity-")],
                         [f"L{i:02}" for i in range(1, 17)])
        for index in range(1, 17):
            matrix = groups[f"ck-matrix-f{index:02}"]
            self.assertEqual(len(matrix), 3)
            self.assertTrue(all(x["row"] == f"F{index:02}" and "callkit" in x["args"] for x in matrix))
        for name in ["ck-dnd-unknown", "callkit-dnd-answer"]:
            self.assertTrue(all("--unknown-caller" in x["args"] and "--focus-mode" in x["args"] for x in groups[name]))
        self.assertEqual(len({x["id"] for x in plan}), len(plan))

    def test_dry_run_calls_real_plan_interface_without_secrets_or_unknown_number(self):
        plan = batch.make_plan("+15555550301")[:4]
        calls = []
        def fake(argv, env, timeout=25):
            calls.append((argv, env))
            self.assertNotIn("PHONE_APNS_KEY", env)
            self.assertNotIn("FOCUS_DEVICE", env)
            return {"row": argv[1], "callerValue": "+15555550301", "steps": []}
        with mock.patch.dict(os.environ, {"PHONE_APNS_KEY": "secret", "FOCUS_DEVICE": "device"}), \
             mock.patch.object(batch, "run_json", side_effect=fake), contextlib.redirect_stdout(io.StringIO()) as out:
            batch.dry_run(plan, "+15555550301")
        self.assertEqual(len(calls), len(plan) + 2)
        self.assertTrue(all("--dry-run" in args for args, _ in calls))
        self.assertNotIn("+15555550301", out.getvalue())
        self.assertNotIn("secret", out.getvalue())

    def test_lock_never_steals_and_owner_controls_release(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root) / "locks"
            owner = batch.DeviceLock(base, "00008110-0011223344556677")
            owner.acquire()
            with self.assertRaises(RuntimeError):
                batch.DeviceLock(base, "00008110-0011223344556677").acquire()
            owner.release()
            self.assertFalse(owner.path.exists())

    def test_device_gate_requires_unique_iphone_13_with_canonical_id(self):
        udid = "00008110-0011223344556677"
        core = "01234567-1234-5678-ABCD-1234567890AB"
        good = {"identifier": core, "hardwareProperties": {"udid": udid, "marketingName": "iPhone 13", "productType": "iPhone14,5"}}
        inventory = {"result": {"devices": [good]}}
        self.assertEqual(batch.iphone13_identity(inventory, udid), udid)
        self.assertEqual(batch.iphone13_identity(inventory, core.lower()), udid)
        for hardware in [{"udid": udid, "marketingName": "iPhone 15 Pro Max"},
                         {"udid": udid, "marketingName": "iPhone 15 Pro Max", "productType": "iPhone14,5"},
                         {"udid": udid}]:
            with self.assertRaises(ValueError):
                batch.iphone13_identity({"result": {"devices": [{"identifier": core, "hardwareProperties": hardware}]}}, udid)
        with self.assertRaises(ValueError):
            batch.iphone13_identity({"result": {"devices": [good, good]}}, udid)
        with self.assertRaises(ValueError):
            batch.iphone13_identity(inventory, "Hamza's iPhone")

    def test_microphone_authorization_is_bounded_and_failure_is_visual_only(self):
        with tempfile.TemporaryDirectory() as root:
            work = Path(root)
            calls = []
            def fake(argv, env, log, timeout, should_pause=None):
                calls.append((argv, timeout))
                if argv[-1] == "--authorize":
                    log.write_text("Microphone authorized\n")
            with mock.patch.object(batch, "command", side_effect=fake):
                self.assertEqual(batch.authorize_microphone(work, lambda: False), "authorized")
            self.assertEqual(calls[-1][1], 30)
            with mock.patch.object(batch, "command", side_effect=__import__("subprocess").TimeoutExpired("listen", 30)):
                self.assertEqual(batch.authorize_microphone(work, lambda: False), "pending-or-denied")

    def test_summary_never_promotes_unqualified_answer_or_mic(self):
        item = {"row": "F09", "args": ["--server-answer"]}
        summary = batch.result_summary(item, {"answeredElsewhere": {"status": "unqualified", "caller": "private"},
                                               "visualNegativeQualified": False})
        self.assertEqual(summary, {"answerEvidence": "unqualified", "visualNegativeQualified": False})
        audio = batch.result_summary({"row": "C00", "args": ["--listen"]},
                                     {"audio": {"reason": "mic permission pending", "token": "private"}})
        self.assertEqual(audio["microphone"], "mic permission pending; visual evidence only")

    def test_pause_restores_and_resume_does_not_repeat_completed_rows(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            fake_build = root / "build.xctestrun"
            fake_build.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:2]
            commands = []
            paused = [False]
            def fake_command(argv, env, log, timeout, should_pause=None):
                commands.append(argv[1])
                if argv[1] not in ["preflight", "restore-all"]:
                    self.assertEqual(json.loads((work / "morning-checkpoint.json").read_text())["inFlight"],
                                     next(p["id"] for p in plan if p["row"] == argv[1]))
                    result_path = work / (argv[1] + ".json")
                    result_path.write_text(json.dumps({"row": argv[1], "status": "recorded", "restored": "focus-off"}))
                    log.write_text(json.dumps({"status": "recorded", "result": str(result_path)}) + "\n")
                    if not paused[0]:
                        (work / "PAUSE").touch()
                        paused[0] = True
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=fake_build), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 75)
                self.assertFalse((root / ".device-locks" / "00008110-0011223344556677.lock").exists())
                self.assertEqual(commands, ["preflight", "C06", "restore-all"])
                (work / "PAUSE").unlink()
                self.assertEqual(batch.run_batch(plan, None), 0)
                self.assertEqual(commands, ["preflight", "C06", "restore-all", "preflight", "C01", "restore-all"])
            state = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertIsNone(state["inFlight"])
            self.assertEqual(set(state["completed"]), {p["id"] for p in plan})

    def test_failed_row_is_not_replayed_and_restore_failure_keeps_lock(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            fake_build = root / "build.xctestrun"
            fake_build.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:1]
            def fake_command(argv, env, log, timeout, should_pause=None):
                if argv[1] != "preflight":
                    raise RuntimeError("simulated failure")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=fake_build), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, None)
            self.assertTrue((root / ".device-locks" / "00008110-0011223344556677.lock").is_dir())
            self.assertEqual(json.loads((work / "morning-checkpoint.json").read_text())["inFlight"], plan[0]["id"])

    def test_crash_recovery_restores_then_marks_ambiguous_attempt_unqualified(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            work.mkdir()
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:2]
            state = {"device": "00008110-0011223344556677", "planHash": batch.checkpoint_id(plan), "completed": {},
                     "build": str(product), "buildHash": hashlib.sha256(product.read_bytes()).hexdigest(),
                     "inFlight": plan[0]["id"], "dirty": True}
            batch.atomic_json(work / "morning-checkpoint.json", state)
            calls = []
            def fake_command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
                if argv[1] == "C01":
                    result_path = work / (argv[1] + ".json")
                    result_path.write_text(json.dumps({"row": argv[1], "status": "recorded", "restored": "focus-off"}))
                    log.write_text(json.dumps({"status": "recorded", "result": str(result_path)}) + "\n")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 0)
            self.assertEqual(calls, ["preflight", "restore-all", "C01", "restore-all"])
            result = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertEqual(result["completed"][plan[0]["id"]]["status"], "unqualified-interrupted")
            self.assertFalse(result["dirty"])

    def test_unqualified_restored_row_does_not_abort_remaining_measurements(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:2]
            calls = []
            def fake_command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
                if argv[1] == "C06":
                    result_path = work / "row-result.json"
                    result_path.write_text(json.dumps({"row": "C06", "status": "unqualified", "restored": "focus-off"}))
                    log.write_text(json.dumps({"row": "C06", "status": "unqualified", "result": str(result_path)}) + "\n")
                    raise RuntimeError("unqualified")
                if argv[1] == "C01":
                    result_path = work / (argv[1] + ".json")
                    result_path.write_text(json.dumps({"row": argv[1], "status": "recorded", "restored": "focus-off"}))
                    log.write_text(json.dumps({"status": "recorded", "result": str(result_path)}) + "\n")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 0)
            self.assertEqual(calls, ["preflight", "C06", "C01", "restore-all"])
            result = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertEqual(result["completed"][plan[0]["id"]]["status"], "unqualified")
            self.assertFalse(result["dirty"])

    def test_dirty_checkpoint_without_preflight_never_releases_lock(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            work.mkdir()
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:1]
            batch.atomic_json(work / "morning-checkpoint.json", {
                "device": "00008110-0011223344556677", "planHash": batch.checkpoint_id(plan), "completed": {},
                "build": str(product), "buildHash": hashlib.sha256(product.read_bytes()).hexdigest(),
                "inFlight": plan[0]["id"], "dirty": True})
            def fail_preflight(argv, env, log, timeout, should_pause=None):
                self.assertEqual(argv[1], "preflight")
                raise RuntimeError("Share Across Devices unknown")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "command", side_effect=fail_preflight), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, None)
            self.assertTrue((root / ".device-locks" / "00008110-0011223344556677.lock").is_dir())

    def test_phone_priority_during_build_stops_before_preflight_and_unlocks(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            calls = []
            def pause_build(workdir, device, env, should_pause):
                (workdir / "PAUSE").touch()
                self.assertTrue(should_pause())
                raise batch.BatchPaused("priority")
            def no_device_actions(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", side_effect=pause_build), \
                 mock.patch.object(batch, "command", side_effect=no_device_actions):
                self.assertEqual(batch.run_batch(batch.make_plan(batch.DEFAULT_UNKNOWN)[:1], None), 75)
            self.assertEqual(calls, [])
            self.assertFalse((root / ".device-locks" / "00008110-0011223344556677.lock").exists())


if __name__ == "__main__":
    unittest.main()
