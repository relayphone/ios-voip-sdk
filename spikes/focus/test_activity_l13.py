import unittest
from unittest.mock import Mock

from activity_rows import run_activity_case


class ActivityL13Tests(unittest.TestCase):
    def run_case(self, visible):
        scenario = Mock()
        scenario.row = "L13"
        scenario.send.return_value = {"status": 200, "transportAcknowledged": True, "bytes": 4090, "truncated": True}
        scenario.ui_visibility.side_effect = [visible, False]
        run_activity_case(scenario)
        return {call.args[0]: call.args[1] for call in scenario.note.call_args_list}

    def test_accepted_payload_does_not_prove_unicode_rendered(self):
        notes = self.run_case(False)
        self.assertEqual(notes["unicodePayloadTransport"], "observed")
        self.assertEqual(notes["previewSettingObservations"], "observed")
        self.assertEqual(notes["unicodeRendering"], "unqualified")
        self.assertEqual(notes["lockedPrivacy"], "unqualified")

    def test_visible_unicode_marker_qualifies_only_unlocked_render(self):
        notes = self.run_case(True)
        self.assertEqual(notes["unicodeRendering"], "observed")
        self.assertEqual(notes["lockedPrivacy"], "unqualified")


if __name__ == "__main__":
    unittest.main()
