import importlib.util
import unittest
import json
import os
import subprocess
import tempfile
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / 'runtime_failure_summary.py'
spec = importlib.util.spec_from_file_location('runtime_failure_summary', PATH)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class RuntimeFailureSummary(unittest.TestCase):
    def test_failed_watch_and_cleanup_show_only_terminal_safe_labels(self):
        result = summary.render({'watch': 'failure', 'cleanup': 'failure'}, {
            'watch': '- `infra:install`: scheduled (one pre-app retry)\n'
                     '- `infra:install`: recovered\n'
                     '- `infra:inventory`: exhausted\nsecret command and args\n',
            'cleanup': '- `infra:delete`: not eligible\n'})
        self.assertIn('Consume the shared channel through watch: observed infrastructure labels: `infra:inventory`', result)
        self.assertIn('Delete the owned simulator: observed infrastructure labels: `infra:delete`', result)
        self.assertNotIn('infra:install', result)
        self.assertNotIn('secret', result)

    def test_inventory_retry_recovered_before_later_launch_failure(self):
        result = summary.render({'watch': 'failure'}, {'watch':
            '- `infra:inventory`: timeout after 180s; scheduled one bounded re-attempt\n'
            '- `infra:inventory`: recovered within 180s inventory bound\n'
            '- `infra:launch`: transport failed; never retried\n'})
        self.assertNotIn('infra:inventory', result)
        self.assertIn('`infra:launch`', result)

    def test_other_label_with_similar_text_remains_visible(self):
        result = summary.render({'watch': 'failure'}, {'watch':
            '- `infra:launch`: timeout after 180s; scheduled one bounded re-attempt\n'})
        self.assertIn('`infra:launch`', result)

    def test_inventory_retry_exhaustion_is_still_reported(self):
        result = summary.render({'watch': 'failure'}, {'watch':
            '- `infra:inventory`: timeout after 180s; scheduled one bounded re-attempt\n'
            '- `infra:inventory`: timeout after 180s; inventory re-attempt exhausted\n'})
        self.assertIn('`infra:inventory`', result)

    def test_recovery_does_not_hide_an_independent_terminal_failure(self):
        result = summary.render({'watch': 'failure'}, {'watch':
            '- `infra:inventory`: not eligible\n'
            '- `infra:inventory`: recovered within 180s inventory bound\n'})
        self.assertIn('`infra:inventory`', result)

    def test_success_and_skipped_phases_do_not_report_recovered_failures(self):
        result = summary.render({'watch': 'success', 'inspector': 'skipped'}, {
            'watch': '- `infra:list`: recovered\n'})
        self.assertIn('No tracked Runtime phase failure or cancellation was recorded.', result)
        self.assertNotIn('infra:list', result)

    def test_missing_or_malformed_receipt_is_unclassified(self):
        result = summary.render({'build': 'failure', 'watch': 'failure'}, {
            'watch': '- `infra:bad label`: not eligible\n'
                     '- `infra:list`: scheduled\n- `infra:list`: recovered\n'})
        self.assertIn('Build simulator runtime and event fixture: no infrastructure label recorded', result)
        self.assertIn('Consume the shared channel through watch: no infrastructure label recorded', result)
        self.assertNotIn('bad label', result)

    def test_repeated_terminal_label_is_deduplicated_and_details_are_private(self):
        result = summary.render({'watch': 'failure'}, {'watch':
            '- `infra:list`: not eligible with secret device\n'
            '- `infra:list`: exhausted\n'})
        self.assertEqual(result.count('`infra:list`'), 1)
        self.assertNotIn('secret', result)


    def test_cancelled_phase_is_not_reported_as_clean(self):
        result = summary.render({'watch': 'cancelled'}, {})
        self.assertIn('Consume the shared channel through watch: cancelled', result)
        self.assertNotIn('No tracked Runtime phase', result)

    def test_workflow_wires_every_phase_and_preserves_failed_step_status(self):
        workflow = PATH.parents[2] / '.github/workflows/runtime-m4.yml'
        text = workflow.read_text()
        for key, name in summary.PHASES:
            self.assertIn('- name: ' + name + '\n        id: ' + key, text)
            self.assertIn('steps.' + key + '.outcome', text)
        upload = text.split('- name: Upload Runtime failure summary', 1)[1].split('      - ', 1)[0]
        self.assertIn('continue-on-error: true', upload)
        for key in ('create', 'watch', 'lck', 'inspector', 'cleanup'):
            self.assertIn('runtime-phase-' + key + '.md', text)
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, RUNNER_TEMP=tmp, GITHUB_STEP_SUMMARY=tmp + '/original')
            shell = ('runtime_original_summary="$GITHUB_STEP_SUMMARY"; '
                     'export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/runtime-phase-watch.md"; '
                     "trap 'if [ -f \"$GITHUB_STEP_SUMMARY\" ]; then cat \"$GITHUB_STEP_SUMMARY\" >> \"$runtime_original_summary\" || :; fi' EXIT; "
                     "printf '%s\\n' '- `infra:list`: not eligible' > \"$GITHUB_STEP_SUMMARY\"; exit 73")
            result = subprocess.run(['bash', '-e', '-c', shell], env=env)
            self.assertEqual(result.returncode, 73)
            self.assertEqual((Path(tmp) / 'original').read_text(),
                             (Path(tmp) / 'runtime-phase-watch.md').read_text())
            env['RUNTIME_PHASE_OUTCOMES'] = json.dumps({'watch': 'failure'})
            env['GITHUB_STEP_SUMMARY'] = tmp + '/final'
            subprocess.run(['python3', str(PATH)], env=env, check=True, capture_output=True)
            report = (Path(tmp) / 'runtime-failure-summary.md').read_text()
            self.assertIn('Consume the shared channel through watch: observed infrastructure labels: `infra:list`', report)
            self.assertEqual(report, (Path(tmp) / 'final').read_text())


if __name__ == '__main__':
    unittest.main()
