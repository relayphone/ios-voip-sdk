import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from activity_rows import ActivityScenario, accepted, activity_plan, execute_activity, run_activity_case, summarize_render

HERE = Path(__file__).resolve().parent


class ActivityRowsTests(unittest.TestCase):
    def test_all_rows_have_device_free_plans_and_hardware_na_is_not_a_skip(self):
        for index in range(1, 17):
            row = f"L{index:02}"
            self.assertGreaterEqual(len(activity_plan(row)), 3)
            command = subprocess.run([str(HERE / "run.sh"), row, "--dry-run"], capture_output=True, text=True, timeout=10)
            self.assertEqual(command.returncode, 0, command.stderr)
            data = json.loads(command.stdout)
            self.assertIsNone(data["blocked"])
            if row == "L16":
                self.assertIn("no Dynamic Island", data["hardwareNA"])
        self.assertNotEqual(subprocess.run([str(HERE / "run.sh"), "L01", "--activity-focus", "on", "--dry-run"], capture_output=True).returncode, 0)

    def test_no_start_case_never_sends_a_push(self):
        scenario = Mock()
        scenario.row = "L05"
        scenario.capabilities.side_effect = [{"activeActivityCount": 0, "observedAtMs": 5}, {"activeActivityCount": 0}]
        with patch("activity_rows.time.sleep"):
            run_activity_case(scenario)
        scenario.send.assert_not_called()
        scenario.start.assert_not_called()
        self.assertIn("home", scenario.run.ui.call_args_list[0].args[0])
        self.assertIn("activity-absent", scenario.run.ui.call_args_list[-1].args[0])

    def test_uncalibrated_or_unobserved_subcase_cannot_be_recorded_as_complete(self):
        fake = Mock()
        fake.p = {"row": "L01"}
        fake.run_id = "run"
        result = {}
        with patch.object(ActivityScenario, "setup"), patch("activity_rows.run_activity_case") as case:
            case.side_effect = lambda scenario: scenario.note("lockScreen", "unqualified", "not observed")
            execute_activity(fake, result)
        self.assertEqual(result["status"], "unqualified")
        self.assertEqual(result["coverage"]["lockScreen"]["status"], "unqualified")

    def test_cadence_is_bounded_and_never_treats_apns_ack_as_render(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Mock()
            fake.p = {"row": "L11"}
            fake.folder = Path(directory)
            scenario = ActivityScenario(fake, {})
            with self.assertRaises(ValueError):
                scenario.cadence(61, 1)
            with patch.object(scenario, "send", return_value={"status": 200, "transportAcknowledged": True}) as send, patch("activity_rows.time.sleep"):
                self.assertTrue(scenario.cadence(3, 1))
                self.assertEqual(send.call_count, 3)
            self.assertNotIn("presentation", scenario.coverage)
            self.assertFalse(accepted({"status": 200, "transportAcknowledged": False}))

    def test_sender_failure_with_http_200_is_not_promoted_to_acknowledged(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Mock()
            fake.p = {"row": "L12"}
            fake.folder = Path(directory)
            fake.current_activity.return_value = {"activityID": "a", "surfaceID": "s"}
            def rejected(argv, timeout):
                receipt = Path(argv[argv.index("--receipt-file") + 1])
                receipt.write_text(json.dumps({"status": 200, "revision": 1}))
                raise RuntimeError("mismatched APNs request ID")
            fake.command.side_effect = rejected
            result = {}
            scenario = ActivityScenario(fake, result)
            value = scenario.send()
            self.assertEqual(value["status"], 200)
            self.assertFalse(accepted(value))
            self.assertFalse(value["transportAcknowledged"])

    def test_offline_failure_restores_network_before_propagating(self):
        scenario = Mock()
        scenario.row = "L09"
        scenario.read_file.return_value = {"lastPathUpdateAtMs": 1}
        scenario.send.return_value = {"status": 200, "transportAcknowledged": True}
        scenario.network_offline_snapshot.side_effect = RuntimeError("no verified route")
        with patch("activity_rows.time.sleep"), self.assertRaises(RuntimeError):
            run_activity_case(scenario)
        actions = [call.args[0] for call in scenario.run.ui.call_args_list]
        self.assertIn(["activity-network:offline"], actions)
        self.assertIn(["activity-network:restore"], actions)

    def test_remote_start_is_explicitly_alerting_and_uses_separate_update(self):
        scenario = Mock()
        scenario.row = "L15"
        scenario.send.side_effect = [{"status": 200, "transportAcknowledged": True, "surfaceID": "surface"},
                                     {"status": 200, "transportAcknowledged": True}]
        scenario.run.current_activity.return_value = {"activityID": "activity", "surfaceID": "surface"}
        scenario.result = {}
        run_activity_case(scenario)
        self.assertEqual(scenario.send.call_args_list[0].kwargs["event"], "start")
        self.assertEqual(scenario.send.call_args_list[0].kwargs["priority"], 10)
        self.assertEqual(scenario.send.call_args_list[1].kwargs["priority"], 5)
        scenario.ui_card.assert_called_once()

    def test_render_latency_requires_actual_revision_and_bounded_stable_clocks(self):
        receipt = {"status": 200, "transportAcknowledged": True, "revision": 7,
                   "hostSendStart": 1000.1, "hostSendEnd": 1000.12,
                   "hostMonotonicStart": 100.1, "hostMonotonicEnd": 100.12}
        sample = {"revision": 7, "wallTimeMs": 1000300, "uptimeMs": 5000, "sampleStartUptimeMs": 4990}
        events = [{**sample, "event": "activity.sample"}, {**sample, "event": "activity.renderSample"}]
        bounds = {"deviceMinusHostMin": -50, "deviceMinusHostMax": 50,
                  "hostWallAnchorMs": 1000000, "hostMonotonicAnchorMs": 100000}
        result = summarize_render([receipt], events, bounds)
        self.assertEqual(result["latencyStatus"], "bounded-observations")
        self.assertEqual(result["latencyBounds"][0]["lowerMs"], 120)
        self.assertEqual(result["latencyBounds"][0]["upperMs"], 250)
        self.assertEqual(summarize_render([receipt], [], bounds)["missingRevisions"], [7])
        self.assertEqual(summarize_render([receipt], events, {**bounds, "deviceMinusHostMax": 5000})["latencyStatus"], "unqualified")
        self.assertEqual(summarize_render([{**receipt, "hostMonotonicEnd": 101}], events, bounds)["latencyStatus"], "unqualified")


if __name__ == "__main__":
    unittest.main()
