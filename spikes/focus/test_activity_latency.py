import unittest

from activity_rows import summarize_render


class ActivityLatencyTests(unittest.TestCase):
    def test_first_ever_render_lower_bound_does_not_assume_no_unseen_transient(self):
        receipt = {"status": 200, "transportAcknowledged": True, "revision": 7,
                   "hostSendStart": 1000.1, "hostSendEnd": 1000.12,
                   "hostMonotonicStart": 100.1, "hostMonotonicEnd": 100.12}
        bounds = {"deviceMinusHostMin": 50, "deviceMinusHostMax": 50,
                  "hostWallAnchorMs": 1000000, "hostMonotonicAnchorMs": 100000,
                  "deviceWallAnchorMs": 1000050, "deviceUptimeAnchorMs": 4750}
        negative = {"event": "activity.sample", "revision": 6, "wallTimeMs": 1000200,
                    "uptimeMs": 4900, "sampleStartUptimeMs": 4890}
        positive = {"revision": 7, "wallTimeMs": 1000300, "uptimeMs": 5000,
                    "sampleStartUptimeMs": 4990}
        events = [negative, {**positive, "event": "activity.sample"},
                  {**positive, "event": "activity.renderSample"}]
        result = summarize_render([receipt], events, bounds)
        self.assertEqual(result["latencyStatus"], "bounded-observations")
        self.assertEqual(result["latencyBounds"], [{"revision": 7, "lowerMs": 0, "upperMs": 400}])
        self.assertIn("zero lower bound", result["latencyScope"])
        self.assertEqual(summarize_render([receipt], events[1:], bounds)["latencyBounds"][0]["lowerMs"], 0)


if __name__ == "__main__":
    unittest.main()
