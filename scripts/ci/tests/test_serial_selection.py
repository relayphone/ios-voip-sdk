import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import gate, select, workflow_optional_changes


BEFORE = '''name: SDK
jobs:
  plain-simulator:
    runs-on: xcode-27
  swift-livekit-native:
    runs-on: xcode-27
  expo-livekit-native:
    runs-on: xcode-27
  legacy-audio-lifecycle:
    needs: plain-simulator
    runs-on: macos-26
'''
AFTER = '''name: SDK
jobs:
  changes:
    uses: ./.github/workflows/ci-changes.yml
  sdk-native:
    needs: changes
    if: needs.changes.outputs.sdk == 'true'
    runs-on: xcode-27
  plain-simulator:
    needs: [changes, sdk-native, legacy-audio-lifecycle, swift-livekit-native, expo-livekit-native]
  swift-livekit-native:
    needs: changes
    if: needs.changes.outputs.swift == 'true'
    runs-on: xcode-27
  expo-livekit-native:
    needs: changes
    if: needs.changes.outputs.expo == 'true'
    runs-on: xcode-27
  legacy-audio-lifecycle:
    needs: [changes, sdk-native]
    if: needs.changes.outputs.legacy == 'true'
    runs-on: macos-26
'''


class SerialSelectionTests(unittest.TestCase):
    def test_sdk_input_runs_serial_critical_and_affected_expo_only(self):
        plan = select(['Expo/src/client.ts'])
        self.assertEqual(plan['sdk_plan'], {'sdk-native': True, 'legacy-audio-lifecycle': False,
            'swift-livekit-native': False, 'expo-livekit-native': True})
        self.assertFalse(plan['runtime'])

    def test_docs_only_skips_natives_but_main_requires_all_original_jobs(self):
        self.assertFalse(any(select(['README.md'])['sdk_plan'].values()))
        full = select([], full=True)
        self.assertEqual(set(full['sdk_plan']), {'sdk-native', 'legacy-audio-lifecycle',
                         'swift-livekit-native', 'expo-livekit-native'})
        self.assertTrue(all(full['sdk_plan'].values()))

    def test_legacy_dependency_migration_does_not_mask_real_edits(self):
        self.assertEqual(workflow_optional_changes(BEFORE, AFTER), set())
        self.assertEqual(workflow_optional_changes(BEFORE, AFTER.replace('runs-on: macos-26',
                         'runs-on: xcode-27')), {'legacy-audio-lifecycle'})

    def test_serial_gate_rejects_unexpected_skip(self):
        expected = {'sdk-native': True, 'legacy-audio-lifecycle': False,
                    'swift-livekit-native': False, 'expo-livekit-native': False}
        rows = {'changes': {'result': 'success'}, **{key: {'result': 'skipped'} for key in expected}}
        with self.assertRaises(ValueError): gate(rows, expected)
        rows['sdk-native']['result'] = 'success'
        gate(rows, expected)


if __name__ == '__main__':
    unittest.main()
