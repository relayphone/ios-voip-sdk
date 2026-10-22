#!/usr/bin/env python3
"""Exercise loaded-image identity failures; optionally qualify a native capture."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import tempfile

from conformance import bound_capture
from summarize import build_identity, EvidenceError, require


def controls():
    with tempfile.TemporaryDirectory(prefix='cksim-identity-') as temporary:
        root = Path(temporary)
        package = root / 'runtime-dist'
        (package / 'profiles').mkdir(parents=True)
        runtime = package / 'CKSimRuntime.dylib'
        profile = package / 'profiles/ios-27.0.json'
        runtime.write_bytes(b'synthetic runtime fixture')
        profile.write_bytes(b'synthetic profile fixture')
        manifest = dict(schemaVersion=1, profileID='ios-27.0', runID='fixture', simulatorID='fixture',
                        runtimeSHA256=hashlib.sha256(runtime.read_bytes()).hexdigest(),
                        profileSHA256=hashlib.sha256(profile.read_bytes()).hexdigest(),
                        probeSHA256=hashlib.sha256(b'synthetic probe fixture').hexdigest())
        rows = [dict(event='launch', runID='fixture', simulatorID='fixture', injected=True),
                dict(event='runtime.identity', version='0.1.0',
                     **{key: manifest[key] for key in ('runtimeSHA256', 'profileSHA256', 'probeSHA256')})]
        checks = []

        def check(label, mutate=None):
            current = copy.deepcopy(rows)
            (root / 'manifest.json').write_text(json.dumps(manifest))
            if mutate:
                mutate(current)
            try:
                build_identity(root, current)
            except (EvidenceError, OSError):
                require(mutate is not None, 'positive identity fixture rejected')
            else:
                require(mutate is None, f'{label}: corrupt identity accepted')
            checks.append(label)

        check('synthetic-positive')
        for key in ('runtimeSHA256', 'profileSHA256', 'probeSHA256'):
            check('wrong-loaded-' + key, lambda r, key=key: r[1].update({key: '0' * 64}))
            check('missing-loaded-' + key, lambda r, key=key: r[1].pop(key))
        check('missing-runtime-identity', lambda r: r.pop())
        check('duplicate-runtime-identity', lambda r: r.append(dict(r[1])))
        for path, label in ((runtime, 'runtime'), (profile, 'profile')):
            original = path.read_bytes()
            check('tampered-package-' + label, lambda r, path=path: path.write_bytes(b'tampered'))
            path.write_bytes(original)
        return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path)
    parser.add_argument('--scenario', default='report-threading')
    args = parser.parse_args()
    checks = controls()
    if args.capture:
        rows, _ = bound_capture(args.capture, args.scenario)
        build_identity(args.capture, rows)
        checks.append('native-loaded-image-and-package')
    print(json.dumps(dict(success=True, checks=checks), indent=2))


if __name__ == '__main__':
    main()
