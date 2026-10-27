from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import SDK_NATIVE_JOBS, gate, select, workflow_optional_changes, workflow_parts


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
        rows = {'changes': {'result': 'success'},
                **{k: {'result': 'success'} for k in SDK_NATIVE_JOBS},
                **{k: {'result': 'success'} for k in plan if k != 'sdk-native'}}
        gate(rows, plan)
        for result in ('skipped', 'cancelled', 'failure'):
            rows['routes-duo']['result'] = result
            with self.assertRaises(ValueError): gate(rows, plan)
        del rows['routes-duo']
        with self.assertRaises(ValueError): gate(rows, plan)

    def test_fixture_producer_change_selects_both_artifact_consumers(self):
        before = '''name: SDK\njobs:\n  sdk-fixtures:\n    steps:\n      - run: echo build\n  swift-livekit-native:\n    runs-on: xcode-27\n  expo-livekit-native:\n    runs-on: xcode-27\n  legacy-audio-lifecycle:\n    needs: sdk-fixtures\n  routes-duo:\n    needs: sdk-fixtures\n'''
        after = before.replace('echo build', 'echo changed-build')
        self.assertEqual(workflow_optional_changes(before, after), {'legacy-audio-lifecycle', 'routes-duo'})
        with self.assertRaises(ValueError): workflow_optional_changes(before, after.replace('  routes-duo:', '  renamed:'))


    def test_duo_job_guard_and_inherited_environment_select_duo(self):
        before = """name: SDK
env:
  PLAIN: ""
jobs:
  sdk-fixtures:
    steps:
      - run: echo build
  swift-livekit-native:
    runs-on: xcode-27
  expo-livekit-native:
    runs-on: xcode-27
  legacy-audio-lifecycle:
    needs: sdk-fixtures
  routes-duo:
    needs: [changes, sdk-fixtures]
    if: needs.changes.outputs.routes == 'true'
"""
        changed = before.replace("needs.changes.outputs.routes == 'true'", 'false')
        self.assertEqual(workflow_optional_changes(before, changed), {'routes-duo'})
        changed = before.replace('PLAIN: ""', 'PLAIN: changed')
        self.assertEqual(workflow_optional_changes(before, changed),
                         {'legacy-audio-lifecycle', 'swift-livekit-native', 'expo-livekit-native', 'routes-duo'})

    def test_real_duo_job_uses_verified_fixtures_and_stable_gate(self):
        root = Path(__file__).resolve().parents[3]
        jobs, _ = workflow_parts((root / '.github/workflows/sdk-m0.yml').read_text())
        duo = jobs['routes-duo']
        self.assertIn('needs: [changes, sdk-fixtures]', duo)
        self.assertIn("if: needs.changes.outputs.routes == 'true'", duo)
        self.assertIn('name: sdk-native-fixtures-${{ github.run_id }}', duo)
        self.assertLess(duo.index('sdk_artifacts.py unpack fixtures'), duo.index('run_sdk_routes.py'))
        self.assertIn('--build "$SDK_M1_CONTRACT_BUILD"', duo)
        self.assertIn('uses: ./.github/actions/upload-transfer', duo)
        self.assertIn('routes-duo', jobs['plain-simulator'])
        selection = (root / '.github/workflows/ci-changes.yml').read_text()
        self.assertIn('value: ${{ jobs.detect.outputs.routes }}', selection)
        self.assertIn('routes: ${{ steps.select.outputs.routes }}', selection)


if __name__ == '__main__': unittest.main()
