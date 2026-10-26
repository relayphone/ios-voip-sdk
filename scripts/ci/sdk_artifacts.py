#!/usr/bin/env python3
"""Source-bound component transfer; preserve app modes and framework symlinks."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import stat
import subprocess
import sys
import tarfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'discovery'))
from sdk_m0_conformance import source_identity, device_objects

COMPONENTS = dict(example=('example', 'example-start.json'),
                  core=('bootstrap', 'device', 'spm-device'),
                  fixtures=('m1-contracts', 'system-control', 'push-entry'))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source():
    value = source_identity()
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--',
        'scripts/ci/sdk_paths.sh', 'scripts/ci/sdk_artifacts.py'], cwd=REPO, timeout=10)
    if value['sourceDirty'] or dirty:
        raise ValueError('Component source must be committed')
    return value


def entry(path):
    if path.is_symlink():
        return dict(kind='symlink', target=os.readlink(path))
    return dict(kind='file', sha256=digest(path), mode=stat.S_IMODE(path.stat().st_mode))


def begin(component, root):
    with (root / (component + '-start.json')).open('x') as stream:
        json.dump(source(), stream)


def pack(component, root, output):
    before = json.loads((root / (component + '-start.json')).read_text())
    if before != source():
        raise ValueError('Source changed during component build')
    prefixes = (*COMPONENTS[component], 'build-logs')
    files = {}
    for name in prefixes:
        path = root / name
        if not path.exists():
            raise ValueError('Missing component product: ' + name)
        for item in [path, *path.rglob('*')] if path.is_dir() else [path]:
            if item.is_file() or item.is_symlink():
                files[str(item.relative_to(root))] = entry(item)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (component + '.tgz')
    with tarfile.open(archive, 'w:gz', compresslevel=1) as bundle:
        for name in prefixes:
            bundle.add(root / name, arcname=name)
    if before != source():
        raise ValueError('Source changed while publishing component')
    receipt = dict(schemaVersion=1, component=component, hostArchitecture=platform.machine(), sourceStart=before,
                   sourceEnd=before, files=files, archiveSHA256=digest(archive))
    (output / (component + '.json')).write_text(json.dumps(receipt, sort_keys=True) + '\n')


def unpack(component, root, incoming):
    receipt = json.loads((incoming / (component + '.json')).read_text())
    archive = incoming / (component + '.tgz')
    identity = source()
    if (type(receipt.get('schemaVersion')) is not int or receipt['schemaVersion'] != 1 or receipt.get('component') != component or
            receipt.get('hostArchitecture') != platform.machine() or
            receipt.get('sourceStart') != identity or receipt.get('sourceEnd') != identity or
            receipt.get('archiveSHA256') != digest(archive)):
        raise ValueError('Component source/archive identity differs')
    root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        names = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts or
                    path.parts[0] not in (*COMPONENTS[component], 'build-logs') or
                    not (member.isfile() or member.isdir() or member.issym())):
                raise ValueError('Unexpected component archive path/type')
            if member.issym():
                target = posixpath.normpath(str(path.parent / member.linkname))
                if member.linkname.startswith('/') or target == '..' or target.startswith('../'):
                    raise ValueError('Component symlink escapes its root')
            if not member.isdir():
                if member.name in names or (root / member.name).exists() or (root / member.name).is_symlink():
                    raise ValueError('Duplicate component product')
                names.add(member.name)
        if names != set(receipt['files']):
            raise ValueError('Component file inventory differs')
        for member in members:
            if not (root / member.name).resolve().is_relative_to(root.resolve()):
                raise ValueError('Component extraction escapes its root')
            # Paths/types were checked above. Keep producer modes rather than
            # Python3.14's default data filter stripping group-write bits.
            options = dict(filter='fully_trusted') if hasattr(tarfile, 'fully_trusted_filter') else {}
            bundle.extract(member, root, set_attrs=not member.isdir(), **options)
        for member in sorted((m for m in members if m.isdir()), key=lambda m: len(m.name), reverse=True):
            os.chmod(root / member.name, member.mode)
    if any(entry(root / name) != value for name, value in receipt['files'].items()):
        raise ValueError('Transferred component bytes/modes differ')
    shutil.copyfile(incoming / (component + '.json'), root / 'build-logs' / (component + '-artifact.json'))


def compact_spm(root):
    original, compact = root / 'spm-device', root / '.spm-device-objects'
    compact.mkdir()
    for _, _, path in device_objects(original):
        target = compact / path.relative_to(original)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    shutil.rmtree(original)
    compact.rename(original)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('begin', 'pack', 'unpack', 'compact-spm'))
    parser.add_argument('component', choices=COMPONENTS)
    parser.add_argument('root', type=Path)
    parser.add_argument('transfer', type=Path, nargs='?')
    args = parser.parse_args()
    try:
        if args.action == 'begin': begin(args.component, args.root)
        elif args.action == 'compact-spm': compact_spm(args.root)
        elif args.transfer is None: parser.error('pack/unpack require a transfer directory')
        elif args.action == 'pack': pack(args.component, args.root, args.transfer)
        else: unpack(args.component, args.root, args.transfer)
    except Exception:
        sys.path.insert(0, str(REPO / 'scripts/sim'))
        import sim
        try: sim.report_failure('infra:artifact', 'not retried')
        except OSError: pass
        raise
