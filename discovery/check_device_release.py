#!/usr/bin/env python3
"""Source/package and actual Mach-O negative controls; never runs an iOS app."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from device_release_exclusion import ExclusionError, inspect_binary, inspect_public_headers

ROOT = Path(__file__).resolve().parent.parent


def embedded_profile(source):
    match = re.search(r'private static let embeddedProfileJSON = #"""\n(.*?)\n"""#', source, re.S)
    if not match:
        raise ValueError('missing guarded simulator profile')
    return json.loads(match[1])


class InspectionControls(unittest.TestCase):
    """Policy controls only; all native tools are explicit mocks."""

    def test_binary_inspection_preserves_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'binary'
            binary.write_bytes(b'native-tool-output-fixture')
            for marker in ('CKSimInjectPush', 'CKSimEmit', 'CKSimPrepareEngine', 'CKSimActivateRuntime',
                           'CKSimMakeCall', 'RuntimeEngine', 'RuntimeBootstrap', 'CXCallObserver', 'CXProvider'):
                with self.subTest(marker=marker), patch('device_release_exclusion.subprocess.run', side_effect=[
                        subprocess.CompletedProcess([], 0, 'binary:\n', ''),
                        subprocess.CompletedProcess([], 0, '_clean\n_' + marker, '')]):
                    with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                        inspect_binary(binary)
            with patch('device_release_exclusion.subprocess.run', return_value=subprocess.CompletedProcess(
                    [], 0, 'binary:\n\t/System/Library/Frameworks/CallKit.framework/CallKit (compatibility version 1.0)\n', '')):
                with self.assertRaisesRegex(ExclusionError, 'direct CallKit load command'):
                    inspect_binary(binary)
            binary.write_bytes(b'fulfilledPostEndUnmutePolicy')
            with patch('device_release_exclusion.subprocess.run', side_effect=[
                    subprocess.CompletedProcess([], 0, 'binary:\n', ''),
                    subprocess.CompletedProcess([], 0, '_clean', '')]):
                with self.assertRaisesRegex(ExclusionError, 'embedded simulator profile'):
                    inspect_binary(binary)

    def test_headers_keep_private_hooks_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'Bridge.h').write_text('// preprocessing fixture\n')
            for output in ('', 'void CKSimInjectPush(void);'):
                with self.subTest(output=output), \
                        patch('device_release_exclusion.subprocess.check_output', return_value='/fixture-sdk'), \
                        patch('device_release_exclusion.subprocess.run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                    if 'CKSim' in output:
                        with self.assertRaisesRegex(ExclusionError, 'public simulator test hook'):
                            inspect_public_headers(root)
                    else:
                        inspect_public_headers(root)
            (root / 'Bridge.h').unlink()
            (root / 'CKRuntimeSeam.h').write_text('// private\n')
            with patch('device_release_exclusion.subprocess.check_output', return_value='/fixture-sdk'), \
                    patch('device_release_exclusion.subprocess.run', side_effect=AssertionError('private header must refuse before preprocessing')):
                with self.assertRaisesRegex(ExclusionError, 'private simulator seam'):
                    inspect_public_headers(root)


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
            path.write_text('#import <TargetConditionals.h>\n#if TARGET_OS_SIMULATOR\n'
                            'void CKSimInjectPush(void);\nvoid CKSimEmit(void);\n#endif\n')
            inspect_public_headers(Path(directory))
            for marker in ('CKSimInjectPush', 'CKSimEmit'):
                path.write_text('void ' + marker + '(void);\n')
                with self.assertRaisesRegex(ExclusionError, 'public simulator test hook'):
                    inspect_public_headers(Path(directory))

    def test_simulator_public_header_consumer(self):
        # Consume the actual Expo public header, never the private implementation
        # seam. The example needs both controls in simulator builds.
        with tempfile.TemporaryDirectory(prefix='sdk-public-simulator-') as directory:
            source = Path(directory) / 'consumer.m'
            source.write_text('void controls(void) { CKSimInjectPush(@{}, YES, @"probe"); '
                              'CKSimEmit(@"clock", @{}); }\n')
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
            result = subprocess.run(['xcrun', 'clang', '-fsyntax-only', '-fobjc-arc',
                '-Werror=implicit-function-declaration', '-target', 'arm64-apple-ios26.0-simulator',
                '-isysroot', sdk, '-I', str(ROOT / 'Sources/Interposition/include'),
                '-I', str(ROOT / 'Sources/VoIPPlatform/include'),
                '-include', str(ROOT / 'Expo/apple/IosVoipSDK.h'), str(source)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_actual_macho_negative_controls(self):
        with tempfile.TemporaryDirectory(prefix='sdk-release-exclusion-') as directory:
            out = Path(directory)
            code = out / 'main.c'
            code.write_text('int main(void) { return 0; }\n')
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
            for name, extra in [('clean', []), ('callkit', ['-framework', 'CallKit'])]:
                subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', sdk,
                                str(code), '-o', str(out / name), *extra], capture_output=True,
                               text=True, timeout=30, check=True)
            inspect_binary(out / 'clean')
            with self.assertRaisesRegex(ExclusionError, 'direct CallKit load command'):
                inspect_binary(out / 'callkit')
            leaked = out / 'leaked.c'
            leaked.write_text('void CKSimInjectPush(void) {}\nint main(void) { CKSimInjectPush(); return 0; }\n')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', sdk,
                            str(leaked), '-o', str(out / 'leaked')], capture_output=True,
                           text=True, timeout=30, check=True)
            with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                inspect_binary(out / 'leaked')
            # Release pods can retain an empty guarded translation unit by its
            # source filename. That archive metadata is not implementation.
            empty = out / 'RuntimeEngine.m'
            empty.write_text('// Guarded implementation compiled out.\n')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', sdk,
                            '-c', str(empty), '-o', str(out / 'RuntimeEngine.o')],
                           capture_output=True, text=True, timeout=30, check=True)
            subprocess.run(['xcrun', 'ar', '-rcs', str(out / 'libGuarded.a'),
                            str(out / 'RuntimeEngine.o')], capture_output=True,
                           text=True, timeout=30, check=True)
            inspect_binary(out / 'libGuarded.a')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', sdk,
                            '-c', str(leaked), '-o', str(out / 'RuntimeEngine.o')],
                           capture_output=True, text=True, timeout=30, check=True)
            subprocess.run(['xcrun', 'ar', '-rcs', str(out / 'libGuarded.a'),
                            str(out / 'RuntimeEngine.o')], capture_output=True,
                           text=True, timeout=30, check=True)
            with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                inspect_binary(out / 'libGuarded.a')

if __name__ == '__main__':
    unittest.main()
