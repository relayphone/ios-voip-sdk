import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import morning_batch as batch


class MorningPlanTests(unittest.TestCase):
    def test_default_unknown_uses_distinct_synthetic_number(self):
        self.assertNotEqual(batch.DEFAULT_UNKNOWN[-7:], "+15555550199"[-7:])
        self.assertTrue(batch.DEFAULT_UNKNOWN.startswith("+447700900"))

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
        activity = [x for x in plan if x["id"].startswith("activity-")]
        self.assertEqual([x["row"] for x in activity],
                         [f"L{i:02}" for i in range(1, 7)] +
                         [f"L{i:02}" for i in range(7, 16) for _ in range(2)] + ["L16"])
        for index in range(1, 16):
            variants = [x for x in activity if x["row"] == f"L{index:02}"]
            expected = ["on" if index % 2 == 0 else "off"] if index <= 6 else ["off", "on"]
            self.assertEqual([x["args"][x["args"].index("--activity-focus") + 1] for x in variants], expected)
        self.assertNotIn("--activity-focus", activity[-1]["args"])
        for index in range(1, 17):
            matrix = groups[f"ck-matrix-f{index:02}"]
            self.assertEqual(len(matrix), 3)
            self.assertTrue(all(x["row"] == f"F{index:02}" and "callkit" in x["args"] for x in matrix))
        for name in ["ck-dnd-unknown", "callkit-dnd-answer"]:
            self.assertTrue(all("--unknown-caller" in x["args"] and "--focus-mode" in x["args"] for x in groups[name]))
            positions = [i for i, item in enumerate(plan) if item["id"].startswith(name + "-") and
                         "--focus-mode" in item["args"]]
            for control in [plan[positions[0] - 1], plan[positions[-1] + 1]]:
                self.assertEqual(control["row"], "C00")
                self.assertIn("--unknown-caller", control["args"])
                self.assertIn("callkit", control["args"])
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

    def test_timed_out_row_terminates_its_observer_process_group(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            ready, escaped = root / "observer-ready", root / "observer-escaped"
            child = ("import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"pathlib.Path({str(ready)!r}).touch(); time.sleep(3); "
                     f"pathlib.Path({str(escaped)!r}).touch()")
            parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(30)"
            with self.assertRaises(subprocess.TimeoutExpired):
                batch.command([sys.executable, "-c", parent], os.environ.copy(), root / "command.log", 1)
            self.assertTrue(ready.exists())
            time.sleep(3)
            self.assertFalse(escaped.exists())

    def test_successful_parent_does_not_leave_observer_process_group_alive(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            ready, escaped = root / "observer-ready", root / "observer-escaped"
            child = ("import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"pathlib.Path({str(ready)!r}).touch(); time.sleep(3); "
                     f"pathlib.Path({str(escaped)!r}).touch()")
            parent = (f"import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,'-c',{child!r}]); "
                      f"p=pathlib.Path({str(ready)!r}); "
                      "exec('while not p.exists():\\n time.sleep(0.01)')")
            batch.command([sys.executable, "-c", parent], os.environ.copy(), root / "command.log", 10)
            self.assertTrue(ready.exists())
            time.sleep(3)
            self.assertFalse(escaped.exists())

    def test_standalone_restore_owns_lock_and_preserves_dirty_checkpoint(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            work.mkdir()
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            device = "00008110-0011223344556677"
            batch.atomic_json(work / "morning-checkpoint.json", {"device": device, "completed": {},
                              "buildHash": hashlib.sha256(product.read_bytes()).hexdigest(),
                              "inFlight": "activity-01-off-01", "inFlightAttempt": "old-attempt", "dirty": True})
            calls = []
            def fake_command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
                owner = json.loads((root / ".focus-locks" / (device + ".lock") / "owner.json").read_text())
                self.assertEqual(env["FOCUS_BATCH_OWNER_PID"], str(os.getpid()))
                self.assertEqual(env["FOCUS_BATCH_LOCK_NONCE"], owner["nonce"])
                self.assertEqual(env["FOCUS_REQUIRE_DEVICE_JOURNAL"], "1")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": device, "FOCUS_WORK": str(work), "FOCUS_XCTESTRUN": str(product)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda value, workdir: value), \
                 mock.patch.object(batch, "command", side_effect=fake_command):
                batch.supervised_restore()
            self.assertEqual(calls, ["preflight", "restore-all"])
            self.assertFalse((root / ".focus-locks" / (device + ".lock")).exists())
            state = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertFalse(state["dirty"])
            self.assertIsNone(state["inFlight"])
            self.assertNotIn("inFlightAttempt", state)
            self.assertEqual(state["completed"]["activity-01-off-01"]["status"], "unqualified-interrupted")

    def test_standalone_restore_failure_retains_owned_lock(self):
        for fail_at in ["preflight", "restore-all"]:
            with self.subTest(fail_at=fail_at), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                work = root / "work"
                product = root / "device.xctestrun"
                product.write_bytes(b"signed-product")
                device = "00008110-0011223344556677"
                def fake_command(argv, env, log, timeout, should_pause=None):
                    if argv[1] == fail_at:
                        raise batch.ProcessGroupCleanupError("fixture group cleanup failed")
                with mock.patch.dict(os.environ, {"FOCUS_DEVICE": device, "FOCUS_WORK": str(work), "FOCUS_XCTESTRUN": str(product)}), \
                     mock.patch.object(Path, "home", return_value=root), \
                     mock.patch.object(batch, "identify_iphone13", side_effect=lambda value, workdir: value), \
                     mock.patch.object(batch, "command", side_effect=fake_command), \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(batch.ProcessGroupCleanupError):
                        batch.supervised_restore()
                self.assertTrue((root / ".focus-locks" / (device + ".lock")).is_dir())

    def test_standalone_restore_never_steals_an_existing_lock(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            device = "00008110-0011223344556677"
            occupied = batch.DeviceLock(root / ".focus-locks", device)
            occupied.acquire()
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": device, "FOCUS_WORK": str(work), "FOCUS_XCTESTRUN": str(product)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda value, workdir: value), \
                 mock.patch.object(batch, "command") as command:
                with self.assertRaises(RuntimeError):
                    batch.supervised_restore()
            command.assert_not_called()
            self.assertTrue(occupied.path.is_dir())
            occupied.release()

    def test_device_gate_requires_unique_iphone_13_with_canonical_id(self):
        udid = "00008110-0011223344556677"
        core = "01234567-1234-5678-ABCD-1234567890AB"
        good = {"identifier": core, "hardwareProperties": {"udid": udid, "marketingName": "iPhone 13", "productType": "iPhone14,5"}}
        inventory = {"result": {"devices": [good]}}
        self.assertEqual(batch.iphone13_identity(inventory, udid), udid)
        with self.assertRaises(ValueError):
            batch.iphone13_identity(inventory, core)
        with self.assertRaises(ValueError):
            batch.iphone13_identity(inventory, "00008110-00a1223344556677")
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
        self.assertNotIn("activityCoverage", batch.result_summary({"row": "LCK-C02b", "args": []}, {}))
        self.assertEqual(batch.result_summary({"row": "L12", "args": []}, {"coverage": {"simulation": "observed"}})["activityCoverage"], "structured")

    def test_activity_unqualified_and_hardware_na_keep_honest_status(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            full_plan = batch.make_plan(batch.DEFAULT_UNKNOWN)
            plan = [next(item for item in full_plan if item["id"] == name)
                    for name in ["activity-07-off-01", "activity-16-01"]]
            def fake_command(argv, env, log, timeout, should_pause=None):
                if argv[1] not in ["L07", "L16"]:
                    return
                status = "unqualified" if argv[1] == "L07" else "not-applicable-hardware"
                result = {"row": argv[1], "status": status, "restored": True,
                          "coverage": {"outcome": "unqualified"}}
                result_path = work / (argv[1] + ".json")
                result_path.write_text(json.dumps(result))
                log.write_text(json.dumps({"status": status, "result": str(result_path)}) + "\n")
                if argv[1] == "L07":
                    raise RuntimeError("unqualified")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 0)
            state = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertEqual(state["completed"][plan[0]["id"]]["status"], "unqualified")
            self.assertEqual(state["completed"][plan[0]["id"]]["activityCoverage"], "structured")
            self.assertEqual(state["completed"][plan[1]["id"]]["status"], "not-applicable-hardware")
            self.assertFalse(state["dirty"])

    def test_activity_skip_is_not_accepted_as_completed_coverage(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = [next(item for item in batch.make_plan(batch.DEFAULT_UNKNOWN) if item["id"] == "activity-10-off-01")]
            def fake_command(argv, env, log, timeout, should_pause=None):
                if argv[1] == "L10":
                    log.write_text(json.dumps({"row": "L10", "status": "skipped-dependency-or-unsupported"}) + "\n")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, None)

    def test_final_c00_postclassifies_private_activity_envelope(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            full = batch.make_plan(batch.DEFAULT_UNKNOWN)
            plan = [next(item for item in full if item["id"] == name)
                    for name in ["activity-01-off-01", "microphone-positive-01"]]
            binding = {"device": "00008110-0011223344556677", "build": hashlib.sha256(product.read_bytes()).hexdigest(),
                       "provider": "lck", "callerFormat": "e164"}
            samples = [{"wallTime": 1000 + index / 10, "rms": 0.0001 if index < 30 else 0.01}
                       for index in range(200)]
            calibration = {"calibrationValid": True, "threshold": 0.0025, "quietP95": 0.0001,
                           "signalP95": 0.01, "createdAt": 1030.0, "binding": binding}

            def fake_command(argv, env, log, timeout, should_pause=None):
                if argv[1] not in ["L01", "C00"]:
                    return
                row_dir = work / ("row-" + argv[1])
                row_dir.mkdir()
                row_path = row_dir / "result.json"
                if argv[1] == "L01":
                    audio_path = row_dir / "activity-audio.json"
                    audio_path.write_text(json.dumps({"startedAt": 1000.0, "binding": binding, "samples": samples}))
                    row = {"row": "L01", "status": "unqualified", "restored": "focus-off",
                           "activityAudio": str(audio_path), "activityAudioWindow": {"start": 1005.0, "end": 1010.0}}
                else:
                    (work / "audio-calibration.json").write_text(json.dumps(calibration))
                    row = {"row": "C00", "status": "recorded", "restored": "focus-off", "audio": calibration}
                row_path.write_text(json.dumps(row))
                log.write_text(json.dumps({"row": argv[1], "status": row["status"], "result": str(row_path)}) + "\n")

            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": binding["device"], "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 0)
            state = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertEqual(state["completed"][plan[0]["id"]]["status"], "unqualified")
            self.assertEqual(state["completed"][plan[0]["id"]]["activityAcoustic"]["status"], "qualified-energy-proxy")
            row = json.loads((work / "row-L01" / "result.json").read_text())
            self.assertTrue(row["activityAcoustic"]["energyAboveThreshold"])
            self.assertIn("cannot prove or rule out", row["activityAcoustic"]["limitation"])

    def test_stale_or_unmatched_control_does_not_classify_prior_audio(self):
        with tempfile.TemporaryDirectory() as root:
            work = Path(root)
            row_dir = work / "activity"
            row_dir.mkdir()
            row_path = row_dir / "result.json"
            audio_path = row_dir / "activity-audio.json"
            binding = {"device": "00008110-0011223344556677", "build": "a" * 64,
                       "provider": "lck", "callerFormat": "e164"}
            audio_path.write_text(json.dumps({"startedAt": 1000, "binding": binding, "samples": []}))
            row_path.write_text(json.dumps({"row": "L02", "restored": "focus-off", "activityAudio": str(audio_path),
                                            "activityAudioWindow": {"start": 1005, "end": 1010}}))
            c00_path = work / "c00.json"
            c00_path.write_text(json.dumps({"row": "C00", "status": "recorded", "restored": True,
                                           "audio": {"calibrationValid": False}}))
            (work / "audio-calibration.json").write_text(json.dumps({"calibrationValid": True, "binding": binding,
                                                                      "createdAt": 1030, "threshold": 0.0025,
                                                                      "quietP95": 0.0001, "signalP95": 0.01}))
            item = {"id": "activity-02-on-01", "row": "L02", "args": []}
            state = {"device": binding["device"], "buildHash": binding["build"], "completed": {
                item["id"]: {"status": "unqualified", "result": str(row_path)},
                "microphone-positive-01": {"status": "recorded", "result": str(c00_path)}}}
            batch.postclassify_activity_audio(work, state, [item])
            evidence = json.loads(row_path.read_text())["activityAcoustic"]
            self.assertEqual(evidence["status"], "unqualified")
            self.assertIsNone(evidence["energyAboveThreshold"])

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
                self.assertFalse((root / ".focus-locks" / "00008110-0011223344556677.lock").exists())
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
            self.assertTrue((root / ".focus-locks" / "00008110-0011223344556677.lock").is_dir())
            self.assertEqual(json.loads((work / "morning-checkpoint.json").read_text())["inFlight"], plan[0]["id"])

    def test_old_log_and_result_cannot_certify_new_attempt(self):
        for emit_old_result in [False, True]:
            with self.subTest(emit_old_result=emit_old_result), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                work = root / "work"
                work.mkdir()
                product = root / "device.xctestrun"
                product.write_bytes(b"signed-product")
                plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:1]
                old_dir = work / "C06-old"
                old_dir.mkdir()
                old_result = old_dir / "result.json"
                old_result.write_text(json.dumps({"row": "C06", "status": "unqualified", "restored": True}))
                old_payload = json.dumps({"row": "C06", "status": "unqualified", "result": str(old_result)})
                (work / ("batch-" + plan[0]["id"] + ".log")).write_text(old_payload + "\n")
                row_logs = []
                def fake_command(argv, env, log, timeout, should_pause=None):
                    if argv[1] == "C06":
                        row_logs.append(log)
                        if emit_old_result:
                            log.write_text(old_payload + "\n")
                        raise RuntimeError("row crashed")
                with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                     mock.patch.object(Path, "home", return_value=root), \
                     mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                     mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                     mock.patch.object(batch, "signed_build", return_value=product), \
                     mock.patch.object(batch, "command", side_effect=fake_command), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "current attempt" if emit_old_result else "no machine-readable result"):
                        batch.run_batch(plan, None)
                state = json.loads((work / "morning-checkpoint.json").read_text())
                self.assertEqual(state["completed"][plan[0]["id"]],
                                 {"status": "unqualified-interrupted", "result": None})
                self.assertIsNone(state["inFlight"])
                self.assertNotIn("inFlightAttempt", state)
                self.assertEqual(len(row_logs), 1)
                self.assertRegex(row_logs[0].name, r"-[a-f0-9]{32}\.log$")
                self.assertNotEqual(row_logs[0].name, "batch-" + plan[0]["id"] + ".log")

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
                if argv[1] in ["preflight", "restore-all"]:
                    self.assertEqual(env.get("FOCUS_REQUIRE_DEVICE_JOURNAL"), "1")
                if argv[1] == "C01":
                    self.assertNotIn("FOCUS_REQUIRE_DEVICE_JOURNAL", env)
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

    def test_failed_row_recovers_device_journal_before_next_sample(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:2]
            calls = []
            device = "00008110-0011223344556677"

            def fake_command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
                if argv[1] == "C06":
                    result_path = work / "failed-row.json"
                    result_path.write_text(json.dumps({"row": "C06", "status": "restore-failed-use-restore-all", "restored": False}))
                    log.write_text(json.dumps({"row": "C06", "status": "restore-failed-use-restore-all", "result": str(result_path)}) + "\n")
                    # command() returns this error only after successful process-group cleanup.
                    raise RuntimeError("row process stopped")
                if argv[1] == "restore-all":
                    self.assertEqual(env.get("FOCUS_REQUIRE_DEVICE_JOURNAL"), "1")
                    self.assertTrue((root / ".focus-locks" / (device + ".lock")).is_dir())
                if argv[1] == "C01":
                    self.assertNotIn("FOCUS_REQUIRE_DEVICE_JOURNAL", env)
                    checkpoint = json.loads((work / "morning-checkpoint.json").read_text())
                    self.assertEqual(checkpoint["completed"][plan[0]["id"]]["status"], "unqualified")
                    result_path = work / "next-row.json"
                    result_path.write_text(json.dumps({"row": "C01", "status": "recorded", "restored": "focus-off"}))
                    log.write_text(json.dumps({"row": "C01", "status": "recorded", "result": str(result_path)}) + "\n")

            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": device, "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda value, workdir: value), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(batch.run_batch(plan, None), 0)
            self.assertEqual(calls, ["preflight", "C06", "restore-all", "C01", "restore-all"])
            state = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertEqual(state["completed"][plan[0]["id"]]["reason"], "restore-failed-use-restore-all")
            self.assertEqual(state["completed"][plan[0]["id"]]["result"], str(work / "failed-row.json"))
            self.assertFalse(state["dirty"])
            self.assertIsNone(state["inFlight"])

    def test_failed_row_recovery_is_not_retried_and_keeps_lock(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:2]
            calls = []
            device = "00008110-0011223344556677"

            def fake_command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
                if argv[1] == "C06":
                    result_path = work / "failed-row.json"
                    result_path.write_text(json.dumps({"row": "C06", "status": "restore-failed-use-restore-all", "restored": False}))
                    log.write_text(json.dumps({"row": "C06", "status": "restore-failed-use-restore-all", "result": str(result_path)}) + "\n")
                    raise RuntimeError("row process stopped")
                if argv[1] == "restore-all":
                    self.assertEqual(env.get("FOCUS_REQUIRE_DEVICE_JOURNAL"), "1")
                    raise RuntimeError("cannot restore")

            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": device, "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda value, workdir: value), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, None)
            self.assertEqual(calls, ["preflight", "C06", "restore-all"])
            self.assertTrue((root / ".focus-locks" / (device + ".lock")).is_dir())
            state = json.loads((work / "morning-checkpoint.json").read_text())
            self.assertTrue(state["dirty"])
            self.assertEqual(state["inFlight"], plan[0]["id"])

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
            self.assertTrue((root / ".focus-locks" / "00008110-0011223344556677.lock").is_dir())

    def test_unknown_surviving_process_group_prevents_restore_and_unlock(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work = root / "work"
            product = root / "device.xctestrun"
            product.write_bytes(b"signed-product")
            plan = batch.make_plan(batch.DEFAULT_UNKNOWN)[:1]
            calls = []
            def fake_command(argv, env, log, timeout, should_pause=None):
                calls.append(argv[1])
                if argv[1] == "C06":
                    raise batch.ProcessGroupCleanupError("cannot verify process exit")
            with mock.patch.dict(os.environ, {"FOCUS_DEVICE": "00008110-0011223344556677", "FOCUS_WORK": str(work)}), \
                 mock.patch.object(Path, "home", return_value=root), \
                 mock.patch.object(batch, "identify_iphone13", side_effect=lambda device, workdir: device), \
                 mock.patch.object(batch, "authorize_microphone", return_value="authorized"), \
                 mock.patch.object(batch, "signed_build", return_value=product), \
                 mock.patch.object(batch, "command", side_effect=fake_command), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    batch.run_batch(plan, None)
            self.assertEqual(calls, ["preflight", "C06"])
            self.assertTrue((root / ".focus-locks" / "00008110-0011223344556677.lock").is_dir())

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
            self.assertFalse((root / ".focus-locks" / "00008110-0011223344556677.lock").exists())


if __name__ == "__main__":
    unittest.main()
