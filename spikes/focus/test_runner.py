import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from runner import Run, audio_control_eligible, correlate, matching_activity, needs_repeat_fence, repeat_cooldown, reports_complete, surface_windows

HERE = Path(__file__).resolve().parent


class DryRunTests(unittest.TestCase):
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
