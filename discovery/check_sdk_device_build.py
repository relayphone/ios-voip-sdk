#!/usr/bin/env python3
"""Offline controls for the signed device builder; every native tool is mocked."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
BUILDER = ROOT / 'discovery/device/build_sdk.sh'
BUNDLE = 'dev.example.sdkqa'
TEAM = 'ABCDE12345'
SOURCES = {
    'Sources/VoIPSDK/F.swift': 'public struct Fixture {}\n',
    'Sources/VoIPPlatform/X.m': '#import "include/VoIPPlatform.h"\n',
    'Sources/VoIPPlatform/include/VoIPPlatform.h': '#pragma once\n',
    'Sources/VoIPPlatform/include/VSDeviceQADiagnostics.h': '#pragma once\n',
    'discovery/device/SDKDeviceProbe.swift': '// Synthetic SDK device entry point.\n',
    'discovery/device/DeviceQAStorage.swift': '// Synthetic private storage.\n',
}
COMPILED = {name for name in SOURCES if name.endswith(('.swift', '.m'))}
NATIVE_TOOLS = ('xcodegen', 'xcodebuild', 'codesign', 'security')
TOOL_CALLS = ('xcodegen', 'xcodebuild', 'codesign', 'codesign', 'security')
FORBIDDEN_TOOLS = ('xcrun', 'simctl', 'devicectl', 'curl', 'wget', 'node', 'npm',
                   'pnpm', 'pod', 'swift', 'swiftc', 'clang', 'open')

# Each mock is a real executable in an isolated PATH. An unexpected native tool
# fails closed; there is no delegation to the host's Xcode or signing tools.
MOCK = r'''#!/usr/bin/env python3
import json,os,pathlib,plistlib,sys
tool=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['MOCK_CALLS'],'a') as stream:
    stream.write(json.dumps(dict(tool=tool,args=args))+'\n')
assert tool in ('xcodegen','xcodebuild','security','codesign'), 'forbidden tool: '+tool
root=pathlib.Path(os.environ['MOCK_REPO'])
out=pathlib.Path(os.environ['MOCK_OUT'])
def option(name):
    return args[args.index(name)+1]
if tool=='xcodegen':
    assert args==['generate','--spec',str(out/'project.json'),'--project',str(out)],args
    project=json.loads((out/'project.json').read_text())
    assert project['name']=='SDKDeviceQA'
    target=project['targets']['SDKDeviceProbe']
    paths={str(pathlib.Path(row['path']).relative_to(root)) for row in target['sources']}
    assert paths==set(json.loads(os.environ['MOCK_COMPILED'])),paths
    assert all((root/path).is_file() for path in paths)
    assert not any('Engine' in path or 'Interposition' in path or '/probe/' in path for path in paths)
    settings=target['settings']['base']
    assert str(settings['SWIFT_VERSION']) in ('6','6.0')
    assert str(project['options']['deploymentTarget']['iOS'])=='17.4'
    assert 'SDK_DEVICE_QA=1' in settings['GCC_PREPROCESSOR_DEFINITIONS']
    assert 'SDK_DEVICE_QA' in settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
    assert settings['PRODUCT_BUNDLE_IDENTIFIER']==os.environ['SDK_DEVICE_BUNDLE_ID']
    assert settings['DEVELOPMENT_TEAM']==os.environ['SDK_DEVICE_TEAM_ID']
    assert settings['CODE_SIGN_STYLE']=='Automatic'
    assert 'SDKDeviceProbe' in project['schemes']
    info=plistlib.loads((out/'Info.plist').read_bytes())
    assert info['UIBackgroundModes']==['voip','audio'] or set(info['UIBackgroundModes'])=={'voip','audio'}
    assert info.get('NSMicrophoneUsageDescription')
    entitlements=plistlib.loads((out/'SDKDeviceProbe.entitlements').read_bytes())
    assert entitlements['aps-environment']=='development'
    assert not any('calling-app' in key for key in entitlements)
    headers=(out/'SDKDeviceHeaders.h').read_text()
    assert 'VoIPPlatform.h' in headers
    assert 'CKRuntime' not in headers
    (out/'SDKDeviceQA.xcodeproj').mkdir()
elif tool=='xcodebuild':
    expected=['-project',str(out/'SDKDeviceQA.xcodeproj'),'-scheme','SDKDeviceProbe',
        '-configuration','Debug','-sdk','iphoneos','-destination','generic/platform=iOS',
        '-derivedDataPath',str(out/'DerivedData'),'-allowProvisioningUpdates','build']
    assert args==expected,args
    assert '-allowProvisioningDeviceRegistration' not in args
    app=out/'DerivedData/Build/Products/Debug-iphoneos/SDKDeviceProbe.app'
    app.mkdir(parents=True)
    info=plistlib.loads((out/'Info.plist').read_bytes())
    info.update(CFBundleIdentifier=os.environ['SDK_DEVICE_BUNDLE_ID'],
                CFBundleExecutable='SDKDeviceProbe',CFBundleName='SDKDeviceProbe')
    case=os.environ.get('MOCK_APP_CASE','valid')
    if case=='wrong-bundle': info['CFBundleIdentifier']='dev.example.other'
    elif case=='wrong-source': info['SDKDeviceQASourceInputsSHA256']='0'*64
    elif case!='valid': raise AssertionError('unknown app case')
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    (app/'SDKDeviceProbe').write_bytes(b'mocked signed device build\n')
    (app/'embedded.mobileprovision').write_bytes(b'synthetic CMS profile\n')
    if os.environ.get('MOCK_MUTATE_SOURCE')=='1':
        with (root/'Sources/VoIPSDK/F.swift').open('a') as stream:
            stream.write('// changed during mocked build\n')
elif tool=='security':
    app=out/'DerivedData/Build/Products/Debug-iphoneos/SDKDeviceProbe.app'
    assert args==['cms','-D','-i',str(app/'embedded.mobileprovision'),'-o',str(out/'decoded-profile.plist')],args
    team=os.environ['SDK_DEVICE_TEAM_ID']
    bundle=os.environ['SDK_DEVICE_BUNDLE_ID']
    profile=dict(TeamIdentifier=[team],ApplicationIdentifierPrefix=[team],Entitlements={
        'aps-environment':'development','application-identifier':team+'.'+bundle,
        'com.apple.developer.team-identifier':team})
    case=os.environ.get('MOCK_PROFILE_CASE','valid')
    if case=='production': profile['Entitlements']['aps-environment']='production'
    elif case=='missing-aps': profile['Entitlements'].pop('aps-environment')
    elif case=='wrong-team':
        profile['TeamIdentifier']=['OTHER12345']
        profile['Entitlements']['com.apple.developer.team-identifier']='OTHER12345'
        profile['Entitlements']['application-identifier']='OTHER12345.'+bundle
    elif case=='wrong-bundle': profile['Entitlements']['application-identifier']=team+'.dev.example.other'
    elif case=='wrong-prefix': profile['Entitlements']['application-identifier']='OTHER12345.'+bundle
    elif case!='valid': raise AssertionError('unknown profile case')
    (out/'decoded-profile.plist').write_bytes(plistlib.dumps(profile))
elif tool=='codesign':
    app=out/'DerivedData/Build/Products/Debug-iphoneos/SDKDeviceProbe.app'
    assert app.is_dir()
    if args==['-d','--entitlements',':-',str(app)]:
        team=os.environ['SDK_DEVICE_TEAM_ID']
        bundle=os.environ['SDK_DEVICE_BUNDLE_ID']
        signed={'aps-environment':'development','application-identifier':team+'.'+bundle,
                'com.apple.developer.team-identifier':team}
        case=os.environ.get('MOCK_SIGNED_CASE','valid')
        if case=='missing-aps': signed.pop('aps-environment')
        elif case=='production': signed['aps-environment']='production'
        elif case=='missing-team': signed.pop('com.apple.developer.team-identifier')
        elif case=='wrong-team': signed['com.apple.developer.team-identifier']='OTHER12345'
        elif case=='missing-application': signed.pop('application-identifier')
        elif case=='wrong-application': signed['application-identifier']=team+'.dev.example.other'
        elif case!='valid': raise AssertionError('unknown signed-entitlement case')
        sys.stdout.buffer.write(plistlib.dumps(signed))
        raise SystemExit(0)
    assert args==['--verify','--strict',str(app)],args
print('mock '+tool+' completed')
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Fixture:
    def __init__(self, temporary):
        temporary = Path(temporary).resolve()
        self.root = temporary / 'repo'
        self.root.mkdir()
        self.private = temporary / 'private'
        self.private.mkdir(mode=0o700)
        self.out = self.private / 'build'
        self.bin = temporary / 'bin'
        self.bin.mkdir()
        self.calls_path = temporary / 'calls.jsonl'
        (self.root / '.gitignore').write_text('.env/\n')
        for name, contents in SOURCES.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.builder = self.root / 'discovery/device/build_sdk.sh'
        shutil.copyfile(BUILDER, self.builder)
        self.builder.chmod(0o700)
        # Include tempting inputs that the generated native target must exclude.
        for name in ('Sources/Engine/RuntimeEngine.swift', 'Sources/Interposition/CKInterposition.m',
                     'discovery/probe/main.swift'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('// Must not enter the device QA target.\n')
        for tool in (*NATIVE_TOOLS, *FORBIDDEN_TOOLS):
            path = self.bin / tool
            path.write_text(MOCK)
            path.chmod(0o700)
        # Only ordinary shell/identity helpers can reach host executables.
        for tool in ('bash', 'cat', 'chmod', 'date', 'dirname', 'git', 'mkdir', 'mktemp',
                     'perl', 'pwd', 'readlink', 'rm', 'sed', 'stat', 'tee', 'tr', 'uname'):
            source = shutil.which(tool)
            if source:
                (self.bin / tool).symlink_to(source)
        (self.bin / 'python3').symlink_to(sys.executable)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ('SDK_DEVICE_BUNDLE_ID', 'SDK_DEVICE_TEAM_ID', 'BASH_ENV', 'ENV')
                    and not key.startswith('GIT_')}
        self.env.update(PATH=str(self.bin), SDK_DEVICE_BUNDLE_ID=BUNDLE, SDK_DEVICE_TEAM_ID=TEAM,
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        MOCK_REPO=str(self.root), MOCK_OUT=str(self.out), MOCK_CALLS=str(self.calls_path),
                        MOCK_COMPILED=json.dumps(sorted(COMPILED)))
        for args in (['init', '-q'], ['config', 'user.email', 'fixture@example.invalid'],
                     ['config', 'user.name', 'Offline Fixture'], ['add', '.'],
                     ['commit', '-q', '-m', 'test: synthetic device builder inputs']):
            self.git(*args)

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null',
                                        '-c', 'commit.gpgsign=false', *args],
                                       cwd=self.root, env=self.env, stderr=subprocess.STDOUT, text=True)

    def calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()] \
            if self.calls_path.exists() else []

    def run(self, *, out=None, update=None, remove=()):
        out = self.out if out is None else out
        env = dict(self.env, MOCK_OUT=str(out.resolve()))
        env.update(update or {})
        for key in remove:
            env.pop(key, None)
        return subprocess.run(['bash', str(self.builder), str(out)], cwd=self.root,
                              env=env, text=True, capture_output=True, timeout=30)


class Controls(unittest.TestCase):
    def fixture(self, check):
        with tempfile.TemporaryDirectory(prefix='sdk-device-build-controls-') as temporary:
            check(Fixture(temporary))

    def success(self, fixture, *, out=None):
        result = fixture.run(out=out)
        target = fixture.out if out is None else out
        logs = ''.join(path.read_text() for path in target.glob('*.log')) if target.is_dir() else ''
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr + logs)[-3000:])
        return fixture.out if out is None else out

    def rejected(self, fixture, *, before_tools=False, diagnostic=None, **kwargs):
        result = fixture.run(**kwargs)
        out = Path(kwargs.get('out', fixture.out))
        logs = ''.join(path.read_text() for path in out.glob('*.log')) if out.is_dir() else ''
        self.assertNotEqual(result.returncode, 0, 'unsafe build unexpectedly succeeded')
        self.assertNotIn('AssertionError', result.stdout + result.stderr + logs,
                         'a mock contract failure cannot qualify a rejection')
        if diagnostic:
            self.assertIn(diagnostic, result.stdout + result.stderr + logs)
        if before_tools:
            self.assertEqual(fixture.calls(), [], (result.stdout + result.stderr)[-2000:])
        self.assertFalse((out / 'build-receipt.json').exists())

    def test_build_and_bound_receipt(self):
        def check(fixture):
            out = self.success(fixture)
            self.assertEqual([call['tool'] for call in fixture.calls()], list(TOOL_CALLS))
            start = json.loads((out / 'source-build-start.json').read_text())
            receipt = json.loads((out / 'build-receipt.json').read_text())
            self.assertEqual(receipt['schemaVersion'], 1)
            self.assertEqual(receipt['sourceCommit'], fixture.git('rev-parse', 'HEAD').strip())
            self.assertEqual(receipt['sourceCommit'], start['sourceCommit'])
            self.assertEqual(receipt['sourceInputsSHA256'], start['sourceInputsSHA256'])
            self.assertRegex(receipt['sourceInputsSHA256'], r'^[0-9a-f]{64}$')
            inputs = start['inputs']
            paths = [item['path'] for item in inputs]
            self.assertTrue(set(SOURCES).issubset(paths))
            self.assertEqual(len(paths), len(set(paths)))
            combined = hashlib.sha256()
            for item in inputs:
                self.assertEqual(item['sha256'], digest(fixture.root / item['path']))
                combined.update(item['path'].encode() + b'\0' +
                                (fixture.root / item['path']).read_bytes() + b'\0')
            self.assertEqual(combined.hexdigest(), receipt['sourceInputsSHA256'])
            app = out / 'DerivedData/Build/Products/Debug-iphoneos/SDKDeviceProbe.app'
            self.assertEqual(receipt['binarySHA256'], digest(app / 'SDKDeviceProbe'))
            self.assertEqual(receipt['provisioningProfileSHA256'], digest(app / 'embedded.mobileprovision'))
            self.assertEqual(receipt['signedEntitlementsSHA256'], digest(out / 'signed-entitlements.plist'))
            self.assertEqual(receipt['configuration'], 'Debug')
            self.assertEqual(receipt['platform'], 'iphoneos')
            self.assertEqual(receipt['destination'], 'generic/platform=iOS')
            info = plistlib.loads((app / 'Info.plist').read_bytes())
            self.assertEqual(info['SDKDeviceQASourceCommit'], receipt['sourceCommit'])
            self.assertEqual(info['SDKDeviceQASourceInputsSHA256'], receipt['sourceInputsSHA256'])
            self.assertEqual(info['CFBundleIdentifier'], BUNDLE)
            for path in (out, *out.rglob('*')):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o077, 0, str(path.relative_to(out)))
        self.fixture(check)

    def test_private_env_output(self):
        def check(fixture):
            parent = fixture.root / '.env'
            parent.mkdir(mode=0o700)
            self.success(fixture, out=parent / 'sdk-build')
        self.fixture(check)

    def test_private_alias_resolves_to_private_output(self):
        def check(fixture):
            parent = fixture.private.parent / 'alias'
            parent.symlink_to(fixture.private)
            self.success(fixture, out=parent / 'build')
            args = fixture.calls()[0]['args']
            self.assertEqual(args[2], str(fixture.out / 'project.json'))
        self.fixture(check)

    def test_required_environment(self):
        for name in ('SDK_DEVICE_BUNDLE_ID', 'SDK_DEVICE_TEAM_ID'):
            with self.subTest(name=name):
                self.fixture(lambda fixture: self.rejected(fixture, before_tools=True, remove=(name,)))

    def test_invalid_environment(self):
        for name, values in (('SDK_DEVICE_BUNDLE_ID', ('', 'bad id', 'dev..bad', 'dev.example/unsafe')),
                             ('SDK_DEVICE_TEAM_ID', ('', 'short', 'ABCDE1234!', '../ABCDE12'))):
            for value in values:
                with self.subTest(name=name, value=value):
                    self.fixture(lambda fixture: self.rejected(fixture, before_tools=True, update={name: value}))

    def test_reused_output(self):
        for kind in ('directory', 'file', 'symlink'):
            def check(fixture):
                if kind == 'directory':
                    fixture.out.mkdir(mode=0o700)
                elif kind == 'file':
                    fixture.out.write_text('existing output')
                else:
                    fixture.out.symlink_to(fixture.private)
                self.rejected(fixture, before_tools=True)
            with self.subTest(kind=kind):
                self.fixture(check)

    def test_unsafe_output_parent(self):
        def public(fixture):
            parent = fixture.private.parent / 'public'
            parent.mkdir(mode=0o755)
            self.rejected(fixture, out=parent / 'build', before_tools=True)
        def repository(fixture):
            self.rejected(fixture, out=fixture.root / 'build', before_tools=True)
        for check in (public, repository):
            with self.subTest(case=check.__name__):
                self.fixture(check)

    def test_dirty_source_before_build(self):
        def check(fixture):
            (fixture.root / 'Sources/VoIPSDK/F.swift').write_text('// uncommitted source\n')
            self.rejected(fixture, before_tools=True)
        self.fixture(check)

    def test_source_mutation_during_build(self):
        self.fixture(lambda fixture: self.rejected(fixture, update={'MOCK_MUTATE_SOURCE': '1'},
                                                  diagnostic='changed during compilation'))

    def test_built_app_must_match(self):
        for case in ('wrong-source', 'wrong-bundle'):
            with self.subTest(case=case):
                self.fixture(lambda fixture: self.rejected(fixture, update={'MOCK_APP_CASE': case}))

    def test_provisioning_profile_must_match(self):
        for case in ('production', 'missing-aps', 'wrong-team', 'wrong-bundle', 'wrong-prefix'):
            with self.subTest(case=case):
                self.fixture(lambda fixture: self.rejected(fixture, update={'MOCK_PROFILE_CASE': case},
                                                          diagnostic='development APNs identity'))

    def test_signed_app_entitlements_must_match(self):
        for case in ('missing-aps', 'production', 'missing-team', 'wrong-team',
                     'missing-application', 'wrong-application'):
            with self.subTest(case=case):
                self.fixture(lambda fixture: self.rejected(fixture, update={'MOCK_SIGNED_CASE': case},
                    diagnostic='Signed app entitlements must match the development APNs identity.'))


if __name__ == '__main__':
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Controls))
    print(json.dumps(dict(success=result.wasSuccessful(), testGroups=result.testsRun,
        nativeExecution=False, controls=['private-fresh-output', 'environment-validation',
            'shared-source-target', 'generic-build-only', 'development-profile-binding', 'signed-entitlement-binding',
            'source-before-and-after-binding'])))
    raise SystemExit(0 if result.wasSuccessful() else 1)
