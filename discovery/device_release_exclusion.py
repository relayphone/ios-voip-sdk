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
    dependencies = [line.strip().split(' (', 1)[0] for line in result.stdout.splitlines()[1:] if line.strip()]
    require(not any('/CallKit.framework/' in item for item in dependencies), 'direct CallKit load command')
    data = path.read_bytes()
    # Error-domain strings intentionally remain: they do not link a framework.
    for marker in (b'CKSimInjectPush', b'CKSimEmit', b'RuntimeEngine', b'RuntimeBootstrap',
                   b'fulfilledPostEndUnmutePolicy', b'CXCallObserver', b'CXProvider',
                   b'VSProviderMonitorInstall', b'VSProviderCreationMonitor'):
        require(marker not in data, 'device binary contains simulator/debug implementation: ' + marker.decode())
    return dict(sha256=digest(path), bytes=len(data), directDependencies=dependencies)


def inspect_public_headers(directory):
    headers = sorted(directory.rglob('*.h'))
    require(headers, 'missing SDK public headers')
    for path in headers:
        require(path.name != 'CKRuntimeSeam.h', 'private simulator seam is public')
        text = path.read_text()
        require('CKSimInjectPush' not in text and 'CKSimEmit' not in text, 'public simulator test hook')
    return {str(path.relative_to(directory)): digest(path) for path in headers}


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
