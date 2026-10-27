import unittest
from unittest.mock import Mock, patch

from activity_rows import run_activity_case


def notes(scenario):
    return {call.args[0]: call.args[1] for call in scenario.note.call_args_list}


class ActivityRequalificationTests(unittest.TestCase):
    def test_connected_stale_and_resume_require_fresh_path_callbacks(self):
        scenario = Mock()
        scenario.row = "L09"
        scenario.run.run_id = "run"
        first = {"event": "app.launch", "monoMs": 100}
        second = {"event": "app.launch", "monoMs": 200}
        scenario.trace.side_effect = [[], [first], [first], [first, second]]
        scenario.read_file.side_effect = [
            {"runID": "run", "source": "pathUpdate", "pathReady": True, "status": "satisfied", "lastPathUpdateUptimeMs": 101},
            {"runID": "run", "source": "pathUpdate", "pathReady": True, "status": "satisfied", "lastPathUpdateUptimeMs": 201},
        ]
        scenario.send.return_value = {"status": 200, "transportAcknowledged": True}
        scenario.verify_usb.side_effect = RuntimeError("stop before offline subcase")
        with patch("activity_rows.time.sleep"), self.assertRaises(RuntimeError):
            run_activity_case(scenario)
        self.assertEqual(notes(scenario)["connectedStale"], "observed")
        self.assertEqual(notes(scenario)["connectedResume"], "observed")
        self.assertEqual(notes(scenario)["connectedContinuity"], "unqualified")
        cards = [call.args[0] for call in scenario.ui_card.call_args_list]
        self.assertEqual(cards, ["Synthetic connected before stale", "Updates delayed", "Synthetic connected resumed"])

    def test_missing_connected_callback_is_unqualified_without_connected_sends(self):
        scenario = Mock()
        scenario.row = "L09"
        scenario.trace.return_value = []
        scenario.verify_usb.side_effect = RuntimeError("stop before offline subcase")
        with patch("activity_rows.time.sleep"), patch("activity_rows.time.monotonic", side_effect=[0, 21]), self.assertRaises(RuntimeError):
            run_activity_case(scenario)
        self.assertEqual(notes(scenario)["connectedStale"], "unqualified")
        self.assertEqual(notes(scenario)["connectedResume"], "unqualified")
        scenario.send.assert_not_called()

    def test_rediscovery_requires_new_pid_and_same_activity_trace(self):
        old = {"event": "app.launch", "pid": 10, "monoMs": 100}
        new = {"event": "app.launch", "pid": 11, "monoMs": 200}
        current = {"event": "activity.current", "activityID": "a", "monoMs": 201}
        for tail, expected in [([new, current], "observed"), ([{**new, "pid": 10}, current], "unqualified"),
                               ([new, {**current, "activityID": "other"}], "unqualified"), ([], "unqualified")]:
            with self.subTest(expected=expected, tail=tail):
                scenario = Mock()
                scenario.row = "L10"
                scenario.start.return_value = {"activityID": "a", "surfaceID": "s"}
                scenario.run.current_activity.return_value = {"activityID": "a", "surfaceID": "s"}
                scenario.trace.side_effect = [[old], [old, *tail]]
                scenario.send.return_value = {"expectedRejection": True, "transportAcknowledged": True}
                run_activity_case(scenario)
                self.assertEqual(notes(scenario)["processRediscovery"], expected)
                actions = [call.args[0] for call in scenario.run.ui.call_args_list]
                self.assertEqual(actions[:2], [["terminate"], ["launch", "activity-consent"]])


if __name__ == "__main__":
    unittest.main()
