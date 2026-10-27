import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import gate, select, workflow_parts


NATIVE = ('offline-controls', 'apple-host-controls', 'sdk-example', 'sdk-core',
          'sdk-fixtures', 'device-release', 'journeys')


def results(native, optional):
    return {'changes': {'result': 'success'},
            **{job: {'result': native} for job in NATIVE},
            **{job: {'result': optional} for job in
               ('legacy-audio-lifecycle', 'swift-livekit-native', 'expo-livekit-native', 'routes-duo')}}


class ParallelGateTests(unittest.TestCase):
    def test_full_selection_requires_every_shard_and_optional_job(self):
        expected = select([], full=True)['sdk_plan']
        rows = results('success', 'success')
        gate(rows, expected)
        for job in NATIVE:
            for result in ('failure', 'cancelled', 'skipped'):
                with self.subTest(job=job, result=result):
                    rows[job]['result'] = result
                    with self.assertRaises(ValueError): gate(rows, expected)
                    rows[job]['result'] = 'success'

    def test_docs_only_accepts_only_unselected_skips(self):
        expected = select(['README.md'])['sdk_plan']
        rows = results('skipped', 'skipped')
        gate(rows, expected)
        rows['sdk-core']['result'] = 'success'
        with self.assertRaises(ValueError): gate(rows, expected)

    def test_missing_or_unexpected_producer_fails_closed(self):
        expected = select([], full=True)['sdk_plan']
        rows = results('success', 'success')
        del rows['sdk-fixtures']
        with self.assertRaises(ValueError): gate(rows, expected)
        rows['sdk-fixtures'] = {'result': 'success'}
        rows['unknown-native'] = {'result': 'success'}
        with self.assertRaises(ValueError): gate(rows, expected)


class ParallelMatrixTests(unittest.TestCase):
    def groups(self, paths, **kwargs):
        return [row['group'] for row in select(paths, **kwargs)['matrix']['include']]

    def test_main_and_nightly_select_every_journey(self):
        self.assertEqual(self.groups([], full=True), ['m1', 'contracts', 'push-entry', 'system'])

    def test_pr_selects_critical_and_affected_journeys(self):
        self.assertEqual(self.groups(['Expo/src/client.ts']), ['m1'])
        self.assertEqual(self.groups(['Tests/AudioLifecycle/Controls.m']), ['m1', 'contracts'])
        self.assertEqual(self.groups(['Tests/PushLaunch/Controls.m']), ['m1', 'push-entry'])
        self.assertEqual(self.groups(['discovery/sdk_system_probe.swift']), ['m1', 'system'])

    def test_shared_simulator_and_sdk_inputs_select_every_journey(self):
        for path in ('scripts/sim/sim.py', 'scripts/ci/changes.py',
                     'discovery/run_sdk_m0.sh', 'Sources/VoIPSDK/SDK.swift', 'Package.swift',
                     'Integrations/LiveKit/Adapter.swift', 'Tests/NewFixture/test.swift',
                     'new/native-entry.cc', '.github/actions/upload-transfer/action.yml',
                     'scripts/new-native-helper.sh'):
            with self.subTest(path=path):
                self.assertEqual(self.groups([path]), ['m1', 'contracts', 'push-entry', 'system'])


    def test_real_workflow_wires_selected_shards_into_the_stable_gate(self):
        root = Path(__file__).resolve().parents[3]
        jobs, _ = workflow_parts((root / '.github/workflows/sdk-m0.yml').read_text())
        for job in NATIVE:
            self.assertIn("if: needs.changes.outputs.sdk == 'true'", jobs[job])
            self.assertIn(job, jobs['plain-simulator'])
        self.assertIn('fromJSON(needs.changes.outputs.matrix)', jobs['journeys'])
        selection = (root / '.github/workflows/ci-changes.yml').read_text()
        self.assertIn('value: ${{ jobs.detect.outputs.matrix }}', selection)
        self.assertIn('matrix: ${{ steps.select.outputs.matrix }}', selection)


if __name__ == '__main__': unittest.main()
