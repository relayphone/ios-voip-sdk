import sys
import json
import os
import subprocess
import tempfile
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import select, gate, changed_paths


class SelectionTests(unittest.TestCase):
    def test_docs_only_pr_runs_no_heavy_jobs(self):
        plan = select(['README.md', 'docs/ci/sdk-jobs.md'])
        self.assertFalse(plan['sdk'])
        self.assertFalse(plan['runtime'])
        self.assertFalse(plan['helper'])
        self.assertFalse(any(plan['sdk_plan'].values()))

    def test_sdk_source_pr_selects_the_native_group_without_runtime(self):
        for path in ('Sources/VoIPCore/VoIPClient.swift', 'Examples/CallExample/CallExample/ContentView.swift',
                     'Tests/VoIPJourneyTests/Journeys.swift', 'IosVoipSDK.podspec'):
            with self.subTest(path=path):
                plan = select([path])
                self.assertTrue(plan['sdk'])
                self.assertFalse(plan['runtime'])
                self.assertEqual(plan['sdk_plan'], {'sdk-native': True})

    def test_main_and_nightly_keep_every_original_job_even_for_docs(self):
        plan = select(['README.md'], full=True)
        self.assertTrue(plan['sdk'] and plan['runtime'] and plan['helper'])
        self.assertTrue(all(plan['sdk_plan'].values()))

    def test_pr_routing_follows_product_and_infrastructure_boundaries(self):
        examples = [
            ('Tests/RuntimeTests/Runtime.swift', False, True, False),
            ('Tests/CKSimProtocolTests/RuntimeSessionTests.swift', False, True, False),
            ('Inspector/App.swift', False, True, False),
            ('Sources/Engine/RuntimeEngine.swift', True, True, False),
            ('Sources/CKSimProtocol/RuntimeSession.swift', True, True, False),
            ('Sources/VoIPCore/VoIPClient.swift', True, False, False),
            ('docs/research/callkit-simulator-probe/livecommunicationkit/multicall/Probe.swift', True, True, False),
            ('.github/workflows/sdk-m0.yml', True, False, False),
            ('.github/workflows/runtime-m4.yml', False, True, False),
            ('scripts/sim/sim.py', True, True, True),
            ('scripts/ci/changes.py', True, True, True),
            ('scripts/ci/sdk_build.sh', True, False, True),
            ('discovery/run_scenario.py', True, False, True),
            ('new/native-entry.cc', True, True, True),
            ('.github/ISSUE_TEMPLATE/bug.yml', False, False, False),
        ]
        for path, sdk, runtime, helper in examples:
            with self.subTest(path=path):
                plan = select([path])
                self.assertEqual((plan['sdk'], plan['runtime'], plan['helper']),
                                 (sdk, runtime, helper))

    def test_docs_do_not_hide_code_changes(self):
        plan = select(['docs/ci/README.md', 'Sources/Engine/RuntimeEngine.swift'])
        self.assertTrue(plan['sdk'] and plan['runtime'])

    def test_example_assets_are_sdk_inputs(self):
        self.assertTrue(select(['Examples/CallExample/CallExample/Assets.xcassets/Contents.json'])['sdk'])


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


class GitChangesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ci-selection-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git('init')
        (self.root / 'Sources').mkdir()
        (self.root / 'Sources/client.swift').write_text('source fixture\n')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        (self.root / 'docs').mkdir()
        (self.root / 'Sources/client.swift').rename(self.root / 'docs/moved.md')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture rename')
        self.head = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
            '-c', 'user.name=CI Fixture', '-c', 'user.email=fixture@example.invalid', *args],
            cwd=self.root, capture_output=True, text=True, check=True, timeout=10).stdout

    def test_rename_keeps_the_deleted_source_path_in_selection(self):
        paths = changed_paths(self.base, self.head, self.root)
        self.assertEqual(set(paths), {'Sources/client.swift', 'docs/moved.md'})
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


if __name__ == '__main__':
    unittest.main()
