import sys
import json
import os
import subprocess
import tempfile
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import select, gate, changed_paths, workflow_optional_changes


class SelectionTests(unittest.TestCase):
    def test_docs_only_pr_runs_no_heavy_jobs(self):
        plan = select(['README.md', 'docs/ci/sdk-jobs.md'])
        self.assertFalse(plan['sdk'])
        self.assertFalse(plan['runtime'])
        self.assertFalse(plan['helper'])
        self.assertFalse(any(plan['sdk_plan'].values()))

    def test_sdk_javascript_pr_keeps_critical_journey_without_runtime(self):
        plan = select(['Expo/src/ConversationClient.ts'])
        self.assertTrue(plan['sdk'])
        self.assertFalse(plan['runtime'])
        self.assertTrue(plan['sdk_plan']['sdk-native'])
        self.assertTrue(plan['sdk_plan']['expo-livekit-native'])
        self.assertFalse(plan['sdk_plan']['legacy-audio-lifecycle'])

    def test_main_and_nightly_keep_every_original_job_even_for_docs(self):
        plan = select(['README.md'], full=True)
        self.assertTrue(plan['sdk'] and plan['runtime'] and plan['helper'])
        self.assertTrue(all(plan['sdk_plan'].values()))

    def test_pr_routing_follows_product_and_infrastructure_boundaries(self):
        examples = [
            ('Tests/RuntimeEvents/run.py', False, True, True),
            ('Tests/CKSimProtocolTests/RuntimeSessionTests.swift', False, True, False),
            ('Inspector/App.swift', False, True, False),
            ('Sources/Engine/RuntimeEngine.swift', True, True, False),
            ('Sources/CKSimProtocol/RuntimeSession.swift', True, True, False),
            ('Sources/VoIPSDK/ConversationClient.swift', True, False, False),
            ('docs/research/callkit-simulator-probe/livecommunicationkit/multicall/Probe.swift', True, True, False),
            ('.github/workflows/sdk-m0.yml', True, False, False),
            ('.github/workflows/runtime-m4.yml', False, True, False),
            ('scripts/sim/sim.py', True, True, True),
            ('scripts/ci/changes.py', True, True, True),
            ('scripts/ci/sdk_artifacts.py', True, False, True),
            ('discovery/run_sdk_m0.sh', True, False, True),
            ('new/native-entry.cc', True, True, True),
            ('.github/ISSUE_TEMPLATE/bug.yml', False, False, False),
        ]
        for path, sdk, runtime, helper in examples:
            with self.subTest(path=path):
                plan = select([path])
                self.assertEqual((plan['sdk'], plan['runtime'], plan['helper']),
                                 (sdk, runtime, helper))

    def test_serial_native_and_legacy_follow_shared_and_contract_inputs(self):
        examples = [('Sources/VoIPSDK/ConversationClient.swift', True),
                    ('discovery/probe/push_report_entry.swift', False),
                    ('Sources/Engine/RuntimeEngine.swift', True),
                    ('Sources/CKSimProtocol/RuntimeSession.swift', True),
                    ('discovery/probe/sdk_m1_contracts.swift', True),
                    ('discovery/sdk_m2_audio_lifecycle.py', True)]
        for path, legacy in examples:
            with self.subTest(path=path):
                plan = select([path])
                self.assertTrue(plan['sdk_plan']['sdk-native'])
                self.assertEqual(plan['sdk_plan']['legacy-audio-lifecycle'], legacy)

    def test_native_dependency_changes_select_device_backends(self):
        plan = select(['package-lock.json'])
        self.assertTrue(plan['sdk_plan']['sdk-native'])
        self.assertTrue(plan['sdk_plan']['expo-livekit-native'])
        self.assertFalse(plan['sdk_plan']['legacy-audio-lifecycle'])
        self.assertTrue(select(['IosVoipSDK.podspec'])['sdk_plan']['expo-livekit-native'])

    def test_audio_contract_changes_select_the_legacy_decoder(self):
        self.assertTrue(select(['Tests/AudioLifecycle/Controls.m'])['sdk_plan']['legacy-audio-lifecycle'])

    def test_native_fixture_and_device_builder_changes_select_their_consumers(self):
        for path in ('Tests/SwiftLiveKit/NativeJourney.swift', 'Tests/SwiftLiveKit/Package.resolved'):
            with self.subTest(path=path):
                self.assertTrue(select([path])['sdk_plan']['swift-livekit-native'])
        self.assertTrue(select(['discovery/sdk_m2_audio_lifecycle.py'])['sdk_plan']['legacy-audio-lifecycle'])
        for path in ('discovery/build_sdk_device_release.py', 'discovery/device_oracles.py'):
            with self.subTest(path=path):
                plan = select([path])['sdk_plan']
                self.assertTrue(plan['sdk-native'])
                self.assertTrue(plan['expo-livekit-native'])

    def test_docs_do_not_hide_code_changes(self):
        plan = select(['docs/ci/README.md', 'Sources/Engine/RuntimeEngine.swift'])
        self.assertTrue(plan['sdk'] and plan['runtime'])

    def test_example_assets_are_sdk_inputs(self):
        self.assertTrue(select(['example/assets/icon.png'])['sdk'])


class GateTests(unittest.TestCase):
    def test_selected_checks_cannot_be_skipped_or_cancelled(self):
        for result in ('skipped', 'cancelled', 'failure'):
            with self.subTest(result=result), self.assertRaises(ValueError):
                gate({'changes': {'result': 'success'}, 'journeys': {'result': result}},
                     {'journeys': True})

    def test_intentional_skip_is_accepted_only_with_successful_selection(self):
        gate({'changes': {'result': 'success'}, 'journeys': {'result': 'skipped'}},
             {'journeys': False})
        with self.assertRaises(ValueError):
            gate({'changes': {'result': 'failure'}, 'journeys': {'result': 'skipped'}},
                 {'journeys': False})

    def test_unmapped_jobs_and_malformed_flags_fail_closed(self):
        for expected in ({}, {'journeys': 'false'}):
            with self.subTest(expected=expected), self.assertRaises(ValueError):
                gate({'changes': {'result': 'success'}, 'journeys': {'result': 'skipped'}}, expected)

    def test_selected_success_passes(self):
        gate({'changes': {'result': 'success'}, 'journeys': {'result': 'success'}},
             {'journeys': True})


class WorkflowChangeTests(unittest.TestCase):
    BEFORE = '''name: SDK
env:
  PLAIN: ""
jobs:
  swift-livekit-native:
    runs-on: xcode-27
    steps:
      - run: echo swift
  expo-livekit-native:
    runs-on: xcode-27
    steps:
      - run: echo expo
  legacy-audio-lifecycle:
    needs: plain-simulator
    runs-on: macos-26
    steps:
      - run: echo legacy
'''
    AFTER = '''name: SDK
env:
  PLAIN: ""
jobs:
  changes:
    uses: ./.github/workflows/ci-changes.yml
  swift-livekit-native:
    needs: changes
    if: needs.changes.outputs.swift == 'true'
    runs-on: xcode-27
    steps:
      - run: echo swift
  expo-livekit-native:
    needs: changes
    if: needs.changes.outputs.expo == 'true'
    runs-on: xcode-27
    steps:
      - run: echo expo
  legacy-audio-lifecycle:
    needs: [changes, sdk-native]
    if: needs.changes.outputs.legacy == 'true'
    runs-on: macos-26
    steps:
      - run: echo legacy
'''

    def test_execution_edit_selects_only_affected_optional_job(self):
        changed = self.AFTER.replace('echo swift', 'echo changed-swift')
        self.assertEqual(workflow_optional_changes(self.BEFORE, changed), {'swift-livekit-native'})

    def test_canonical_migration_keeps_critical_pr_policy(self):
        self.assertEqual(workflow_optional_changes(self.BEFORE, self.AFTER), set())

    def test_changed_guard_cannot_hide_its_job(self):
        changed = self.AFTER.replace("needs.changes.outputs.swift == 'true'", 'false')
        self.assertEqual(workflow_optional_changes(self.AFTER, changed), {'swift-livekit-native'})

    def test_inherited_execution_environment_selects_all_optional_jobs(self):
        changed = self.AFTER.replace('PLAIN: ""', 'PLAIN: custom')
        self.assertEqual(workflow_optional_changes(self.AFTER, changed),
                         {'swift-livekit-native', 'expo-livekit-native', 'legacy-audio-lifecycle'})

    def test_missing_job_or_unreadable_format_fails_closed(self):
        for changed in ('jobs: {}', self.AFTER.replace('  swift-livekit-native:', '  renamed:'),
                        self.AFTER + 'defaults:\n  run:\n    working-directory: example\n'):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                workflow_optional_changes(self.AFTER, changed)


class GitChangesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ci-selection-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git('init')
        (self.root / 'Expo').mkdir()
        (self.root / 'Expo/client.ts').write_text('source fixture\n')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        (self.root / 'docs').mkdir()
        (self.root / 'Expo/client.ts').rename(self.root / 'docs/moved.md')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture rename')
        self.head = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
            '-c', 'user.name=CI Fixture', '-c', 'user.email=fixture@example.invalid', *args],
            cwd=self.root, capture_output=True, text=True, check=True, timeout=10).stdout

    def test_rename_keeps_the_deleted_source_path_in_selection(self):
        paths = changed_paths(self.base, self.head, self.root)
        self.assertEqual(set(paths), {'Expo/client.ts', 'docs/moved.md'})
        self.assertTrue(select(paths)['sdk'])

    def invoke(self, event_name, payload, *args, extra=None):
        event, output = self.root / 'event.json', self.root / 'outputs'
        event.write_text(json.dumps(payload))
        if output.exists(): output.unlink()
        env = {**os.environ, 'GITHUB_EVENT_NAME': event_name, 'GITHUB_EVENT_PATH': str(event),
               'GITHUB_WORKSPACE': str(self.root), 'GITHUB_OUTPUT': str(output),
               'GITHUB_STEP_SUMMARY': str(self.root / 'summary.md'), **(extra or {})}
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'changes.py'), *args],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=10)
        return result, output

    def test_pr_cli_emits_boolean_and_json_job_outputs(self):
        result, output = self.invoke('pull_request', {'pull_request': {
            'base': {'sha': self.base}, 'head': {'sha': self.head}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.exists(), 'CLI must publish its selection outputs')
        values = dict(line.split('=', 1) for line in output.read_text().splitlines())
        self.assertEqual(values['sdk'], 'true')
        self.assertEqual(values['runtime'], 'false')
        self.assertTrue(json.loads(values['sdk_plan'])['sdk-native'])

    def test_unavailable_diff_fails_instead_of_publishing_a_skip(self):
        result, output = self.invoke('pull_request', {'pull_request': {
            'base': {'sha': '0' * 40}, 'head': {'sha': self.head}}})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_merge_group_uses_its_base_and_head(self):
        result, output = self.invoke('merge_group', {'merge_group': {
            'base_sha': self.base, 'head_sha': self.head}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.exists(), 'Queue selection must publish outputs')
        self.assertIn('sdk=true\n', output.read_text())

    def test_main_and_nightly_cli_use_full_policy_without_pr_payload(self):
        for event in ('push', 'schedule', 'workflow_dispatch'):
            with self.subTest(event=event):
                result, output = self.invoke(event, {})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(output.exists())
                values = dict(line.split('=', 1) for line in output.read_text().splitlines())
                self.assertTrue(all(json.loads(values['sdk_plan']).values()))

    def test_push_only_known_non_native_paths_skips_native_and_keeps_host_controls(self):
        (self.root / 'spikes').mkdir()
        (self.root / 'spikes/experiment.swift').write_text('fixture')
        (self.root / 'README.md').write_text('fixture')
        (self.root / 'docs/research').mkdir()
        (self.root / 'docs/research/probe.swift').write_text('fixture')
        self.git('add', '.')
        self.git('commit', '-m', 'non-native')
        head = self.git('rev-parse', 'HEAD').strip()
        result, output = self.invoke('push', {'before': self.head, 'after': head})
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for line in output.read_text().splitlines())
        self.assertEqual((values['sdk'], values['runtime'], values['helper']), ('false', 'false', 'true'))
        self.assertFalse(any(json.loads(values['sdk_plan']).values()))

    def test_push_unknown_mixed_and_unavailable_diffs_run_everything(self):
        (self.root / 'unknown').write_text('fixture')
        self.git('add', '.')
        self.git('commit', '-m', 'unknown')
        head = self.git('rev-parse', 'HEAD').strip()
        for payload in ({'before': self.base, 'after': self.head},
                        {'before': self.head, 'after': head},
                        {'before': '0' * 40, 'after': head},
                        {'before': 'f' * 40, 'after': head},
                        {'before': head, 'after': head}, {}):
            with self.subTest(payload=payload):
                result, output = self.invoke('push', payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                values = dict(line.split('=', 1) for line in output.read_text().splitlines())
                self.assertEqual((values['sdk'], values['runtime'], values['helper']), ('true', 'true', 'true'))
                self.assertTrue(all(json.loads(values['sdk_plan']).values()))

    def test_push_multi_commit_with_native_input_runs_everything(self):
        (self.root / 'native.swift').write_text('fixture')
        self.git('add', '.')
        self.git('commit', '-m', 'native research')
        (self.root / 'README.md').write_text('docs')
        self.git('add', '.')
        self.git('commit', '-m', 'documentation')
        head = self.git('rev-parse', 'HEAD').strip()
        result, output = self.invoke('push', {'before': self.head, 'after': head})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('sdk=true\n', output.read_text())
        self.assertIn('runtime=true\n', output.read_text())

    def test_force_push_compares_endpoints_not_merge_base(self):
        # Reverting a code deletion on a non-descendant branch must run native.
        self.git('checkout', '-b', 'other', self.base)
        (self.root / 'README.md').write_text('docs')
        self.git('add', '.')
        self.git('commit', '-m', 'other branch')
        other = self.git('rev-parse', 'HEAD').strip()
        result, output = self.invoke('push', {'before': self.head, 'after': other})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('sdk=true\n', output.read_text())

    def test_gate_cli_rejects_an_unexpected_native_skip(self):
        result, _ = self.invoke('pull_request', {}, 'gate', extra={
            'CI_NEEDS_JSON': json.dumps({'changes': {'result': 'success'}, 'journeys': {'result': 'skipped'}}),
            'CI_EXPECTED_JSON': json.dumps({'journeys': True})})
        self.assertNotEqual(result.returncode, 0)

    def test_workflow_job_edit_is_selected_through_the_real_git_cli(self):
        workflow = self.root / '.github/workflows/sdk-m0.yml'
        workflow.parent.mkdir(parents=True)
        workflow.write_text(WorkflowChangeTests.BEFORE)
        self.git('add', '.')
        self.git('commit', '-m', 'workflow base')
        base = self.git('rev-parse', 'HEAD').strip()
        workflow.write_text(WorkflowChangeTests.AFTER.replace('echo expo', 'echo new-expo'))
        self.git('add', '.')
        self.git('commit', '-m', 'workflow edit')
        head = self.git('rev-parse', 'HEAD').strip()
        result, output = self.invoke('pull_request', {'pull_request': {
            'base': {'sha': base}, 'head': {'sha': head}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for line in output.read_text().splitlines())
        jobs = json.loads(values['sdk_plan'])
        self.assertTrue(jobs['expo-livekit-native'])
        self.assertFalse(jobs['swift-livekit-native'])


if __name__ == '__main__':
    unittest.main()
