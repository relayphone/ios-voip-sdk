import unittest
from unittest.mock import Mock

from activity_rows import run_activity_case, summarize_render


class ActivityRenderContentTests(unittest.TestCase):
    def test_revision_label_does_not_alone_qualify_synthetic_content(self):
        receipt = {"status": 200, "transportAcknowledged": True, "revision": 7}
        event = {"event": "activity.renderSample", "revision": 7, "syntheticTextVisible": False}
        result = summarize_render([receipt], [event], None)
        self.assertEqual(result["observedRevisions"], [7])
        self.assertEqual(result["syntheticTextRevisions"], [])
        result = summarize_render([receipt], [event, {**event, "syntheticTextVisible": True}], None)
        self.assertEqual(result["syntheticTextRevisions"], [7])

    def run_case(self, visible, stale=False):
        scenario = Mock()
        scenario.row = "L01"
        scenario.result = {
            "activityReceipts": [{"status": 200, "transportAcknowledged": True, "revision": 7}],
            "activityObservation": [{"event": "activity.renderSample", "revision": 7,
                                      "syntheticTextVisible": visible, "stale": stale}],
        }
        scenario.cadence.return_value = True
        scenario.begin_audio.return_value = None
        scenario.finish_observer.return_value = {}
        run_activity_case(scenario)
        return {call.args[0]: (call.args[1], call.args[2] if len(call.args) > 2 else None)
                for call in scenario.note.call_args_list}

    def test_cadence_needs_content_but_stale_label_is_separate(self):
        hidden = self.run_case(False)
        self.assertEqual(hidden["renderCadence"][0], "unqualified")
        self.assertEqual(hidden["latestOrStale"][0], "unqualified")
        visible = self.run_case(True)
        self.assertEqual(visible["renderCadence"][0], "observed")
        self.assertEqual(visible["exactTranscriptContent"][0], "unqualified")
        stale = self.run_case(False, stale=True)
        self.assertEqual(stale["renderCadence"][0], "unqualified")
        self.assertEqual(stale["latestOrStale"][0], "observed")
        self.assertTrue(stale["latestOrStale"][1]["staleLabel"])


if __name__ == "__main__":
    unittest.main()
