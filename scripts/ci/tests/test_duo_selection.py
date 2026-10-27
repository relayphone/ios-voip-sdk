from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import gate, select, workflow_optional_changes


class DuoSelectionTests(unittest.TestCase):
    def test_duo_consumes_affected_source_and_shared_build_inputs(self):
        for path in ('Sources/VoIPSDK/AudioRoutes.swift', 'Tests/AudioRoutes/run.py',
                     'discovery/run_sdk_routes.py', 'discovery/sdk_m1_contracts_conformance.py',
                     'scripts/sim/sim.py', 'VERSION', 'new/native-entry.cc', 'Sources/New/Adapter.swift',
                     'docs/research/callkit-simulator-probe/livecommunicationkit/2026-10-21-iphone13-ios27-lck-basic.jsonl'):
            with self.subTest(path=path):
                self.assertTrue(select([path])['sdk_plan']['routes-duo'])
        self.assertFalse(select(['README.md'])['sdk_plan']['routes-duo'])
        self.assertTrue(select([], full=True)['sdk_plan']['routes-duo'])

    def test_selected_duo_cannot_be_skipped_or_omitted(self):
        plan = select([], full=True)['sdk_plan']
        rows = {'changes': {'result': 'success'}, **{k: {'result': 'success'} for k in plan}}
        gate(rows, plan)
        rows['routes-duo']['result'] = 'skipped'
        with self.assertRaises(ValueError): gate(rows, plan)
        del rows['routes-duo']
        with self.assertRaises(ValueError): gate(rows, plan)

    def test_producer_change_selects_both_artifact_consumers(self):
        before = '''name: SDK\njobs:\n  sdk-native:\n    steps:\n      - run: echo build\n  swift-livekit-native:\n    runs-on: xcode-27\n  expo-livekit-native:\n    runs-on: xcode-27\n  legacy-audio-lifecycle:\n    needs: sdk-native\n  routes-duo:\n    needs: sdk-native\n'''
        after = before.replace('echo build', 'echo changed-build')
        self.assertEqual(workflow_optional_changes(before, after), {'legacy-audio-lifecycle', 'routes-duo'})
        with self.assertRaises(ValueError): workflow_optional_changes(before, after.replace('  routes-duo:', '  renamed:'))


if __name__ == '__main__': unittest.main()
