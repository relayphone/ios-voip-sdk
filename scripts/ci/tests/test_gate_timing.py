import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class TimingGateTests(unittest.TestCase):
    def test_report_failure_preserves_the_original_gate_result(self):
        root = Path(__file__).resolve().parents[3]
        workflow = (root / '.github/workflows/sdk-m0.yml').read_text()
        section = workflow.split('      - name: Require every selected acceptance group\n', 1)[1]
        script = textwrap.dedent(section.split('        run: |\n', 1)[1].split('\n  legacy-audio-lifecycle:', 1)[0])
        with tempfile.TemporaryDirectory(prefix='ci-gate-timing-') as temporary:
            temp = Path(temporary)
            bounded = temp / 'scripts/ci/bounded'
            bounded.parent.mkdir(parents=True)
            bounded.write_text('#!/bin/sh\nif [ "$2" = python3 ] && [ "$3" = scripts/ci/changes.py ]; then exit "$GATE_RESULT"; fi\nexit 1\n')
            bounded.chmod(0o755)
            for status in (0, 7):
                summary = temp / 'summary.md'
                summary.write_text('')
                env = {**os.environ, 'GATE_RESULT': str(status), 'GITHUB_STEP_SUMMARY': str(summary),
                       'RUNNER_TEMP': str(temp), 'GITHUB_REPOSITORY': 'test/repo',
                       'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}
                result = subprocess.run(['/bin/bash', '-e', '-c', script], cwd=temp, env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn('timing report unavailable', summary.read_text())


if __name__ == '__main__': unittest.main()
