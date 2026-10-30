#!/usr/bin/env python3
"""Refuse runtime releases without an annotated, versioned tag merged into main."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def git(*args):
    return subprocess.check_output(['git', *args], text=True, stderr=subprocess.PIPE).strip()


def check(tag, main_ref, package=None):
    version = Path('VERSION').read_text().strip()
    if not re.fullmatch(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', version) or tag != 'v' + version:
        raise ValueError('Release tag must match VERSION exactly')
    ref = 'refs/tags/' + tag
    if git('cat-file', '-t', ref) != 'tag':
        raise ValueError('Release requires an annotated tag')
    commit = git('rev-parse', ref + '^{commit}')
    if commit != git('rev-parse', 'HEAD'):
        raise ValueError('Checkout differs from tagged commit')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', commit, main_ref], check=False).returncode:
        raise ValueError('Tagged commit is not merged into main')
    if git('status', '--porcelain'):
        raise ValueError('Release source checkout is dirty')
    if package is not None:
        info = json.loads((package / 'build-info.json').read_text())
        if (info.get('version') != version or (package / 'VERSION').read_text().strip() != version or
                info.get('sourceCommit') != commit or info.get('sourceDirty') is not False):
            raise ValueError('Runtime package version or source differs from release')
        if info.get('sourceDateEpoch') != int(git('show', '-s', '--format=%ct', commit)):
            raise ValueError('Runtime package source date differs from release')
        for key in ('xcode', 'swift', 'clang'):
            if not isinstance(info.get('toolchain', {}).get(key), str) or not info['toolchain'][key].strip():
                raise ValueError(f'Runtime package is missing toolchain {key}')
        for key in ('version', 'build'):
            if not isinstance(info.get('sdk', {}).get(key), str) or not info['sdk'][key].strip():
                raise ValueError(f'Runtime package is missing SDK {key}')
        if set(info.get('architectures', [])) != {'arm64', 'x86_64'}:
            raise ValueError('Release requires arm64 and x86_64 simulator slices')
        required = {'CKSimRuntime.dylib', 'CKSimLoader.dylib', 'cksim', 'VERSION', 'profiles/ios-27.0.json'}
        if info.get('schemaVersion') != 1 or not required.issubset(info.get('files', {})):
            raise ValueError('Incomplete runtime release package')
        for name, digest in info['files'].items():
            path = package / name
            if not path.resolve().is_relative_to(package.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise ValueError('Runtime release checksum mismatch: ' + name)
    return dict(version=version, tag=tag, sourceCommit=commit, mainRef=main_ref, packageVerified=package is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--main-ref', default='origin/main')
    parser.add_argument('--package', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.tag, args.main_ref, args.package), indent=2))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release refused: {error}\n')


if __name__ == '__main__':
    main()
