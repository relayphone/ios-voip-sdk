#!/usr/bin/env python3
"""Offline negative controls for release gating and deterministic archive metadata."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/check-runtime-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.PIPE).strip()


def repository(root, annotated=True, merged=True):
    root.mkdir()
    git(root, 'init', '-b', 'main')
    git(root, 'config', 'user.email', 'release-fixture@example.invalid')
    git(root, 'config', 'user.name', 'Release Fixture')
    (root / 'VERSION').write_text('0.1.1\n')
    git(root, 'add', 'VERSION')
    git(root, 'commit', '-m', 'fixture')
    if not merged:
        git(root, 'checkout', '-b', 'unmerged')
        (root / 'VERSION').write_text('0.1.1\n\n')
        git(root, 'commit', '-am', 'unmerged fixture')
    git(root, 'tag', *(['-a', 'v0.1.1', '-m', 'fixture'] if annotated else ['v0.1.1']))


def package(root, repo):
    (root / 'profiles').mkdir(parents=True)
    for name in ('CKSimRuntime.dylib', 'CKSimLoader.dylib'):
        (root / name).write_bytes(b'synthetic release fixture\n')
    (root / 'profiles/ios-27.0.json').write_text('{}\n')
    (root / 'VERSION').write_text('0.1.1\n')
    (root / 'cksim').write_bytes((ROOT / 'Tools/cksim').read_bytes())
    (root / 'cksim').chmod(0o755)
    info = dict(schemaVersion=1, version='0.1.1', sourceCommit=git(repo, 'rev-parse', 'HEAD'), sourceDirty=False,
                sourceDateEpoch=int(git(repo, 'show', '-s', '--format=%ct', 'HEAD')), architectures=['arm64', 'x86_64'],
                toolchain=dict(xcode='synthetic Xcode', swift='synthetic Swift', clang='synthetic Clang'),
                sdk=dict(version='synthetic SDK', build='synthetic SDK build'))
    info['files'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
    (root / 'build-info.json').write_text(json.dumps(info))
    return info


def main():
    checks = []
    old_cwd = Path.cwd()
    with tempfile.TemporaryDirectory(prefix='cksim-release-controls-') as temporary:
        root = Path(temporary)
        for label, annotated, merged in (('annotated-merged', True, True), ('lightweight-tag', False, True), ('unmerged-tag', True, False)):
            repo = root / label
            repository(repo, annotated, merged)
            os.chdir(repo)
            try:
                release.check('v0.1.1', 'main')
            except ValueError:
                assert label != 'annotated-merged', 'valid annotated merged tag refused'
            else:
                assert label == 'annotated-merged', f'{label} accepted'
            checks.append(label)
        repo = root / 'annotated-merged'
        os.chdir(repo)
        dist = root / 'runtime-dist'
        info = package(dist, repo)
        release.check('v0.1.1', 'main', dist)
        checks.append('valid-synthetic-release-package')
        cases = (('version-mismatch', lambda i: i.update(version='0.1.0')),
                 ('source-mismatch', lambda i: i.update(sourceCommit='0' * 40)),
                 ('dirty-source-build', lambda i: i.update(sourceDirty=True)),
                 ('missing-toolchain', lambda i: i.pop('toolchain')),
                 ('missing-sdk-build', lambda i: i['sdk'].pop('build')),
                 ('missing-architecture', lambda i: i.update(architectures=['arm64'])),
                 ('source-date-mismatch', lambda i: i.update(sourceDateEpoch=0)),
                 ('checksum-mismatch', lambda i: i['files'].update({'CKSimRuntime.dylib': '0' * 64})))
        for label, mutate in cases:
            current = copy.deepcopy(info)
            mutate(current)
            (dist / 'build-info.json').write_text(json.dumps(current))
            try:
                release.check('v0.1.1', 'main', dist)
            except ValueError:
                checks.append(label)
            else:
                raise AssertionError(f'{label} accepted')
        (dist / 'build-info.json').write_text(json.dumps(info))
        for tag in ('v0.1', 'v9.9.9'):
            try:
                release.check(tag, 'main', dist)
            except ValueError:
                checks.append('tag-version-mismatch-' + tag)
            else:
                raise AssertionError('mismatched version tag accepted')
        (dist / 'VERSION').write_text('0.1.0\n')
        try:
            release.check('v0.1.1', 'main', dist)
        except ValueError:
            checks.append('package-VERSION-mismatch')
        else:
            raise AssertionError('mismatched package VERSION accepted')
        (dist / 'VERSION').write_text('0.1.1\n')
        os.chdir(ROOT)
        archives = []
        for index in range(2):
            output = root / f'archive-{index}'
            subprocess.run(['bash', str(ROOT / 'scripts/package-runtime.sh'), str(dist), str(output)], check=True)
            archive = output / 'callkit-simulator-v0.1.1-macos.tar.gz'
            archives.append(archive.read_bytes())
            assert (output / 'SHA256SUMS').read_text() == hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n'
            with tarfile.open(archive) as tar:
                members = tar.getmembers()
                assert all(m.uid == m.gid == 0 and m.uname == m.gname == '' and m.mtime == info['sourceDateEpoch'] for m in members)
                assert [m.name for m in members] == sorted(m.name for m in members)
                assert tar.getmember('./cksim').mode == 0o755
            for path in dist.rglob('*'):
                os.utime(path, (1_000_000_000 + index, 1_000_000_000 + index))
        assert archives[0] == archives[1], 'archive differs after filesystem timestamp changes'
        checks.extend(['normalized-archive-ownership-order-mtime-modes', 'reproducible-packaging', 'archive-checksums'])
    os.chdir(old_cwd)
    print(json.dumps(dict(success=True, checks=checks), indent=2))


if __name__ == '__main__':
    main()
