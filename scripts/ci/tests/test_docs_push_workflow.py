"""Exercise a real docs-only push against the native workflow job guards."""
import re
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
from changes import SDK_JOBS, SDK_NATIVE_JOBS, event_selection, gate


def job_blocks(path):
    body = path.read_text().split('\njobs:\n', 1)[1]
    blocks, current = {}, None
    for line in body.splitlines(keepends=True):
        match = re.fullmatch(r'  ([A-Za-z_][\w-]*):\s*(?:#[^\n]*)?\n?', line)
        if match:
            current = match.group(1)
            blocks[current] = line
        elif current:
            blocks[current] += line
    return blocks


class DocsPushWorkflowTests(unittest.TestCase):
    def test_docs_push_keeps_host_controls_and_skips_every_native_job(self):
        with tempfile.TemporaryDirectory(prefix='ci-docs-push-') as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null',
                    '-c', 'commit.gpgsign=false', '-c', 'user.name=CI Fixture',
                    '-c', 'user.email=fixture@example.invalid', *args], cwd=root,
                    text=True, capture_output=True, check=True, timeout=10).stdout.strip()
            git('init')
            (root / 'README.md').write_text('before\n')
            git('add', '.')
            git('commit', '-m', 'base')
            before = git('rev-parse', 'HEAD')
            (root / 'README.md').write_text('after\n')
            git('add', '.')
            git('commit', '-m', 'docs')
            after = git('rev-parse', 'HEAD')
            plan = event_selection('push', {'before': before, 'after': after}, root)

        self.assertFalse(plan['sdk'])
        self.assertFalse(plan['runtime'])
        self.assertTrue(plan['helper'])
        self.assertFalse(any(plan['sdk_plan'].values()))

        reusable = (ROOT / '.github/workflows/ci-changes.yml').read_text()
        for flag in ('sdk', 'runtime', 'helper', 'sdk_plan', 'runtime_plan'):
            with self.subTest(output=flag):
                self.assertRegex(reusable, r'(?m)^      ' + flag + r':\n        value: \$\{\{ jobs\.detect\.outputs\.' + flag + r' \}\}$')
                self.assertRegex(reusable, r'(?m)^      ' + flag + r': \$\{\{ steps\.select\.outputs\.' + flag + r' \}\}$')
        self.assertIn('id: select', reusable)
        self.assertIn('python3 scripts/ci/changes.py', reusable)
        for filename in ('sdk-m0.yml', 'runtime-m4.yml', 'sim-infrastructure.yml'):
            with self.subTest(workflow=filename):
                blocks = job_blocks(ROOT / '.github/workflows' / filename)
                self.assertIn('uses: ./.github/workflows/ci-changes.yml', blocks['changes'])

        sdk = job_blocks(ROOT / '.github/workflows/sdk-m0.yml')
        expected_native = set(SDK_NATIVE_JOBS) | (set(SDK_JOBS) - {'sdk-native'})
        actual_native = {name for name, block in sdk.items()
                         if re.search(r'^    runs-on: (?:xcode-27|macos-26)\s*$', block, re.M)}
        self.assertEqual(actual_native, expected_native - {'offline-controls'})
        self.assertIn('runs-on: ubuntu-latest', sdk['offline-controls'])
        for name in expected_native:
            with self.subTest(job=name):
                self.assertIn("needs.changes.outputs.sdk == 'true'", sdk[name])
                if name != 'offline-controls':
                    self.assertIn("needs.nightly-coverage.outputs.skip != 'true'", sdk[name])
                    self.assertIn("!github.event.pull_request.draft", sdk[name])
                self.assertRegex(sdk[name], r'(?m)^    needs: (?:\[[^\n]*\bchanges\b[^\n]*\]|changes)\s*$')

        aggregate = sdk['plain-simulator']
        self.assertIn('if: always()', aggregate)
        needs = re.search(r'(?m)^    needs: \[([^\]]+)\]$', aggregate)
        self.assertIsNotNone(needs)
        self.assertEqual({value.strip() for value in needs.group(1).split(',')},
                         expected_native | {'changes', 'nightly-coverage'})
        self.assertIn('CI_NEEDS_JSON: ${{ toJSON(needs) }}', aggregate)
        self.assertIn('CI_EXPECTED_JSON: ${{ needs.changes.outputs.sdk_plan }}', aggregate)
        self.assertRegex(aggregate, r'python3 scripts/ci/changes\.py gate(?:;|\s|$)')
        results = {'changes': {'result': 'success'},
                   **{name: {'result': 'skipped'} for name in expected_native}}
        gate(results, plan['sdk_plan'])
        runtime = job_blocks(ROOT / '.github/workflows/runtime-m4.yml')
        runtime_native = {name for name, block in runtime.items()
                          if re.search(r'^    runs-on: (?:xcode-27|macos-26)\s*$', block, re.M)}
        self.assertEqual(runtime_native, {'runtime-native'})
        self.assertIn('needs: [changes, nightly-coverage]', runtime['runtime-native'])
        self.assertIn("needs.changes.outputs.runtime == 'true'", runtime['runtime-native'])
        self.assertIn("!github.event.pull_request.draft", runtime['runtime-native'])
        runtime_gate = runtime['runtime-events']
        self.assertIn('if: always()', runtime_gate)
        self.assertRegex(runtime_gate, r'(?m)^    needs: \[changes, nightly-coverage, runtime-native\]$')
        self.assertIn('CI_NEEDS_JSON: ${{ toJSON(needs) }}', runtime_gate)
        self.assertIn('CI_EXPECTED_JSON: ${{ needs.changes.outputs.runtime_plan }}', runtime_gate)
        self.assertRegex(runtime_gate, r'python3 scripts/ci/changes\.py gate(?:;|\s|$)')
        gate({'changes': {'result': 'success'}, 'runtime-native': {'result': 'skipped'}},
             {'runtime-native': plan['runtime']})
        helper = job_blocks(ROOT / '.github/workflows/sim-infrastructure.yml')
        self.assertRegex(helper['helper-controls'], r"(?m)^    if: needs\.changes\.outputs\.helper == 'true'$")
        self.assertIn('runs-on: ubuntu-latest', helper['helper-controls'])


if __name__ == '__main__': unittest.main()
