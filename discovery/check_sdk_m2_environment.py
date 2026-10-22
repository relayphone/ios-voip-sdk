#!/usr/bin/env python3
"""Synthetic host preflight controls; no native environment or simulator claim."""
import copy
import json
import subprocess
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


if __name__ == '__main__':
    unittest.main()
