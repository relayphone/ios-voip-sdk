import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import select


class ExpoJourneySelection(unittest.TestCase):
    def test_each_journey_input_requires_native_runtime_acceptance(self):
        for path in ('discovery/build_expo_livekit.py', 'discovery/run_expo_livekit.py',
                     'discovery/expo_livekit_conformance.py', 'discovery/check_expo_livekit.py',
                     'example/media.ts', 'example/journey.ts',
                     'example/modules/journey/apple/VoIPExampleJourneyModule.swift',
                     'discovery/run_swift_livekit.py', 'discovery/build_swift_livekit_contract.py',
                     'discovery/swift_livekit_conformance.py', 'discovery/run_scenario.py',
                     'discovery/sdk_m0_conformance.py', 'discovery/sdk_m1_conformance.py',
                     'discovery/summarize.py', 'scripts/sim/sim.py', 'scripts/sim/paths.py', 'VERSION'):
            with self.subTest(path=path):
                self.assertTrue(select([path])['sdk_plan']['expo-livekit-native'])


if __name__ == '__main__':
    unittest.main()
