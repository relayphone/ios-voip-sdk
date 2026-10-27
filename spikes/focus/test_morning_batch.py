import contextlib
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
        for name in ["ck-person", "ck-dnd-unknown", "callkit-repeat-off", "callkit-repeat-on",
                     "lck-repeat-off", "lck-repeat-on", "callkit-contacts-only-unknown",
                     "lck-everyone-contact", "lck-favorite-yes", "callkit-handle-generic",
                     "callkit-answer", "lck-answer", "callkit-dnd-answer"]:
            self.assertEqual(len(groups[name]), 3, name)
        self.assertEqual([x["row"] for x in plan if x["id"].startswith("activity-")],
                         [f"L{i:02}" for i in range(1, 17)])
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
            owner = batch.DeviceLock(base, "device-13")
            owner.acquire()
            with self.assertRaises(RuntimeError):
                batch.DeviceLock(base, "device-13").acquire()
            owner.release()
            self.assertFalse(owner.path.exists())

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
                    log.write_text(json.dumps({"status": "recorded", "result": "private"}) + "\n")
                    if not paused[0]:
                        (work / "PAUSE").touch()
                        paused[0] = True
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "device-13", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "signed_build", return_value=fake_build), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 75)
                self.assertFalse((root / ".device-locks" / "device-13.lock").exists())
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
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "device-13", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "signed_build", return_value=fake_build), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, None)
            self.assertTrue((root / ".device-locks" / "device-13.lock").is_dir())
            self.assertEqual(json.loads((work / "morning-checkpoint.json").read_text())["inFlight"], plan[0]["id"])


if __name__ == "__main__":
    unittest.main()
