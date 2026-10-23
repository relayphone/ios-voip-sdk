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

from build_sdk_device_release import require_provider_configuration
from device_release_exclusion import ExclusionError, inspect_app, inspect_binary, inspect_public_headers

ROOT = Path(__file__).resolve().parent.parent


def embedded_profile(source):
    match = re.search(r'private static let embeddedProfileJSON = #"""\n(.*?)\n"""#', source, re.S)
    if not match:
        raise ValueError('missing guarded simulator profile')
    return json.loads(match[1])


class InspectionModeControls(unittest.TestCase):
    """Policy/configuration controls only; all native tools are explicit mocks."""

    def test_binary_mode_preserves_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'binary'
            binary.write_bytes(b'native-tool-output-fixture')
            monitor = '_VSProviderMonitorInstall\n_OBJC_CLASS_$_VSProviderCreationMonitor\n'
            for enabled in (False, True):
                outputs = [
                        subprocess.CompletedProcess([], 0, 'binary:\n', ''),
                        subprocess.CompletedProcess([], 0, monitor, '')]
                if enabled:
                    outputs.append(subprocess.CompletedProcess([], 0, monitor, ''))
                with self.subTest(enabled=enabled), patch('device_release_exclusion.subprocess.run', side_effect=outputs):
                    if enabled:
                        self.assertTrue(inspect_binary(binary, True)['providerMonitorPresent'])
                    else:
                        with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                            inspect_binary(binary)
                for marker in ('CKSimInjectPush', 'CKSimEmit', 'CKSimPrepareEngine', 'CKSimActivateRuntime',
                               'CKSimMakeCall', 'RuntimeEngine', 'RuntimeBootstrap', 'CXCallObserver', 'CXProvider'):
                    with self.subTest(enabled=enabled, marker=marker), patch('device_release_exclusion.subprocess.run', side_effect=[
                            subprocess.CompletedProcess([], 0, 'binary:\n', ''),
                            subprocess.CompletedProcess([], 0, monitor + '_' + marker, '')]):
                        with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                            inspect_binary(binary, enabled)
                with patch('device_release_exclusion.subprocess.run', return_value=subprocess.CompletedProcess(
                        [], 0, 'binary:\n\t/System/Library/Frameworks/CallKit.framework/CallKit (compatibility version 1.0)\n', '')):
                    with self.assertRaisesRegex(ExclusionError, 'direct CallKit load command'):
                        inspect_binary(binary, enabled)
                binary.write_bytes(b'fulfilledPostEndUnmutePolicy')
                with patch('device_release_exclusion.subprocess.run', side_effect=[
                        subprocess.CompletedProcess([], 0, 'binary:\n', ''),
                        subprocess.CompletedProcess([], 0, '_clean', '')]):
                    with self.assertRaisesRegex(ExclusionError, 'embedded simulator profile'):
                        inspect_binary(binary, enabled)
                binary.write_bytes(b'native-tool-output-fixture')

    def test_enabled_app_requires_both_monitor_symbols(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app = root / 'App.app'; app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps(dict(DTPlatformName='iphoneos', CFBundleExecutable='App')))
            (app / 'App').write_bytes(b'app')
            pod = root / 'pod'; pod.write_bytes(b'pod')
            for names in ('', '_VSProviderMonitorInstall', '_OBJC_CLASS_$_VSProviderCreationMonitor',
                          '_VSProviderMonitorInstallWithSource\n_OBJC_CLASS_$_VSProviderCreationMonitor',
                          '_VSProviderMonitorInstall\n_OBJC_CLASS_$_VSProviderCreationMonitor'):
                def native(argv, **kwargs):
                    output = ''
                    if argv[1] == 'nm' and Path(argv[-1]) == pod:
                        # The full inventory always contains both references;
                        # only the separate defined-symbol inventory can prove code.
                        output = names if '-jU' in argv else '_VSProviderMonitorInstall\n_OBJC_CLASS_$_VSProviderCreationMonitor'
                    return subprocess.CompletedProcess(argv, 0, output, '')
                with self.subTest(names=names), patch('device_release_exclusion.subprocess.run', side_effect=native), \
                        patch('device_release_exclusion.inspect_public_headers', return_value={}) as headers:
                    if names == '_VSProviderMonitorInstall\n_OBJC_CLASS_$_VSProviderCreationMonitor':
                        self.assertTrue(inspect_app(app, pod, root, True)['success'])
                        headers.assert_called_once_with(root, True)
                    else:
                        with self.assertRaisesRegex(ExclusionError, 'missing provider monitor implementation'):
                            inspect_app(app, pod, root, True)

    def test_header_mode_keeps_private_hooks_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'Bridge.h').write_text('// preprocessing fixture\n')
            for enabled in (False, True):
                for output in ('', '@interface VSProviderCreationMonitor', 'void CKSimInjectPush(void);'):
                    with self.subTest(enabled=enabled, output=output), \
                            patch('device_release_exclusion.subprocess.check_output', return_value='/fixture-sdk'), \
                            patch('device_release_exclusion.subprocess.run', return_value=subprocess.CompletedProcess([], 0, output, '')) as preprocess:
                        if 'CKSim' in output or (not enabled and 'VSProviderCreationMonitor' in output):
                            with self.assertRaises(ExclusionError):
                                inspect_public_headers(root, enabled)
                        else:
                            inspect_public_headers(root, enabled)
                        argv = preprocess.call_args.args[0]
                        self.assertEqual('-DVSSDK_ENABLE_PROVIDER_DIAGNOSTICS=1' in argv, enabled)
            (root / 'Bridge.h').unlink()
            (root / 'CKRuntimeSeam.h').write_text('// private\n')
            with patch('device_release_exclusion.subprocess.check_output', return_value='/fixture-sdk'), \
                    patch('device_release_exclusion.subprocess.run', side_effect=AssertionError('private header must refuse before preprocessing')):
                with self.assertRaisesRegex(ExclusionError, 'private simulator seam'):
                    inspect_public_headers(root, True)

    def test_generated_opt_in_requires_property_and_paired_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'Pods/Target Support Files/IosVoipSDK/IosVoipSDK.release.xcconfig'
            config.parent.mkdir(parents=True)
            for value in (None, False, 'false', 'true'):
                (root / 'Podfile.properties.json').write_text(json.dumps({'ios-voip-sdk.providerOwnershipMonitoring': value}))
                for swift, objc in ((False, False), (True, False), (False, True), (True, True)):
                    config.write_text('SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) ' +
                        ('VSSDK_ENABLE_PROVIDER_DIAGNOSTICS' if swift else '') +
                        '\nGCC_PREPROCESSOR_DEFINITIONS = $(inherited) ' +
                        ('VSSDK_ENABLE_PROVIDER_DIAGNOSTICS=1' if objc else '') + '\n')
                    with self.subTest(value=value, swift=swift, objc=objc):
                        if value == 'true' and swift and objc:
                            require_provider_configuration(root)
                        else:
                            with self.assertRaises(ExclusionError):
                                require_provider_configuration(root)


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
                '-Werror=implicit-function-declaration', '-target', 'arm64-apple-ios17.4-simulator',
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
                subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
                                str(code), '-o', str(out / name), *extra], capture_output=True,
                               text=True, timeout=30, check=True)
            inspect_binary(out / 'clean')
            for enabled in (False, True):
                with self.assertRaisesRegex(ExclusionError, 'direct CallKit load command'):
                    inspect_binary(out / 'callkit', enabled)
            leaked = out / 'leaked.c'
            leaked.write_text('void CKSimInjectPush(void) {}\nint main(void) { CKSimInjectPush(); return 0; }\n')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
                            str(leaked), '-o', str(out / 'leaked')], capture_output=True,
                           text=True, timeout=30, check=True)
            for enabled in (False, True):
                with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                    inspect_binary(out / 'leaked', enabled)
            monitor = out / 'monitor.m'
            monitor.write_text('#import <Foundation/Foundation.h>\n@interface VSProviderCreationMonitor : NSObject @end\n'
                               '@implementation VSProviderCreationMonitor @end\n'
                               'void VSProviderMonitorInstall(void) {}\nint main(void) { VSProviderMonitorInstall(); return 0; }\n')
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
                            '-framework', 'Foundation',
                            str(monitor), '-o', str(out / 'monitor')], capture_output=True,
                           text=True, timeout=30, check=True)
            with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                inspect_binary(out / 'monitor')
            self.assertTrue(inspect_binary(out / 'monitor', True)['providerMonitorPresent'])
            # Release pods can retain an empty guarded translation unit by its
            # source filename. That archive metadata is not implementation.
            empty = out / 'VSProviderCreationMonitor.m'
            empty.write_text('// Guarded implementation compiled out.\n')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
                            '-c', str(empty), '-o', str(out / 'VSProviderCreationMonitor.o')],
                           capture_output=True, text=True, timeout=30, check=True)
            subprocess.run(['xcrun', 'ar', '-rcs', str(out / 'libGuarded.a'),
                            str(out / 'VSProviderCreationMonitor.o')], capture_output=True,
                           text=True, timeout=30, check=True)
            inspect_binary(out / 'libGuarded.a')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
                            '-c', str(leaked), '-o', str(out / 'VSProviderCreationMonitor.o')],
                           capture_output=True, text=True, timeout=30, check=True)
            subprocess.run(['xcrun', 'ar', '-rcs', str(out / 'libGuarded.a'),
                            str(out / 'VSProviderCreationMonitor.o')], capture_output=True,
                           text=True, timeout=30, check=True)
            with self.assertRaisesRegex(ExclusionError, 'simulator/debug implementation'):
                inspect_binary(out / 'libGuarded.a')


if __name__ == '__main__':
    unittest.main()
