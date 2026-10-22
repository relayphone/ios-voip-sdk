#!/usr/bin/env python3
"""Synthetic host preflight controls; no native environment or simulator claim."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

from sdk_m2_environment import COMMANDS, inspect


class EnvironmentControls(unittest.TestCase):
    def setUp(self):
        self.environment = dict(ImageOS='actual-image-label', ImageVersion='actual-image-version',
                                RUNNER_ARCH='ARM64')
        self.output = dict(macOS='ProductName:\tmacOS\nProductVersion:\t27.0.1\nBuildVersion:\t26A434\n',
            architecture='arm64\n', xcode='Xcode 27.1\nBuild version 27A9275\n',
            simulatorSDKVersion='27.1\n', simulatorSDKBuild='24B78\n', simulatorSDKPath='/Applications/Xcode_27.1.app/SDK\n')
        self.runtime = dict(platform='iOS', name='iOS 27.0', version='27.0', buildversion='24A434',
                            identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', isAvailable=True)
        self.runtimes = [self.runtime]
        self.calls = []

    def execute(self, args, **options):
        self.calls.append((args, options))
        name = next(key for key, command in COMMANDS.items() if command == args)
        output = json.dumps(dict(runtimes=self.runtimes)) if name == 'runtimes' else self.output[name]
        return SimpleNamespace(returncode=0, stdout=output, stderr='')

    def inspect(self, **changes):
        options = dict(runtime='iOS 27.0', audio_path='modern', xcode_version='27.1', xcode_build='27A9275',
                       execute=self.execute, environment=self.environment)
        options.update(changes)
        return inspect(**options)

    def test_records_actual_environment_and_selected_identity(self):
        result = self.inspect()
        self.assertTrue(result['success'], result['errors'])
        self.assertEqual(result['runner']['ImageOS'], 'actual-image-label')
        self.assertEqual(result['selectedRuntime'], self.runtime)
        self.assertEqual(len(self.calls), len(COMMANDS))
        self.assertTrue(all(options['timeout'] == 30 for _, options in self.calls))
        self.assertEqual(self.calls[-1][0], ['xcrun', 'simctl', 'list', 'runtimes', '--json'])
        self.assertEqual(result['commands']['xcode']['stdout'], self.output['xcode'])
        self.assertEqual(len(result['sourceSHA256']), 64)

    def test_identifier_selection_and_legacy_lane(self):
        self.assertTrue(self.inspect(runtime=self.runtime['identifier'])['success'])
        self.runtime.update(name='iOS 26.5', version='26.5', identifier='runtime-ios-26-5')
        self.output['xcode'] = 'Xcode 26.6\nBuild version 17F123\n'
        self.assertTrue(self.inspect(runtime='iOS 26.5', audio_path='legacy',
                                     xcode_version='26.6', xcode_build=None)['success'])

    def test_wrong_architecture_and_xcode_are_rejected(self):
        for field, replacement in [('architecture', 'x86_64\n'), ('xcode', 'Xcode 27.0\nBuild version 27A9275\n'),
                                   ('xcode', 'Xcode 27.1\nBuild version wrong\n')]:
            before = self.output[field]
            self.output[field] = replacement
            self.assertFalse(self.inspect()['success'])
            self.output[field] = before
        self.environment['RUNNER_ARCH'] = 'X64'
        self.assertFalse(self.inspect()['success'])

    def test_missing_ambiguous_unavailable_or_incomplete_runtime_is_rejected(self):
        self.runtimes = []
        self.assertFalse(self.inspect()['success'])
        self.runtimes = [self.runtime, copy.deepcopy(self.runtime)]
        self.assertFalse(self.inspect()['success'])
        self.runtimes = [self.runtime]
        self.runtime['isAvailable'] = False
        self.assertFalse(self.inspect()['success'])
        self.runtime['isAvailable'] = True
        self.runtime['buildversion'] = ''
        self.assertFalse(self.inspect()['success'])

    def test_audio_path_mismatch_and_empty_identity_are_rejected(self):
        self.assertFalse(self.inspect(audio_path='legacy')['success'])
        self.output['simulatorSDKBuild'] = ''
        self.assertFalse(self.inspect()['success'])

    def test_failed_or_timed_out_command_remains_failed(self):
        def failed(args, **options):
            return SimpleNamespace(returncode=1, stdout='', stderr='unavailable')
        result = self.inspect(execute=failed)
        self.assertFalse(result['success'])
        self.assertEqual(len(result['errors']), len(COMMANDS))
        def timed_out(args, **options):
            raise subprocess.TimeoutExpired(args, 30)
        result = self.inspect(execute=timed_out)
        self.assertFalse(result['success'])
        self.assertEqual(result['commands']['runtimes']['error'], 'TimeoutExpired')


class WorkflowShellControls(unittest.TestCase):
    """Run the actual YAML step under macOS Bash 3.2; stub only its Python command."""

    @classmethod
    def setUpClass(cls):
        workflow = Path(__file__).resolve().parent.parent / '.github/workflows/sdk-m2.yml'
        # Psych is Ruby's bundled YAML parser; no Python dependency is installed.
        script = '''require 'json'; require 'yaml'
job = YAML.load_file(ARGV[0]).fetch('jobs').fetch('selected-livekit')
steps = job.fetch('steps').select { |step| step['name'] == 'Record and verify the assigned host and requested runtime' }
abort 'missing or duplicate preflight step' unless steps.length == 1
puts JSON.generate({'matrix' => job.fetch('strategy').fetch('matrix').fetch('include'), 'run' => steps.first.fetch('run')})
'''
        loaded = subprocess.run(['ruby', '-e', script, str(workflow)], capture_output=True, text=True, timeout=10, check=True)
        cls.workflow = json.loads(loaded.stdout)
        version = subprocess.run(['/bin/bash', '--version'], capture_output=True, text=True, timeout=10, check=True).stdout
        if not version.startswith('GNU bash, version 3.2.'):
            raise RuntimeError('workflow compatibility controls require macOS /bin/bash 3.2')

    def check_lane(self, path):
        lanes = [lane for lane in self.workflow['matrix'] if lane['audio-path'] == path]
        self.assertEqual(len(lanes), 1)
        lane, script = lanes[0], self.workflow['run']
        for key, value in lane.items():
            script = script.replace('${{ matrix.' + key + ' }}', value)
        self.assertNotIn('${{', script)
        self.assertIn('set -euo pipefail', script)
        with tempfile.TemporaryDirectory(prefix='ios-voip-m2-bash-') as directory:
            capture = Path(directory) / 'arguments'
            runner_temp = Path(directory) / 'runner temp with spaces'
            stub = 'python3() { printf "%s\\0" "$@" > "$ARGUMENT_CAPTURE"; }\n'
            result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail'],
                input=stub + script, capture_output=True, text=True, timeout=10,
                env=dict(PATH=os.defpath, RUNNER_TEMP=str(runner_temp), ARGUMENT_CAPTURE=str(capture),
                         M2_XCODE_BUILD=lane['xcode-build']))
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = capture.read_bytes().split(b'\0')
            self.assertEqual(arguments.pop(), b'')
            self.assertEqual(arguments.pop(0), b'discovery/sdk_m2_environment.py')
            self.assertEqual(len(arguments) % 2, 0)
            flags = [value.decode() for value in arguments[::2]]
            self.assertEqual(len(flags), len(set(flags)))
            expected = {'--runtime': lane['runtime'], '--audio-path': path, '--xcode-version': lane['xcode'],
                        '--output': str(runner_temp / 'sdk-m2-environment-preflight.json')}
            if lane['xcode-build']: expected['--xcode-build'] = lane['xcode-build']
            self.assertEqual(dict(zip(flags, [value.decode() for value in arguments[1::2]])), expected)

    def test_legacy_step_accepts_empty_optional_xcode_build(self):
        self.check_lane('legacy')

    def test_modern_step_preserves_pinned_optional_xcode_build(self):
        self.check_lane('modern')


if __name__ == '__main__':
    unittest.main()
