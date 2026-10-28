import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from runner import Run, audio_control_eligible, correlate, matching_activity, needs_repeat_fence, repeat_cooldown, reports_complete, require_device_supervisor, surface_windows

HERE = Path(__file__).resolve().parent


class DryRunTests(unittest.TestCase):
    def test_restore_reinstalls_only_verified_missing_probe_and_preserves_journal_first(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "test.xctestrun"
            app = root / "Debug-iphoneos" / "FocusProbe.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.callkitsim.focus"}))
            (app / "embedded.mobileprovision").write_bytes(b"profile")
            source.write_bytes(plistlib.dumps({"test": {"IsUITestBundle": True,
                "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/FocusProbe.app"}}))
            run = Run.__new__(Run)
            run.source, run.folder, run.device = source, root, "device"
            run.journal = root / "journal.json"
            run.journal.write_text('{"captured": true, "ownsFocus": true}')
            run.recover = Mock()
            run.arm = Mock()
            run.ui = Mock()
            actions = []
            def command(argv, **kwargs):
                actions.append(argv)
                if argv[1:5] == ["devicectl", "device", "info", "apps"]:
                    output = Path(argv[argv.index("--json-output") + 1])
                    installed = any(a[1:5] == ["devicectl", "device", "install", "app"] for a in actions)
                    output.write_text(json.dumps({"info": {"outcome": "success"}, "result": {"apps":
                        [{"bundleIdentifier": "dev.callkitsim.focus"}] if installed else []}}))
            run.command = command
            run.restore()
            run.recover.assert_called_once_with(required=True)
            run.arm.assert_called_once_with({"armed": False, "activityAction": "end"})
            self.assertEqual([a[0] for a in actions], ["xcrun", "codesign", "xcrun", "xcrun"])
            self.assertIn(str(app.resolve()), actions[2])
            self.assertTrue(json.loads(run.journal.read_text())["ownsFocus"])

    def test_restore_probe_inventory_or_identity_ambiguity_never_installs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            run = Run.__new__(Run)
            run.folder, run.device = root, "device"
            def bad_inventory(argv, **kwargs):
                Path(argv[argv.index("--json-output") + 1]).write_text('{"result": {}}')
            run.command = Mock(side_effect=bad_inventory)
            with self.assertRaises(RuntimeError):
                run.ensure_probe_installed()
            self.assertEqual(run.command.call_count, 1)
            def wrong_shape(argv, **kwargs):
                Path(argv[argv.index("--json-output") + 1]).write_text('{"info": [], "result": []}')
            run.command = Mock(side_effect=wrong_shape)
            with self.assertRaises(RuntimeError):
                run.ensure_probe_installed()
            self.assertEqual(run.command.call_count, 1)
            run.source = root / "test.xctestrun"
            run.source.write_bytes(plistlib.dumps({"test": {"IsUITestBundle": True,
                "UITargetAppPath": "__TESTROOT__/../../Other.app"}}))
            with self.assertRaises(RuntimeError):
                run.signed_probe()

    def test_quiet_preflight_plan_and_listen_are_exclusive(self):
        value = json.loads(self.run_plan("preflight", "--quiet").stdout)
        self.assertTrue(value["quiet"])
        self.assertTrue(any("durably" in step for step in value["steps"]))
        result = self.run_plan("C00", "--quiet", "--listen")
        self.assertNotEqual(result.returncode, 0)

    def test_ringer_mutation_receives_proof_only_for_valid_backed_up_journal(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            run = Run.__new__(Run)
            run.p = {"callerValue": "+15555550199"}
            run.work = run.folder = root
            run.journal = root / "journal.json"
            run.source = root / "test.xctestrun"
            run.source.write_bytes(plistlib.dumps({"test": {"IsUITestBundle": True}}))
            run.device, run.invitation, run.counter = "device", "invitation", 0
            run.unsafe_observer, run.usb_verified, run.journal_fresh = False, False, True
            run.recover = Mock()
            environments = []
            def command(argv, **kwargs):
                data = plistlib.loads(Path(argv[argv.index("-xctestrun") + 1]).read_bytes())
                environments.append(data["test"]["EnvironmentVariables"])
            run.command = command
            for value in ({"captured": True, "ringerVolumePercent": 37},
                          {"captured": True, "ringerVolumePercent": 101},
                          {"captured": False, "ringerVolumePercent": 37}):
                run.journal.write_text(json.dumps(value))
                run.journal_fresh = True
                run.ui(["ringer-volume:minimum"])
            self.assertEqual([env.get("FOCUS_RINGER_BACKED_UP") for env in environments], ["1", None, None])

    def test_device_rows_require_live_lock_owning_supervisor(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            device = "00008110-0011223344556677"
            lock = root / ".device-locks" / (device + ".lock")
            lock.mkdir(parents=True)
            nonce = "a" * 32
            (lock / "owner.json").write_text(json.dumps({"owner": "focus-morning-batch", "pid": 1234, "nonce": nonce}))
            env = {"FOCUS_DEVICE": device, "FOCUS_BATCH_OWNER_PID": "1234", "FOCUS_BATCH_LOCK_NONCE": nonce}
            with patch.object(Path, "home", return_value=root), patch.dict(os.environ, env, clear=True), \
                 patch("runner.os.getppid", return_value=1234), patch("runner.os.getpid", return_value=5678), \
                 patch("runner.os.getpgrp", return_value=5678):
                require_device_supervisor()
                (lock / "owner.json").write_text(json.dumps({"owner": "phone", "pid": 1234, "nonce": nonce}))
                with self.assertRaises(RuntimeError):
                    require_device_supervisor()

    def test_direct_device_row_rejected_before_device_commands(self):
        result = subprocess.run(["/bin/bash", str(HERE / "run.sh"), "L01"],
                                env={"PATH": os.environ["PATH"]}, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RuntimeError", result.stderr)

    def test_device_journal_recovery_replaces_stale_host_atomically(self):
        with tempfile.TemporaryDirectory() as folder:
            run = Run.__new__(Run)
            run.folder = Path(folder)
            run.journal = run.folder / "restore-state.json"
            run.journal.write_text('{"dndCalls": null}')
            run.copy = lambda name, path, test=False: path.write_text('{"dndCalls": "Everyone"}')
            run.recover(required=True)
            self.assertEqual(json.loads(run.journal.read_text())["dndCalls"], "Everyone")
            run.copy = lambda name, path, test=False: path.write_text('{broken')
            with self.assertRaises(RuntimeError):
                run.recover(required=True)
            self.assertEqual(json.loads(run.journal.read_text())["dndCalls"], "Everyone")

    def test_each_repeat_invitation_requires_one_matching_report(self):
        first = {"invitationID": "A", "outcome": "filtered"}
        second = {"invitationID": "B", "outcome": "reported"}
        self.assertTrue(reports_complete([first, second], ["a", "b"]))
        self.assertFalse(reports_complete([first, first], ["a", "b"]))
        self.assertFalse(reports_complete([first], ["a", "b"]))

    def test_repeat_fence_applies_before_pairs_and_after_prior_pairs(self):
        self.assertTrue(needs_repeat_fence("C02", {"repeatPair": False}))
        self.assertTrue(needs_repeat_fence("F13", {"repeatPair": True}))
        self.assertTrue(needs_repeat_fence("F13", {}))
        self.assertFalse(needs_repeat_fence("F13", {"repeatPair": False}))

    def test_repeat_visual_windows_distinguish_second_presentation(self):
        events = [
            {"event": "surface.transition", "surface": "banner", "visible": True, "uptimeMs": 105000},
            {"event": "surface.transition", "surface": "banner", "visible": False, "uptimeMs": 130000},
            {"event": "surface.transition", "surface": "banner", "visible": True, "uptimeMs": 171000},
        ]
        observation = {"startUptimeMs": 90000, "endUptimeMs": 190000}
        windows = surface_windows(events, [("first", 100000), ("second", 169000)], observation)
        self.assertEqual(windows[0]["bannerFirstNewPresentationUptimeMs"], 105000)
        self.assertEqual(windows[1]["bannerFirstNewPresentationUptimeMs"], 171000)
        self.assertTrue(windows[1]["observationQualified"])
        self.assertFalse(windows[1]["bannerVisibleAtStart"])
        carry = surface_windows(events[:1], [("first", 100000), ("second", 169000)], observation)
        self.assertTrue(carry[1]["bannerVisibleAtStart"])
        self.assertIsNone(carry[1]["bannerFirstNewPresentationUptimeMs"])
        short = surface_windows(events, [("first", 100000), ("second", 169000)], {"startUptimeMs": 90000, "endUptimeMs": 180000})
        self.assertFalse(short[1]["observationQualified"])

    def test_surface_foreground_gap_is_recorded_and_disqualifies_absence(self):
        events = [{"event": "surface.gap", "reason": "foreground-transition",
                   "startUptimeMs": 100010, "endUptimeMs": 100500},
                  {"event": "surface.transition", "surface": "callScreen", "visible": True, "uptimeMs": 100600}]
        windows = surface_windows(events, [("first", 100000)], {"startUptimeMs": 90000, "endUptimeMs": 120000})
        self.assertTrue(windows[0]["observationQualified"])
        self.assertFalse(windows[0]["continuityQualified"])
        self.assertEqual(windows[0]["callScreenFirstNewPresentationUptimeMs"], 100600)
        # A surface first seen after a gap is raw evidence, not a qualified presentation.
        self.assertFalse(windows[0]["observationQualified"] and windows[0]["continuityQualified"])
        crossing = [{**events[0], "startUptimeMs": 99900}, events[1]]
        crossing_window = surface_windows(crossing, [("first", 100000)], {"startUptimeMs": 90000, "endUptimeMs": 120000})[0]
        self.assertEqual(crossing_window["callScreenFirstNewPresentationUptimeMs"], 100600)
        self.assertFalse(crossing_window["continuityQualified"])
        windows = surface_windows(events, [("first", 101000)], {"startUptimeMs": 90000, "endUptimeMs": 120000})
        self.assertTrue(windows[0]["continuityQualified"])
        malformed = [{"event": "surface.gap", "startUptimeMs": None}]
        self.assertFalse(surface_windows(malformed, [("first", 100000)], {"startUptimeMs": 90000, "endUptimeMs": 120000})[0]["continuityQualified"])

    def test_repeat_pair_waits_until_prior_attempt_is_outside_three_minutes(self):
        self.assertEqual(repeat_cooldown(1000, 1000), 181)
        self.assertEqual(repeat_cooldown(1000, 1179), 2)
        self.assertEqual(repeat_cooldown(1000, 1181), 0)
        self.assertEqual(repeat_cooldown(1000, 1300), 0)

    def test_activity_registration_requires_current_matching_token_generation(self):
        registration = {"activityID": "activity-a", "surfaceID": "surface-a", "tokenGeneration": "generation-a", "state": "active"}
        token = {**registration, "token": "ab" * 32}
        self.assertTrue(matching_activity(registration, token))
        self.assertFalse(matching_activity(registration, {**token, "activityID": "old-activity"}))
        self.assertFalse(matching_activity(registration, {**token, "tokenGeneration": "old-generation"}))
        self.assertFalse(matching_activity({**registration, "state": "ended"}, token))
        self.assertFalse(matching_activity(registration, {**token, "token": "bad"}))

    def test_callkit_comparison_rows_and_handle_controls(self):
        person = json.loads(self.run_plan("CK-F13").stdout)
        self.assertEqual((person["provider"], person["focus"], person["app"], person["person"]),
                         ("callkit", True, False, True))
        for row, provider in [("CK-C02", "callkit"), ("LCK-C02b", "lck")]:
            result = self.run_plan(row, "--repeated-calls", "on", "--caller-format", "generic")
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual((data["provider"], data["repeatedCalls"], data["handleType"]),
                             (provider, "on", "generic"))
            self.assertTrue(any("181s" in step for step in data["steps"]))
            self.assertTrue(any("69s" in step and "second distinct call" in step for step in data["steps"]))
        national = json.loads(self.run_plan("C01", "--provider", "callkit", "--caller-format", "national", "--calls", "Contacts Only", "--keep-setup").stdout)
        self.assertEqual((national["provider"], national["handleType"], national["callerValue"]),
                         ("callkit", "phoneNumber", "5555550199"))
        self.assertEqual(national["callsFrom"], "Contacts Only")
        self.assertTrue(national["keepSetup"])
        self.assertIn("restore-all after matrix", national["steps"][-1])

    def test_builtin_dnd_unknown_and_local_answer_plan(self):
        result = self.run_plan("CK-F09", "--focus-mode", "dnd", "--caller-value", "+15555550200", "--unknown-caller", "--server-answer")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual((data["provider"], data["focusMode"], data["unknownCaller"], data["serverAnswer"]), ("callkit", "dnd", True, True))
        self.assertIn("local answer signal", " ".join(data["steps"]))
        self.assertNotEqual(self.run_plan("F13", "--focus-mode", "dnd").returncode, 0)
        self.assertNotEqual(self.run_plan("CK-F09", "--unknown-caller", "--caller-value", "+15555550199").returncode, 0)
        self.assertNotEqual(self.run_plan("CK-C02", "--server-answer").returncode, 0)
        self.assertFalse(json.loads(self.run_plan("preflight").stdout)["sendVoIP"])

    def test_answer_signal_requires_visible_ui_and_observed_disappearance(self):
        from runner import answer_evidence
        observation = {"startUptimeMs": 900, "endUptimeMs": 1500}
        signal = [{"event": "answer.signal", "signalID": "abc", "monoMs": 1100},
                  {"event": "answer.report", "signalID": "abc", "monoMs": 1120}]
        events = [{"event": "surface.transition", "surface": "callScreen", "visible": True, "callerMatched": True, "uptimeMs": 1000},
                  {"event": "surface.transition", "surface": "callScreen", "visible": False, "uptimeMs": 1200},
                  {"event": "surface.sample", "uptimeMs": 1000}, {"event": "surface.sample", "uptimeMs": 1200}]
        events = [{**event, "sampleStartUptimeMs": event["uptimeMs"] - 20} for event in events]
        baseline = [{"event": "surface.sample", "surface": surface, "visible": False,
                     "sampleStartUptimeMs": 905, "uptimeMs": 925} for surface in ("banner", "callScreen")]
        events += baseline
        gap = {"event": "surface.gap", "startUptimeMs": 1100, "endUptimeMs": 1150}
        self.assertEqual(answer_evidence(events + [gap], signal, observation, "abc", 950)["reason"], "surface-observation-gap")
        evidence = answer_evidence(events, signal, observation, "abc", 950)
        self.assertEqual((evidence["status"], evidence["signalToDismissalMs"]), ("observed", 100))
        self.assertEqual(answer_evidence(events[1:], signal, observation, "abc", 950)["status"], "unqualified")
        self.assertEqual(answer_evidence(events[:1], signal, observation, "abc", 950)["status"], "unqualified")
        self.assertEqual(answer_evidence(events, signal[:1], observation, "abc", 950)["status"], "unqualified")
        self.assertEqual(answer_evidence(events, signal, observation, "abc", 1050)["status"], "unqualified")
        self.assertEqual(answer_evidence([{**events[0], "callerMatched": False}, *events[1:]], signal, observation, "abc", 950)["status"], "unqualified")
        self.assertEqual(answer_evidence(events[:2], signal, observation, "abc", 950)["status"], "unqualified")
        self.assertEqual(answer_evidence([e for e in events if e.get("uptimeMs") != 925], signal, observation, "abc", 950)["reason"], "missing-pre-push-surface-sample")
        preexisting = [{**e, "visible": True} if e.get("uptimeMs") == 925 and e.get("surface") == "callScreen" else e for e in events]
        self.assertEqual(answer_evidence(preexisting, signal, observation, "abc", 950)["reason"], "pre-push-surface-not-clear")
        handoff = [{"event": "surface.transition", "surface": "banner", "visible": True, "callerMatched": True, "uptimeMs": 1000},
                   {"event": "surface.transition", "surface": "banner", "visible": False, "uptimeMs": 1200},
                   {"event": "surface.transition", "surface": "callScreen", "visible": True, "callerMatched": True, "uptimeMs": 1200},
                   {"event": "surface.transition", "surface": "callScreen", "visible": False, "uptimeMs": 1400},
                   {"event": "surface.sample", "uptimeMs": 1000}, {"event": "surface.sample", "uptimeMs": 1200},
                   {"event": "surface.sample", "uptimeMs": 1400}]
        handoff = [{**event, "sampleStartUptimeMs": event["uptimeMs"] - 20} for event in handoff]
        handoff += baseline
        self.assertEqual(answer_evidence(handoff, signal, observation, "abc", 950)["signalToDismissalMs"], 300)
        self.assertEqual(answer_evidence([e for e in handoff if e.get("uptimeMs") != 1400], signal, observation, "abc", 950)["status"], "unqualified")
        crossing = [{**e, "sampleStartUptimeMs": 940} if e["uptimeMs"] == 1000 else e for e in events]
        self.assertEqual(answer_evidence(crossing, signal, observation, "abc", 950)["status"], "unqualified")
        crossing = [{**e, "sampleStartUptimeMs": 1110} if e["uptimeMs"] == 1200 else e for e in events]
        self.assertEqual(answer_evidence(crossing, signal, observation, "abc", 950)["status"], "unqualified")

    def test_failed_positive_control_cannot_qualify_audio(self):
        valid = {"status": "recorded", "visualNegativeQualified": True, "reports": [{"outcome": "reported"}]}
        self.assertTrue(audio_control_eligible(valid))
        self.assertFalse(audio_control_eligible({**valid, "status": "unqualified"}))
        self.assertFalse(audio_control_eligible({**valid, "visualNegativeQualified": False}))
        self.assertFalse(audio_control_eligible({**valid, "reports": []}))

    def test_calibration_must_be_positive_recent_and_from_same_device_build(self):
        run = Run.__new__(Run)
        run.binding = {"device": "fixture-phone", "build": "fixture-build"}
        with tempfile.TemporaryDirectory() as folder, patch("runner.time.time", return_value=10000):
            path = Path(folder) / "calibration.json"
            for value, expected in [
                ({"positive": True, "createdAt": 9990, "binding": run.binding}, True),
                ({"positive": False, "createdAt": 9990, "binding": run.binding}, False),
                ({"positive": True, "createdAt": 5000, "binding": run.binding}, False),
                ({"positive": True, "createdAt": 9990, "binding": {"device": "other", "build": "fixture-build"}}, False),
            ]:
                path.write_text(json.dumps(value))
                self.assertEqual(run.qualified(path), expected)

    def test_native_uppercase_uuid_correlates_with_host_invitation(self):
        native = {"event": "report.result", "invitationID": "A8EDAA66-EF01-4E4F-8B31-8F31B9FA998A"}
        unrelated = {"event": "report.result", "invitationID": "00000000-0000-0000-0000-000000000000"}
        self.assertEqual(correlate([native, unrelated], ["a8edaa66-ef01-4e4f-8b31-8f31b9fa998a"]), [native])

    def run_plan(self, row, *args):
        return subprocess.run(["/bin/bash", str(HERE / "run.sh"), row, "--dry-run", *args],
                              capture_output=True, text=True, timeout=10)

    def test_full_matrix_and_no_credentials_required(self):
        for n in range(1, 17):
            result = self.run_plan(f"F{n:02}")
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual(plan["focus"], n > 8)
            self.assertEqual(plan["cn"], n % 2 == 0)
        self.assertTrue(json.loads(self.run_plan("F03").stdout)["app"])
        self.assertTrue(json.loads(self.run_plan("F05").stdout)["person"])

    def test_dry_run_does_not_execute_device_or_microphone_commands(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ["xcrun", "xcodebuild", "node", "swiftc"]:
                path = Path(folder) / name
                path.write_text("#!/bin/sh\necho UNEXPECTED_EXECUTION >&2\nexit 99\n")
                path.chmod(0o700)
            env = {**os.environ, "PATH": folder + ":" + os.environ["PATH"]}
            result = subprocess.run(["/bin/bash", str(HERE / "run.sh"), "F01", "--dry-run", "--locked-auto-answer", "--listen"],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("end UI session", result.stdout)
            self.assertNotIn("UNEXPECTED_EXECUTION", result.stderr)

    def test_unknown_rows_fail_and_restore_sends_no_push(self):
        self.assertNotEqual(self.run_plan("F99").returncode, 0)
        plan = json.loads(self.run_plan("restore-all").stdout)
        self.assertFalse(plan["sendVoIP"])


if __name__ == "__main__":
    unittest.main()
