#!/usr/bin/env python3
"""Run the actual legacy post-capture shell seam with native RPCs refused."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

import test_paths as fixtures
import sdk_m0_conformance as m0
import sdk_m1_contracts_conformance as contracts
from summarize import EvidenceError

ROOT = Path(__file__).resolve().parents[2]


class LegacyCaptureTests(unittest.TestCase):
    def run_capture(self, invalidate=False):
        temporary = tempfile.TemporaryDirectory(prefix='legacy-capture-host-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve() / 'owned evidence'
        root.mkdir()
        capture = fixtures.make_capture(root)
        if invalidate:
            value = json.loads(capture['receipt'].read_text())
            value['launcherAppPID'] += 1
            fixtures.write_json(capture['receipt'], value)
        binary = root / 'bin'; binary.mkdir()
        python = binary / 'python3'
        python.write_text('#!' + sys.executable + '\n' + '''import os,pathlib,runpy,sys
if sys.argv[1] == 'scripts/sim/paths.py':
    from unittest.mock import patch
    with patch('pathlib.Path.home', return_value=pathlib.Path(os.environ['FIXTURE_HOME'])):
        sys.argv = sys.argv[1:]
        runpy.run_path(sys.argv[0], run_name='__main__')
else: os.execv(sys.executable,[sys.executable,*sys.argv[1:]])
''')
        python.chmod(0o755)
        xcrun = binary / 'xcrun'
        xcrun.write_text('#!' + sys.executable + '\n' + '''import os,pathlib,sys
pathlib.Path(os.environ['FIXTURE_RPC']).write_text(repr(sys.argv[1:]))
sys.exit(142)
''')
        xcrun.chmod(0o755)
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        limit = source[source.index('limit() {'):source.index('\ncleanup_simulator()')]
        start = source.index('container=$(limit 30 ')
        block = source[start:source.index('\ncleanup_simulator\n', start)]
        script = 'set -euo pipefail\n' + limit + '\n' + '\n'.join(
            name + '=' + shlex.quote(str(value)) for name, value in dict(
                OUT=capture['trace'].parent, NAME=capture['trace'].stem, UDID=capture['simulator'],
                RUN_ID=capture['run_id'], BUNDLE=capture['bundle']).items()) + '\n' + block
        rpc = root / 'native-rpc-attempt'
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, capture_output=True, text=True,
            timeout=10, env={**os.environ, 'PATH': str(binary) + os.pathsep + os.environ.get('PATH', ''),
                             'FIXTURE_HOME': str(capture['home']), 'FIXTURE_RPC': str(rpc)})
        return result, capture, rpc

    def test_completed_capture_copies_original_journal_and_binds_hash_without_native_rpc(self):
        result, capture, rpc = self.run_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(rpc.exists(), 'completed capture must not invoke any native RPC')
        copied = capture['trace'].with_suffix('.runtime.jsonl')
        self.assertEqual(copied.read_bytes(), capture['journal'].read_bytes())
        receipt = json.loads(capture['receipt'].read_text())
        self.assertEqual(receipt['journalSHA256'], hashlib.sha256(copied.read_bytes()).hexdigest())

    def test_unbound_capture_refuses_before_copy_or_receipt_update(self):
        result, capture, rpc = self.run_capture(invalidate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(rpc.exists())
        self.assertFalse(capture['trace'].with_suffix('.runtime.jsonl').exists())
        self.assertNotIn('journalSHA256', json.loads(capture['receipt'].read_text()))

    def test_lookup_helper_changes_bind_both_source_identities(self):
        with tempfile.TemporaryDirectory(prefix='legacy-source-host-') as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.run(['git', '-C', str(root), *args], check=True,
                                      capture_output=True, timeout=10)
            git('init', '-q')
            for name in (*contracts.OWN_FILES, *contracts.REFERENCES, 'Sources/fixture.swift', 'scripts/sim/paths.py'):
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'host-only source fixture\n')
            def commit():
                git('add', '.')
                git('-c', 'user.name=Legacy capture controls', '-c', 'user.email=sim@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Source fixture')
            commit()
            old_m0, old_contracts = m0.source_identity(root), contracts.source_identity(root)
            with (root / 'scripts/sim/paths.py').open('ab') as stream:
                stream.write(b'lookup-only source change\n')
            with self.assertRaises(EvidenceError): m0.source_identity(root)
            changed = contracts.source_identity(root)
            self.assertTrue(changed['sourceDirty'])
            self.assertNotEqual(old_contracts['sourceInputsSHA256'], changed['sourceInputsSHA256'])
            commit()
            self.assertNotEqual(old_m0['sourceInputsSHA256'], m0.source_identity(root)['sourceInputsSHA256'])
            self.assertFalse(contracts.source_identity(root)['sourceDirty'])


if __name__ == '__main__':
    unittest.main()
