import sys
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nightly_coverage import REQUIRED, covered, has_coverage, main


class NightlyCoverageTests(unittest.TestCase):
    def jobs(self, workflow):
        jobs = [{'name': name, 'conclusion': 'success'} for name in REQUIRED[workflow]]
        return {'total_count': len(jobs), 'jobs': jobs}

    def test_requires_every_native_job_to_succeed_in_one_complete_list(self):
        for workflow in REQUIRED:
            with self.subTest(workflow=workflow):
                jobs = self.jobs(workflow)
                self.assertTrue(covered(workflow, jobs))
                jobs['jobs'][0]['conclusion'] = 'skipped'
                self.assertFalse(covered(workflow, jobs))
                jobs['jobs'][0]['conclusion'] = 'failure'
                self.assertFalse(covered(workflow, jobs))
                jobs['jobs'][0]['conclusion'] = 'success'
                jobs['total_count'] += 1
                self.assertFalse(covered(workflow, jobs))

    def test_skips_incomplete_candidates_and_checks_exact_main_sha_and_attempt(self):
        sha = 'a' * 40
        run = {'head_sha': sha, 'head_branch': 'main', 'event': 'push', 'status': 'completed',
               'conclusion': 'success', 'id': 123, 'run_attempt': 2}
        runs = [dict(run, head_sha='b' * 40), dict(run, event='pull_request'),
                dict(run, id=122), run]
        paths = []
        def fetch(path, token):
            paths.append(path)
            if 'workflows/' in path:
                return {'workflow_runs': runs}
            if '/122/' in path:
                return {'total_count': 0, 'jobs': []}
            return self.jobs('runtime-m4.yml')
        self.assertTrue(has_coverage('runtime-m4.yml', 'owner/repo', sha, 'token', fetch))
        self.assertEqual(len(paths), 3)
        self.assertIn('/123/attempts/2/jobs?', paths[-1])
        self.assertIn('head_sha=' + sha, paths[0])

    def test_api_failure_fails_open_and_other_events_do_not_query(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / 'output')
            env = {'GITHUB_EVENT_NAME': 'schedule', 'GITHUB_REPOSITORY': 'o/r',
                   'GITHUB_SHA': 'a' * 40, 'GH_TOKEN': 'token', 'GITHUB_OUTPUT': output}
            with patch.dict('os.environ', env), patch('sys.argv', ['script', 'runtime-m4.yml']), \
                 patch('nightly_coverage.has_coverage', side_effect=OSError('offline')):
                main()
            self.assertEqual(Path(output).read_text(), 'skip=false\n')
            with patch.dict('os.environ', {**env, 'GITHUB_EVENT_NAME': 'push'}), \
                 patch('nightly_coverage.has_coverage', side_effect=AssertionError):
                main()
            self.assertEqual(Path(output).read_text(), 'skip=false\nskip=false\n')

class WorkflowWiringTests(unittest.TestCase):
    def test_every_pr_native_job_is_gated_and_ready_event_is_enabled(self):
        import re
        root = Path(__file__).resolve().parents[3] / '.github/workflows'
        for name in ('sdk-m0.yml', 'runtime-m4.yml'):
            text = (root / name).read_text()
            self.assertIn('ready_for_review', text)
            self.assertIn('converted_to_draft', text)
            blocks = re.split(r'(?m)(?=^  [\w-]+:\s*$)', text)
            native = [block for block in blocks if re.search(
                r'^    runs-on: (?:xcode-27|macos-26)$', block, re.M)]
            self.assertTrue(native)
            for block in native:
                self.assertIn("github.event_name != 'pull_request' || !github.event.pull_request.draft", block)
        for name in ('sdk-m0.yml', 'runtime-m4.yml'):
            text = (root / name).read_text()
            self.assertIn('needs.nightly-coverage.outputs.skip', text)
            self.assertIn('python3 scripts/ci/nightly_coverage.py ' + name, text)

    def test_failed_coverage_job_cannot_pass_acceptance_gate(self):
        from changes import gate
        result = {'changes': {'result': 'success'}, 'runtime-native': {'result': 'success'},
                  'nightly-coverage': {'result': 'success'}}
        gate(result, {'runtime-native': True})
        result['nightly-coverage']['result'] = 'failure'
        with self.assertRaises(ValueError):
            gate(result, {'runtime-native': True})


if __name__ == '__main__':
    unittest.main()
