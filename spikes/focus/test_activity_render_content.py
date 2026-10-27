import unittest
from unittest.mock import Mock, patch

from activity_rows import cadence_excerpt, exact_cadence_summary, run_activity_case, summarize_render


class ActivityRenderContentTests(unittest.TestCase):
    def test_exact_cadence_joins_only_run_bound_accepted_same_activity_evidence(self):
        observation = "550e8400-e29b-41d4-a716-446655440000"
        other = "eaf5852c-2ec8-4612-bb96-6b51ee14dce3"
        continuity = {"activityID": "activity", "surfaceID": "surface"}
        bounds = {"deviceMinusHostMin": -50, "deviceMinusHostMax": 50,
                  "hostWallAnchorMs": 1000000, "hostMonotonicAnchorMs": 100000,
                  "deviceWallAnchorMs": 1000000, "deviceUptimeAnchorMs": 4200}
        receipt = {"status": 200, "transportAcknowledged": True, "event": "update", "revision": 7,
                   "cadenceObservationID": observation, "hostSendStart": 1000.1, "hostSendEnd": 1000.12,
                   "hostMonotonicStart": 100.1, "hostMonotonicEnd": 100.12,
                   "checkedTokenSnapshot": {"kind": "per-activity", **continuity}}
        sample = {"event": "activity.renderSample", "revision": 7, "observationID": observation,
                  "syntheticExactMatch": True, "stale": False, "wallTimeMs": 1000800,
                  "uptimeMs": 5000, "sampleStartUptimeMs": 4990}
        def summary(receipts=None, events=None, clock=bounds, expected=observation, identity=continuity, requested=1):
            return exact_cadence_summary([receipt] if receipts is None else receipts,
                                         [sample] if events is None else events, clock, expected, identity, requested)
        result = summary()
        self.assertEqual(result["exactRevisions"], [7])
        self.assertTrue(result["latestAcceptedExact"])
        self.assertTrue(result["allRequestedExact"])
        self.assertNotIn("Synthetic cadence", str(result))
        self.assertIn("accessibility-tree", result["scope"])
        self.assertIn("pixel visibility", result["scope"])
        for altered in ({"syntheticExactMatch": False}, {"stale": True}, {"observationID": other},
                        {"revision": 8}, {"sampleStartUptimeMs": 4500}):
            self.assertEqual(summary(events=[{**sample, **altered}])["exactRevisions"], [])
        for altered in ({"transportAcknowledged": False}, {"cadenceObservationID": other},
                        {"checkedTokenSnapshot": {"kind": "per-activity", "activityID": "other", "surfaceID": "surface"}}):
            self.assertEqual(summary(receipts=[{**receipt, **altered}])["exactRevisions"], [])
        self.assertEqual(summary(receipts=[receipt, receipt])["exactRevisions"], [])
        self.assertEqual(summary(clock=None)["exactRevisions"], [])
        self.assertEqual(summary(events=[])["exactRevisions"], [])
        self.assertFalse(summary(requested=25)["allRequestedExact"])
        receipts = [{**receipt, "revision": revision} for revision in range(1, 26)]
        events = [{**sample, "revision": revision} for revision in range(1, 26)]
        complete = summary(receipts=receipts, events=events, requested=25)
        self.assertTrue(complete["allRequestedExact"])
        self.assertTrue(complete["latestAcceptedExact"])
        partial = summary(receipts=receipts, events=events[:-1], requested=25)
        self.assertEqual(len(partial["exactRevisions"]), 24)
        self.assertFalse(partial["allRequestedExact"])
        self.assertFalse(partial["latestAcceptedExact"])

    def test_cadence_excerpt_is_strictly_synthetic(self):
        observation = "550e8400-e29b-41d4-a716-446655440000"
        self.assertEqual(cadence_excerpt(observation, 7), f"Synthetic cadence {observation} revision 7")
        for invalid in ("invalid", observation.upper(), None):
            with self.assertRaises((ValueError, TypeError)):
                cadence_excerpt(invalid, 7)
        for invalid in (0, 1_000_001, True, "7"):
            with self.assertRaises(ValueError):
                cadence_excerpt(observation, invalid)

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

    def test_exact_transcript_coverage_requires_completed_cadence_and_latest_match(self):
        for latest, completed, expected in ((False, True, "unqualified"), (True, False, "unqualified"), (True, True, "observed")):
            with self.subTest(latest=latest, completed=completed):
                scenario = Mock()
                scenario.row = "L01"
                scenario.result = {"activityReceipts": [], "activityObservation": []}
                scenario.cadence.return_value = completed
                scenario.begin_audio.return_value = None
                scenario.finish_observer.return_value = {}
                detail = {"exactRevisions": [1], "latestAcceptedExact": latest, "allRequestedExact": False}
                with patch("activity_rows.exact_cadence_summary", return_value=detail):
                    run_activity_case(scenario)
                calls = [call for call in scenario.note.call_args_list if call.args[0] == "exactTranscriptContent"]
                self.assertEqual(calls[0].args[1], expected)
                self.assertEqual(calls[0].args[2]["exactRevisions"], [1])
                pixel = [call for call in scenario.note.call_args_list if call.args[0] == "pixelVisibleExactText"]
                self.assertEqual(pixel[0].args[1], "unqualified")

    def test_l11_exact_coverage_requires_all_requested_for_each_setting(self):
        scenario = Mock()
        scenario.row = "L11"
        scenario.result = {"activityReceipts": [], "activityObservation": []}
        scenario.finish_observer.return_value = {}
        scenario.cadence.return_value = True
        partial = {"exactRevisions": [1], "latestAcceptedExact": True, "allRequestedExact": False}
        complete = {"exactRevisions": list(range(1, 13)), "latestAcceptedExact": True, "allRequestedExact": True}
        with patch("activity_rows.exact_cadence_summary", side_effect=[partial, complete]):
            run_activity_case(scenario)
        calls = {call.args[0]: call.args[1:] for call in scenario.note.call_args_list}
        self.assertEqual(calls["exactCadence-false"][0], "unqualified")
        self.assertEqual(calls["exactCadence-false"][1]["exactRevisions"], [1])
        self.assertEqual(calls["exactCadence-true"][0], "observed")
        self.assertEqual(calls["pixelVisibleExactText"][0], "unqualified")


if __name__ == "__main__":
    unittest.main()
