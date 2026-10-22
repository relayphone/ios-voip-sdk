#!/usr/bin/env python3
"""Source/package and actual Mach-O negative controls; never runs an iOS app."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from device_release_exclusion import ExclusionError, inspect_binary, inspect_public_headers

ROOT = Path(__file__).resolve().parent.parent


def embedded_profile(source):
    match = re.search(r'private static let embeddedProfileJSON = #"""\n(.*?)\n"""#', source, re.S)
    if not match:
        raise ValueError('missing guarded simulator profile')
    return json.loads(match[1])


class Controls(unittest.TestCase):
    def test_profile_drift(self):
        source = (ROOT / 'Sources/Engine/RuntimeEngine.swift').read_text()
        canonical = json.loads((ROOT / 'Sources/Engine/Resources/ios-27.0.json').read_text())
        self.assertEqual(embedded_profile(source), canonical)
        tampered = source.replace('"ringTimeoutSeconds": 60.1', '"ringTimeoutSeconds": 99', 1)
        self.assertNotEqual(embedded_profile(tampered), canonical)
        self.assertTrue(source.startswith('#if os(iOS) && targetEnvironment(simulator)\n'))

    def test_actual_package_declarations(self):
        pod = subprocess.run(['pod', 'ipc', 'spec', 'IosVoipSDK.podspec'], cwd=ROOT,
                             capture_output=True, text=True, timeout=30, check=True)
        spec = json.loads(pod.stdout)
        self.assertNotIn('CallKit', spec['frameworks'])
        self.assertFalse(spec.get('resource_bundles'))
        self.assertNotIn('Sources/Interposition/CKRuntimeSeam.h', spec['public_header_files'])
        package = subprocess.run(['swift', 'package', 'dump-package'], cwd=ROOT,
                                 capture_output=True, text=True, timeout=60, check=True)
        targets = {target['name']: target for target in json.loads(package.stdout)['targets']}
        self.assertFalse(targets['CKSimRuntime'].get('resources'))
        self.assertIn('Resources', targets['CKSimRuntime']['exclude'])
        self.assertEqual(targets['CKSimRuntimeC']['publicHeadersPath'], 'include')

    def test_public_hooks_negative(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Bridge.h'
            path.write_text('void harmless(void);\n')
            inspect_public_headers(Path(directory))
            for marker in ('CKSimInjectPush', 'CKSimEmit'):
                path.write_text('void ' + marker + '(void);\n')
                with self.assertRaisesRegex(ExclusionError, 'public simulator test hook'):
                    inspect_public_headers(Path(directory))

    def test_actual_macho_negative_controls(self):
        with tempfile.TemporaryDirectory(prefix='sdk-release-exclusion-') as directory:
            out = Path(directory)
            code = out / 'main.c'
            code.write_text('int main(void) { return 0; }\n')
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
            for name, extra in [('clean', []), ('callkit', ['-framework', 'CallKit'])]:
                subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
                                str(code), '-o', str(out / name), *extra], capture_output=True,
                               text=True, timeout=30, check=True)
            inspect_binary(out / 'clean')
            with self.assertRaisesRegex(ExclusionError, 'direct CallKit load command'):
                inspect_binary(out / 'callkit')
            # Preserve a real Mach-O's load commands while introducing a leaked
            # implementation marker, exercising the binary gate independently.
            (out / 'leaked').write_bytes((out / 'clean').read_bytes() + b'CKSimInjectPush')
            with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                inspect_binary(out / 'leaked')


if __name__ == '__main__':
    unittest.main()
