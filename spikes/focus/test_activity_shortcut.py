import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from activity_rows import run_activity_case


class ShortcutEvidenceTests(unittest.TestCase):
    def case(self, events, creations):
        with tempfile.TemporaryDirectory() as directory:
            scenario = Mock()
            scenario.row = "L07"
            scenario.run.folder = Path(directory)
            scenario.run.current_activity.return_value = {"activityID": "activity", "surfaceID": "surface"}
            scenario.trace.return_value = creations
            scenario.result = {}

            def copy(name, destination, test=False):
                self.assertEqual((name, test), ("focus-ui-result.json", True))
                self.assertEqual(scenario.run.ui.call_count, 1)  # before relaunch overwrites the result
                destination.write_text(json.dumps({"status": "ok", "events": events}))

            scenario.run.copy.side_effect = copy
            scenario.config.side_effect = lambda *args: self.assertTrue((Path(directory) / "activity-shortcut-ui.json").exists())
            run_activity_case(scenario)
            notes = {call.args[0]: call.args[1:] for call in scenario.note.call_args_list}
            self.assertEqual(notes["perActivityUpdateToken"][0], "observed")
            return notes["systemShortcutCreation"][0]

    def test_creation_requires_same_activity_and_bracketed_nonforeground_samples(self):
        events = [
            {"event": "activity.shortcutInvoked", "source": "Shortcuts UI", "tapStartUptimeMs": 1000, "uptimeMs": 1100},
            {"event": "activity.shortcutProbeState", "state": "background", "uptimeMs": 1200},
            {"event": "activity.shortcutProbeState", "state": "backgroundSuspended", "uptimeMs": 1400},
            {"event": "activity.shortcutObservation", "startUptimeMs": 1000, "tapEndUptimeMs": 1100,
             "firstSampleUptimeMs": 1200, "endUptimeMs": 1500, "samples": 2, "allNonForeground": True},
        ]
        creation = {"event": "activity.created", "activityID": "activity", "surfaceID": "surface", "monoMs": 1300}
        self.assertEqual(self.case(events, [creation]), "observed")
        self.assertEqual(self.case(events, []), "unqualified")
        self.assertEqual(self.case(events, [{**creation, "activityID": "other"}]), "unqualified")
        self.assertEqual(self.case(events, [{**creation, "monoMs": 1150}]), "unqualified")
        self.assertEqual(self.case([events[0], {**events[1], "state": "foreground"}, *events[2:]], [creation]), "unqualified")
        wide = [events[0], events[1], {**events[2], "uptimeMs": 2500}, {**events[3], "endUptimeMs": 2600}]
        self.assertEqual(self.case(wide, [creation]), "unqualified")


if __name__ == "__main__":
    unittest.main()
