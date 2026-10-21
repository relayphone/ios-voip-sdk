#!/usr/bin/env python3
"""Offline controls for exact simulator OS/compiler qualification metadata."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import summarize


class EnvironmentQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cksim-environment-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        package = self.root / 'runtime-dist'
        (package / 'profiles').mkdir(parents=True)
        (package / 'CKSimRuntime.dylib').write_bytes(b'synthetic runtime')
        (package / 'profiles/ios-27.0.json').write_bytes(b'synthetic behavior profile')
        self.runtime = dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                            platform='iOS', version='26.5', buildversion='23F77', isAvailable=True)
        (self.root / 'runtimes.json').write_text(json.dumps(dict(runtimes=[self.runtime])))
        (self.root / 'compiler-version.txt').write_text('Xcode 26.3\nBuild version 17C100\n')
        self.manifest = dict(schemaVersion=1, profileID='ios-27.0', runID='synthetic', simulatorID='synthetic',
                             simulatorRuntimeID=self.runtime['identifier'], simulatorOSVersion='26.5',
                             simulatorOSBuildVersion='23F77', compilerXcodeVersion='26.3',
                             compilerXcodeBuildVersion='17C100',
                             runtimeSHA256=hashlib.sha256(b'synthetic runtime').hexdigest(),
                             profileSHA256=hashlib.sha256(b'synthetic behavior profile').hexdigest(),
                             probeSHA256=hashlib.sha256(b'synthetic probe').hexdigest())
        self.rows = [dict(event='launch', runID='synthetic', simulatorID='synthetic', injected=True),
                     dict(event='runtime.identity', version='0.1.0',
                          **{key: self.manifest[key] for key in ('runtimeSHA256', 'profileSHA256', 'probeSHA256')})]

    def qualify(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
        return summarize.build_identity(self.root, self.rows)

    def test_shipping_identity_rejects_missing_simulator_os_build(self):
        self.manifest.pop('simulatorOSBuildVersion')
        with self.assertRaisesRegex(ValueError, 'simulatorOSBuildVersion'):
            self.qualify()

    def test_shipping_identity_binds_each_os_and_compiler_field(self):
        for field in ('simulatorRuntimeID', 'simulatorOSVersion', 'simulatorOSBuildVersion',
                      'compilerXcodeVersion', 'compilerXcodeBuildVersion'):
            original = self.manifest[field]
            for replacement in (None, '', 'wrong', 27):
                with self.subTest(field=field, replacement=replacement):
                    self.manifest[field] = replacement
                    with self.assertRaises(ValueError):
                        self.qualify()
            self.manifest[field] = original

    def test_behavior_profile_os_and_compiler_remain_distinct(self):
        manifest = self.qualify()
        self.assertEqual(summarize.run_environment(self.root, manifest),
                         dict(behaviorProfileID='ios-27.0',
                              simulatorOS=dict(runtimeID='com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                                               version='26.5', buildVersion='23F77'),
                              compiler=dict(xcodeVersion='26.3', buildVersion='17C100')))

    def test_os_build_cannot_be_inferred_from_the_behavior_profile(self):
        self.manifest['simulatorOSVersion'] = '27.0'
        with self.assertRaisesRegex(ValueError, 'simulatorOSVersion'):
            self.qualify()

    def test_shipping_identity_requires_saved_runtime_and_compiler_sources(self):
        for filename in ('runtimes.json', 'compiler-version.txt'):
            path = self.root / filename
            original = path.read_text()
            with self.subTest(filename=filename):
                path.unlink()
                with self.assertRaises(OSError):
                    self.qualify()
                path.write_text('')
                with self.assertRaises(ValueError):
                    self.qualify()
                path.write_text(original)

    def test_shipping_identity_rejects_changed_saved_os_or_compiler_build(self):
        path = self.root / 'runtimes.json'
        runtime = dict(self.runtime, buildversion='23F78')
        path.write_text(json.dumps(dict(runtimes=[runtime])))
        with self.assertRaisesRegex(ValueError, 'simulatorOSBuildVersion'):
            self.qualify()
        path.write_text(json.dumps(dict(runtimes=[self.runtime])))
        (self.root / 'compiler-version.txt').write_text('Xcode 26.3\nBuild version 17C101\n')
        with self.assertRaisesRegex(ValueError, 'compilerXcodeBuildVersion'):
            self.qualify()

    def test_selected_runtime_must_be_available_unique_ios_with_version_and_build(self):
        for update in (dict(isAvailable=False), dict(platform='tvOS'), dict(version='invalid'),
                       dict(version=''), dict(buildversion=''), dict(buildversion=None)):
            with self.subTest(update=update):
                runtime = dict(self.runtime, **update)
                (self.root / 'runtimes.json').write_text(json.dumps(dict(runtimes=[runtime])))
                with self.assertRaises(ValueError):
                    self.qualify()
        (self.root / 'runtimes.json').write_text(json.dumps(dict(runtimes=[self.runtime, self.runtime])))
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            self.qualify()

    def test_runtime_selection_uses_available_ios_versions(self):
        document = dict(runtimes=[dict(self.runtime, version='26.2', identifier='older'),
                                  dict(self.runtime, version='26.5', identifier='latest'),
                                  dict(self.runtime, version='27.0', identifier='unavailable', isAvailable=False),
                                  dict(self.runtime, version='28.0', identifier='tvos', platform='tvOS')])
        self.assertEqual(summarize.selected_runtime(document)['identifier'], 'latest')
        self.assertEqual(summarize.selected_runtime(document, 'older')['version'], '26.2')
        with self.assertRaises(ValueError):
            summarize.selected_runtime(dict(runtimes=[]))

    def test_summary_marks_historical_evidence_without_current_os_qualification(self):
        fixture = Path(__file__).resolve().parent / 'fixtures/strict-v2'
        summary = summarize.validate(fixture)
        self.assertTrue(summary['success'])
        self.assertEqual(summary['qualification'], 'historical-replay')
        self.assertNotIn('environment', summary)


if __name__ == '__main__':
    unittest.main()
