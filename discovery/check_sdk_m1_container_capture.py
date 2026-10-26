#!/usr/bin/env python3
"""Host-only synthetic control for M1 journal capture; no native acceptance claim."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


RUNNER = Path(__file__).with_name('run_sdk_m0.sh')
CASES = ('journey', 'cold-launch', 'unhandled-expiry')
RUN_ID = 'host-synthetic-m1-capture'
SIMULATOR = 'host-synthetic-simulator'
LABEL = 'host-only synthetic fixture; never native acceptance'


def capture_block():
    source = RUNNER.read_text()
    end = source.index('  mkdir "$OUT/m1/contracts"\n')
    # The earlier acceptance preflight uses the same exact opening line.
    start = source.rindex('if [[ "${SDK_M1_ACCEPTANCE:-0}" == 1 ]]; then\n', 0, end)
    return source[start:end] + 'fi\n'


def journal_bytes(case):
    return (json.dumps(dict(fixture=LABEL, case=case), sort_keys=True) + '\n').encode()


SCENARIO_STUB = r'''
import json, os, pathlib, sys
args = sys.argv[1:]
def option(name): return args[args.index(name) + 1]
case = os.environ['SIMCTL_CHILD_SDK_M1_CASE']
assert case in ('journey', 'cold-launch', 'unhandled-expiry')
assert option('--scenario') == 'sdk-m1-' + case
assert option('--bundle-id') == 'dev.iosvoipsdk.example'
assert option('--run-id') == os.environ['RUN_ID']
assert option('--simulator-id') == os.environ['UDID']
assert option('--timeout') == ('120' if case == 'journey' else '90')
assert args[args.index('--terminate-command') + 1:args.index('--launch-command')] == [
    'xcrun', 'simctl', 'terminate', os.environ['UDID'], 'dev.iosvoipsdk.example']
assert args[args.index('--launch-command') + 1:] == [
    'xcrun', 'simctl', 'launch', '--console', '--terminate-running-process',
    os.environ['UDID'], 'dev.iosvoipsdk.example']
with open(os.environ['FIXTURE_CASES'], 'a') as stream: stream.write(case + '\n')
label = 'host-only synthetic fixture; never native acceptance'
pathlib.Path(option('--output')).write_text(label + ': ' + case + '\n')
receipt = pathlib.Path(option('--receipt'))
receipt.write_text('invalid synthetic receipt' if os.environ['FIXTURE_MODE'] == 'bad-receipt'
    else json.dumps(dict(fixture=label, case=case, journalSHA256='not-captured-yet')) + '\n')
journal = pathlib.Path(os.environ['FIXTURE_CONTAINER']) / 'Documents/.callkit-simulator' / os.environ['RUN_ID'] / 'events.jsonl'
if os.environ['FIXTURE_MODE'] != 'missing-journal':
    journal.parent.mkdir(parents=True, exist_ok=True)
    journal.write_text(json.dumps(dict(fixture=label, case=case), sort_keys=True) + '\n')
'''


PATH_STUB = r'''
import json, os, pathlib, sys
expected = ['--receipt', str(pathlib.Path(os.environ['OUT']) / 'm1/sdk-m1-journey.receipt.json'),
    '--trace', str(pathlib.Path(os.environ['OUT']) / 'm1/sdk-m1-journey.log'),
    '--simulator', os.environ['UDID'], '--run-id', os.environ['RUN_ID'], '--bundle', 'dev.iosvoipsdk.example']
with open(os.environ['FIXTURE_QUERIES'], 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\n')
assert sys.argv[1:] == expected, 'only the completed owned capture can resolve a container'
assert pathlib.Path(os.environ['FIXTURE_QUERIES']).read_text().count('\n') == 1, 'repeated container resolution'
mode = os.environ['FIXTURE_MODE']
if mode == 'lookup-fails': sys.exit(73)
if mode == 'empty': print('')
elif mode == 'not-directory': print(os.environ['FIXTURE_NON_DIRECTORY'])
else: print(os.environ['FIXTURE_CONTAINER'])
'''



class ContainerCaptureControls(unittest.TestCase):
    def run_capture(self, mode, check):
        with tempfile.TemporaryDirectory(prefix='sdk-m1-host-capture-') as temporary:
            root = Path(temporary)
            (root / 'discovery').mkdir()
            (root / 'discovery/run_scenario.py').write_text(textwrap.dedent(SCENARIO_STUB))
            binary = root / 'bin'
            binary.mkdir()
            # Keep real copy/hash operations; the helper has its own binding controls.
            (binary / 'python3').symlink_to(sys.executable)
            helper = root / 'scripts/sim/paths.py'
            helper.parent.mkdir(parents=True)
            helper.write_text(textwrap.dedent(PATH_STUB))
            container = root / 'mock data container'
            container.mkdir()
            non_directory = root / 'not a data container'
            non_directory.write_text(LABEL + '\n')
            output = root / 'evidence with spaces'
            output.mkdir()
            cases = root / 'cases.txt'
            queries = root / 'queries.jsonl'
            environment = dict(os.environ, PATH=str(binary) + ':/usr/bin:/bin',
                SDK_M1_ACCEPTANCE='1', OUT=str(output), INHERITED_DYLD='',
                RUN_ID=RUN_ID, UDID=SIMULATOR, FIXTURE_MODE=mode,
                FIXTURE_CONTAINER=str(container), FIXTURE_NON_DIRECTORY=str(non_directory),
                FIXTURE_CASES=str(cases), FIXTURE_QUERIES=str(queries))
            # Only the real block is under test. No setup, app installation, or
            # contract loop from the native runner is executed by this fixture.
            # Trace actual copy attempts without replacing the real cp command.
            harness = "set -euo pipefail\nPS4='+ '\nset -x\n" + \
                'limit() { [[ "$1" == 30 ]] || return 74; shift; "$@"; }\n' + capture_block()
            result = subprocess.run(['/bin/bash', '-c', harness], cwd=root, env=environment,
                capture_output=True, text=True, timeout=15)
            observed_cases = cases.read_text().splitlines() if cases.exists() else []
            observed_queries = [json.loads(line) for line in queries.read_text().splitlines()] if queries.exists() else []
            self.assertEqual(len(observed_queries), 1, result.stderr)
            check(result, output / 'm1', observed_cases)

    def test_one_bound_lookup_captures_three_distinct_journals_and_receipt_hashes(self):
        def check(result, output, observed_cases):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(observed_cases, list(CASES))
            self.assertEqual(sum(line.startswith('+ cp ') for line in result.stderr.splitlines()), 3)
            captured = []
            for case in CASES:
                name = 'sdk-m1-' + case
                journal = (output / (name + '.runtime.jsonl')).read_bytes()
                self.assertEqual(journal, journal_bytes(case))
                captured.append(journal)
                receipt = json.loads((output / (name + '.receipt.json')).read_text())
                self.assertEqual(receipt, dict(fixture=LABEL, case=case,
                    journalSHA256=hashlib.sha256(journal).hexdigest()))
            self.assertEqual(len(set(captured)), 3)
        self.run_capture('success', check)

    def test_invalid_initial_container_refuses_before_copy_or_later_cases(self):
        for mode in ('lookup-fails', 'empty', 'not-directory'):
            with self.subTest(mode=mode):
                def check(result, output, observed_cases):
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(observed_cases, ['journey'])
                    self.assertFalse(any(line.startswith('+ cp ') for line in result.stderr.splitlines()))
                    self.assertEqual(list(output.glob('*.runtime.jsonl')), [])
                    receipt = json.loads((output / 'sdk-m1-journey.receipt.json').read_text())
                    self.assertEqual(receipt['journalSHA256'], 'not-captured-yet')
                self.run_capture(mode, check)

    def test_missing_journal_refuses_before_later_cases(self):
        def check(result, output, observed_cases):
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(observed_cases, ['journey'])
            self.assertEqual(list(output.glob('*.runtime.jsonl')), [])
        self.run_capture('missing-journal', check)

    def test_invalid_receipt_refuses_before_later_cases(self):
        def check(result, output, observed_cases):
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(observed_cases, ['journey'])
            self.assertEqual((output / 'sdk-m1-journey.runtime.jsonl').read_bytes(), journal_bytes('journey'))
            self.assertFalse((output / 'sdk-m1-cold-launch.receipt.json').exists())
        self.run_capture('bad-receipt', check)


if __name__ == '__main__':
    unittest.main()
