#!/usr/bin/env python3
"""Inspect a pod-built Release iphoneos app; no execution, signing or device use."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


class ExclusionError(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise ExclusionError(reason)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


PROVIDER_MONITOR_SYMBOLS = ('VSProviderMonitorInstall', 'VSProviderCreationMonitor')


def inspect_binary(path, provider_diagnostics=False):
    require(path.is_file() and path.stat().st_size > 0, 'missing native binary')
    result = subprocess.run(['xcrun', 'otool', '-L', str(path)],
                            capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, 'otool could not inspect native binary')
    dependencies = [line.strip().split(' (', 1)[0] for line in result.stdout.splitlines() if line.startswith('\t')]
    require(not any('/CallKit.framework/' in item for item in dependencies), 'direct CallKit load command')
    data = path.read_bytes()
    symbols = subprocess.run(['xcrun', 'nm', '-j', str(path)], capture_output=True, text=True, timeout=30)
    require(symbols.returncode == 0, 'nm could not inspect native binary')
    names = '\n'.join(line.strip() for line in symbols.stdout.splitlines()
                      if line.strip() and not line.rstrip().endswith(':'))
    # Empty archive members retain source filenames. Inspect actual symbols,
    # rather than treating that metadata as compiled runtime implementation.
    for marker in ('CKSimInjectPush', 'CKSimEmit', 'CKSimPrepareEngine', 'CKSimActivateRuntime',
                   'CKSimMakeCall', 'RuntimeEngine', 'RuntimeBootstrap', 'CXCallObserver', 'CXProvider',
                   *(() if provider_diagnostics else PROVIDER_MONITOR_SYMBOLS)):
        require(marker not in names, 'device binary contains simulator/debug implementation: ' + marker)
    require(b'fulfilledPostEndUnmutePolicy' not in data, 'device binary contains embedded simulator profile')
    inspection = dict(sha256=digest(path), bytes=len(data), directDependencies=dependencies,
                      symbolsSHA256=hashlib.sha256(symbols.stdout.encode()).hexdigest())
    if provider_diagnostics:
        defined = subprocess.run(['xcrun', 'nm', '-jU', str(path)], capture_output=True, text=True, timeout=30)
        require(defined.returncode == 0, 'nm could not inspect defined native symbols')
        definitions = set(defined.stdout.splitlines())
        inspection['providerMonitorPresent'] = {
            '_VSProviderMonitorInstall', '_OBJC_CLASS_$_VSProviderCreationMonitor',
        }.issubset(definitions)
    return inspection


def inspect_public_headers(directory, provider_diagnostics=False):
    headers = sorted(directory.rglob('*.h'))
    require(headers, 'missing SDK public headers')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    inspected = {}
    for path in headers:
        require(path.name != 'CKRuntimeSeam.h', 'private simulator seam is public')
        result = subprocess.run(['xcrun', 'clang', '-E', '-P', '-x', 'objective-c', '-fblocks',
                                 '-target', 'arm64-apple-ios17.4', '-isysroot', sdk, '-DDEBUG=0',
                                 *(['-DVSSDK_ENABLE_PROVIDER_DIAGNOSTICS=1'] if provider_diagnostics else []),
                                 '-I', str(directory), str(path)], capture_output=True, text=True, timeout=30)
        require(result.returncode == 0, 'cannot preprocess Release iphoneos public header: ' + path.name)
        require('CKSim' not in result.stdout, 'public simulator test hook')
        if not provider_diagnostics:
            require('VSProviderCreationMonitor' not in result.stdout, 'public Release creation monitor')
        inspected[str(path.relative_to(directory))] = dict(sourceSHA256=digest(path),
            devicePreprocessedSHA256=hashlib.sha256(result.stdout.encode()).hexdigest())
    return inspected


def inspect_app(app, pod_binary, public_headers, provider_diagnostics=False):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('DTPlatformName') == 'iphoneos', 'acceptance requires an iphoneos app')
    executable = app / info['CFBundleExecutable']
    binaries = {str(executable.relative_to(app)): inspect_binary(executable, provider_diagnostics)}
    magics = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
    for path in sorted(app.rglob('*')):
        if not path.is_file() or path == executable:
            continue
        require(not (path.name in ('ios-27.0.json', 'CKSimRuntime.dylib', 'CKSimLoader.dylib') or
                     'CKSimRuntime' in path.name or 'IosVoipSDKRuntime' in path.name),
                'device app contains simulator resource/product')
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in magics:
            binaries[str(path.relative_to(app))] = inspect_binary(path, provider_diagnostics)
    pod = inspect_binary(pod_binary, provider_diagnostics)
    if provider_diagnostics:
        require(pod['providerMonitorPresent'], 'opted-in pod binary is missing provider monitor implementation')
    return dict(success=True, qualification='pod-built Release iphoneos binary/resource/header inspection only',
                platform='iphoneos', appBinaries=binaries, podBinary=pod,
                publicHeaders=inspect_public_headers(public_headers, provider_diagnostics),
                limits='Direct linkage only; Apple LiveCommunicationKit transitive dependencies are not claimed absent.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--pod-binary', type=Path, required=True)
    parser.add_argument('--public-headers', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--provider-diagnostics', action='store_true', help='permit and require the optional provider monitor')
    args = parser.parse_args()
    try:
        result = inspect_app(args.app, args.pod_binary, args.public_headers, args.provider_diagnostics)
    except (ExclusionError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        result = dict(success=False, error=str(error))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
