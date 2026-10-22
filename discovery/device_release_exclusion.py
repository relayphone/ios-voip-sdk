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


def inspect_binary(path):
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
                   'VSProviderMonitorInstall', 'VSProviderCreationMonitor'):
        require(marker not in names, 'device binary contains simulator/debug implementation: ' + marker)
    require(b'fulfilledPostEndUnmutePolicy' not in data, 'device binary contains embedded simulator profile')
    return dict(sha256=digest(path), bytes=len(data), directDependencies=dependencies,
                symbolsSHA256=hashlib.sha256(symbols.stdout.encode()).hexdigest())


def inspect_public_headers(directory):
    headers = sorted(directory.rglob('*.h'))
    require(headers, 'missing SDK public headers')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    inspected = {}
    for path in headers:
        require(path.name != 'CKRuntimeSeam.h', 'private simulator seam is public')
        result = subprocess.run(['xcrun', 'clang', '-E', '-P', '-x', 'objective-c', '-fblocks',
                                 '-target', 'arm64-apple-ios17.4', '-isysroot', sdk, '-DDEBUG=0',
                                 '-I', str(directory), str(path)], capture_output=True, text=True, timeout=30)
        require(result.returncode == 0, 'cannot preprocess Release iphoneos public header: ' + path.name)
        require('CKSim' not in result.stdout, 'public simulator test hook')
        require('VSProviderCreationMonitor' not in result.stdout, 'public Release creation monitor')
        inspected[str(path.relative_to(directory))] = dict(sourceSHA256=digest(path),
            devicePreprocessedSHA256=hashlib.sha256(result.stdout.encode()).hexdigest())
    return inspected


def inspect_app(app, pod_binary, public_headers):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('DTPlatformName') == 'iphoneos', 'acceptance requires an iphoneos app')
    executable = app / info['CFBundleExecutable']
    binaries = {str(executable.relative_to(app)): inspect_binary(executable)}
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
            binaries[str(path.relative_to(app))] = inspect_binary(path)
    return dict(success=True, qualification='pod-built Release iphoneos binary/resource/header inspection only',
                platform='iphoneos', appBinaries=binaries, podBinary=inspect_binary(pod_binary),
                publicHeaders=inspect_public_headers(public_headers),
                limits='Direct linkage only; Apple LiveCommunicationKit transitive dependencies are not claimed absent.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--pod-binary', type=Path, required=True)
    parser.add_argument('--public-headers', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = inspect_app(args.app, args.pod_binary, args.public_headers)
    except (ExclusionError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        result = dict(success=False, error=str(error))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
