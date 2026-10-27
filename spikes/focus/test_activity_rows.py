import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from activity_rows import ActivityScenario, activity_plan, execute_activity, run_activity_case

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
            with patch.object(scenario, "send", return_value={"status": 200}) as send, patch("activity_rows.time.sleep"):
                self.assertTrue(scenario.cadence(3, 1))
                self.assertEqual(send.call_count, 3)
            self.assertNotIn("presentation", scenario.coverage)


if __name__ == "__main__":
    unittest.main()
