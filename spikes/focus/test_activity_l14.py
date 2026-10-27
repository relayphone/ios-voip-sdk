import unittest
from unittest.mock import Mock, patch

from activity_rows import run_activity_case


class ActivityL14Tests(unittest.TestCase):
    def scenario(self, ended_registration=False, terminal=True, dismiss_terminal=True):
        scenario = Mock()
        scenario.row = "L14"
        scenario.result = {}
        scenario.start.side_effect = [
            {"activityID": "activity-a", "surfaceID": "surface-a"},
            {"activityID": "activity-b", "surfaceID": "surface-b"},
        ]
        scenario.send.side_effect = [
            {"status": 200, "transportAcknowledged": True},
            {"status": 200, "transportAcknowledged": True},
        ]
        scenario.capabilities.side_effect = [
            {"activeActivityCount": 0, "registrationPresent": ended_registration, "updateTokenPresent": False},
            {"activeActivityCount": 0, "registrationPresent": False, "updateTokenPresent": False},
        ]
        before = [{"event": "activity.state", "activityID": "activity-a", "state": "active"}]
        after = before + ([{"event": "activity.state", "activityID": "activity-a", "state": "ended"}] if terminal else [])
        before_dismissal = after + [{"event": "activity.state", "activityID": "activity-b", "state": "active"}]
        after_dismissal = before_dismissal + ([{"event": "activity.state", "activityID": "activity-b", "state": "dismissed"}] if dismiss_terminal else [])
        scenario.trace.side_effect = [before, after, before_dismissal, after_dismissal]
        return scenario

    def test_end_attribution_and_unique_dismissal_marker(self):
        scenario = self.scenario()
        with patch("activity_rows.time.sleep"):
            run_activity_case(scenario)
        notes = {call.args[0]: (call.args[1], call.args[2] if len(call.args) > 2 else None)
                 for call in scenario.note.call_args_list}
        self.assertEqual(notes["endTransport"][0], "observed")
        self.assertEqual(notes["sameActivityTerminalState"][0], "observed")
        self.assertEqual(notes["localRegistrationCleanup"][0], "observed")
        self.assertEqual(notes["remoteEndCausality"][0], "unqualified")
        self.assertEqual(notes["sameDismissedActivityTerminalState"][0], "observed")
        self.assertEqual(notes["dismissalRegistrationCleanup"][0], "observed")
        marker = scenario.send.call_args_list[1].kwargs["text"]
        self.assertRegex(marker, r"^Synthetic dismissal [0-9a-f-]{36}$")
        scenario.ui_card.assert_called_once_with(marker, "before-dismissal")
        self.assertIn(((["activity-dismiss"],), {"text": marker}),
                      [(call.args, call.kwargs) for call in scenario.run.ui.call_args_list])

    def test_missing_state_or_present_registration_remains_unqualified(self):
        scenario = self.scenario(ended_registration=True, terminal=False, dismiss_terminal=False)
        with patch("activity_rows.time.sleep"):
            run_activity_case(scenario)
        notes = {call.args[0]: call.args[1] for call in scenario.note.call_args_list}
        self.assertEqual(notes["sameActivityTerminalState"], "unqualified")
        self.assertEqual(notes["localRegistrationCleanup"], "unqualified")
        self.assertEqual(notes["remoteEndCausality"], "unqualified")
        self.assertEqual(notes["userDismissal"], "observed")  # UI alone proves only card disappearance.
        self.assertEqual(notes["sameDismissedActivityTerminalState"], "unqualified")


if __name__ == "__main__":
    unittest.main()
