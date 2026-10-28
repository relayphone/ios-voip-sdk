import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
WRAPPER = ROOT / 'scripts/ci/pod_install.sh'


class PodInstallRetryTests(unittest.TestCase):
    def run_pod(self, first, second='ok'):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            pod = folder / 'pod'
            pod.write_text('''#!/bin/bash
count=0
[[ ! -f "$POD_CALLS" ]] || count=$(cat "$POD_CALLS")
count=$((count + 1))
printf '%s' "$count" > "$POD_CALLS"
if [[ $count == 1 ]]; then behavior=$POD_FIRST; else behavior=$POD_SECOND; fi
printf '%s\\n' "$*" >> "$POD_ARGS"
case "$behavior" in
  network) printf '%s\\n' '[!] /usr/bin/curl https://repo.reactnative.dev/maven2/file.tgz' 'curl: (16) Error in the HTTP2 framing layer'; exit 7 ;;
  rn) printf '%s\\n' '[ReactNativeDependencies] Failed to download tarball from https://repo.reactnative.dev/maven2/file.tgz'; exit 3 ;;
  interrupted) printf '%s\\n' '[!] /usr/bin/curl https://repo.reactnative.dev/maven2/file.tgz' 'curl: (56) connection reset'; kill -TERM $$ ;;
  other) printf '%s\\n' '[!] Invalid Podfile'; exit 9 ;;
  foreign) printf '%s\\n' '[ReactNativeDependencies] Using https://repo.reactnative.dev/maven2/file.tgz' '[!] /usr/bin/curl https://example.org/file.tgz' 'curl: (56) connection reset'; exit 8 ;;
  ok) echo installed ;;
esac
''')
            pod.chmod(0o755)
            env = dict(os.environ, PATH=f'{folder}:' + os.environ['PATH'],
                       POD_CALLS=str(folder / 'calls'), POD_ARGS=str(folder / 'args'),
                       POD_FIRST=first, POD_SECOND=second,
                       GITHUB_STEP_SUMMARY=str(folder / 'summary'))
            result = subprocess.run([str(WRAPPER), '--no-repo-update'], cwd=folder, env=env,
                                    text=True, capture_output=True, timeout=30)
            summary = (folder / 'summary').read_text() if (folder / 'summary').exists() else ''
            return result, (folder / 'calls').read_text(), (folder / 'args').read_text(), summary

    def test_network_failure_retries_once_and_preserves_arguments(self):
        for kind in ('network', 'rn'):
            with self.subTest(kind=kind):
                result, calls, args, summary = self.run_pod(kind)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(calls, '2')
                self.assertEqual(args.splitlines(), ['install --no-repo-update'] * 2)
                self.assertIn('infra:dependency-download', summary)
                self.assertIn('scheduled one bounded re-attempt', summary)

    def test_exhaustion_preserves_second_failure_status(self):
        result, calls, _, summary = self.run_pod('network', 'rn')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(calls, '2')
        self.assertIn('re-attempt exhausted', summary)

    def test_interruption_is_not_retried(self):
        result, calls, _, summary = self.run_pod('interrupted')
        self.assertEqual(result.returncode, 143)
        self.assertEqual(calls, '1')
        self.assertEqual(summary, '')

    def test_other_errors_are_not_retried_or_misclassified(self):
        for kind, status in (('other', 9), ('foreign', 8)):
            with self.subTest(kind=kind):
                result, calls, _, summary = self.run_pod(kind)
                self.assertEqual(result.returncode, status)
                self.assertEqual(calls, '1')
                self.assertEqual(summary, '')

class CacheWiringTests(unittest.TestCase):
    def test_all_pod_jobs_use_versioned_cache_and_retry_wrapper(self):
        import re
        workflow = (ROOT / '.github/workflows/sdk-m0.yml').read_text()
        blocks = re.split(r'(?m)(?=^  [\w-]+:\s*$)', workflow)
        pods = [block for block in blocks if 'scripts/ci/pod_install.sh' in block]
        self.assertEqual(len(pods), 3)
        for block in pods:
            self.assertIn('uses: ./.github/actions/cache-native-dependencies', block)
            self.assertNotRegex(block, r'(?m)^\s*(?:\(cd example/ios && )?pod install')
        action = (ROOT / '.github/actions/cache-native-dependencies/action.yml').read_text()
        for value in ('node_modules/react-native', 'node_modules/hermes-compiler',
                      'steps.versions.outputs.rn', 'steps.versions.outputs.hermes',
                      "hashFiles('package-lock.json')", '~/Library/Caches/ReactNative',
                      '~/Library/Caches/CocoaPods'):
            self.assertIn(value, action)


if __name__ == '__main__':
    unittest.main()
