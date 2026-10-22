#!/usr/bin/env python3
"""Read-only M2 host/runtime preflight; never creates or boots a simulator."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


COMMANDS = {
    'macOS': ['sw_vers'],
    'architecture': ['uname', '-m'],
    'xcode': ['xcodebuild', '-version'],
    'simulatorSDKVersion': ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'],
    'simulatorSDKBuild': ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-build-version'],
    'simulatorSDKPath': ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
    'runtimes': ['xcrun', 'simctl', 'list', 'runtimes', '--json'],
}


def inspect(runtime, audio_path, xcode_version, xcode_build=None, *, execute=subprocess.run, environment=None):
    env = os.environ if environment is None else environment
    receipt = dict(schemaVersion=1, product='sdk-m2-environment',
        recordedAt=datetime.now(timezone.utc).isoformat(),
        sourceSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        requested=dict(runtime=runtime, audioPath=audio_path, architecture='arm64',
                       xcodeVersion=xcode_version, xcodeBuild=xcode_build),
        runner={key: env.get(key) for key in (
            'ImageOS', 'ImageVersion', 'RUNNER_ARCH', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA')},
        commands={}, errors=[], success=False)
    for name, args in COMMANDS.items():
        record = dict(argv=args, timeoutSeconds=30)
        receipt['commands'][name] = record
        try:
            result = execute(args, capture_output=True, text=True, timeout=30, check=False)
            record.update(exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr)
            if result.returncode:
                receipt['errors'].append(name + ': command failed')
        except (OSError, subprocess.SubprocessError) as error:
            record.update(exitCode=None, error=type(error).__name__)
            receipt['errors'].append(name + ': command unavailable or timed out')
    if receipt['errors']:
        return receipt
    output = {key: value['stdout'].strip() for key, value in receipt['commands'].items()}
    if output['architecture'] != 'arm64' or env.get('RUNNER_ARCH', 'ARM64').upper() != 'ARM64':
        receipt['errors'].append('expected arm64 host and runner')
    match = re.fullmatch(r'Xcode (\S+)\nBuild version (\S+)', output['xcode'])
    if match is None or match[1] != xcode_version or (xcode_build is not None and match[2] != xcode_build):
        receipt['errors'].append('selected Xcode version/build differs from lane')
    try:
        runtimes = json.loads(output['runtimes'])['runtimes']
        candidates = [row for row in runtimes if row.get('platform') == 'iOS' and
                      runtime in (row.get('name'), row.get('identifier'))]
        if len(candidates) != 1 or candidates[0].get('isAvailable') is not True:
            raise ValueError('requested runtime missing, ambiguous or unavailable')
        selected = candidates[0]
        for field in ('name', 'identifier', 'version', 'buildversion'):
            if not isinstance(selected.get(field), str) or not selected[field]:
                raise ValueError('runtime identity incomplete')
        major = int(selected['version'].split('.')[0])
        if (audio_path == 'modern') != (major >= 27):
            raise ValueError('runtime does not match requested audio path')
        receipt['selectedRuntime'] = {key: selected[key] for key in (
            'name', 'identifier', 'version', 'buildversion', 'isAvailable', 'platform')}
    except (ValueError, KeyError, TypeError, AttributeError):
        receipt['errors'].append('requested iOS runtime unavailable or incompatible with audio path')
    for field in ('macOS', 'simulatorSDKVersion', 'simulatorSDKBuild', 'simulatorSDKPath'):
        if not output[field]:
            receipt['errors'].append(field + ': empty identity')
    receipt['success'] = not receipt['errors']
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--audio-path', choices=('legacy', 'modern'), required=True)
    parser.add_argument('--xcode-version', required=True)
    parser.add_argument('--xcode-build')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.runtime, args.audio_path, args.xcode_version, args.xcode_build)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(success=result['success'], errors=result['errors'],
                         selectedRuntime=result.get('selectedRuntime')), indent=2))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
