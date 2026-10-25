#!/usr/bin/env python3
"""Acceptance identities must include the helpers that operate their simulator."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import sdk_m0_conformance as m0
import sdk_m1_contracts_conformance as contracts
from summarize import EvidenceError


class SourceInputTests(unittest.TestCase):
    def test_helper_only_changes_bind_hashes_and_dirtiness(self):
        with tempfile.TemporaryDirectory(prefix='sim-helper-identity-') as temporary:
            root = Path(temporary)
            def git(*command):
                return subprocess.run(['git', '-C', str(root), *command], check=True,
                                      capture_output=True, timeout=10)
            git('init', '-q')
            for name in (*contracts.OWN_FILES, *contracts.REFERENCES, 'Sources/fixture.swift',
                         'scripts/sim/sim.py', 'scripts/sim/sim.sh', 'scripts/sim/paths.py'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'host-only source fixture\n')
            def commit():
                git('add', '.')
                git('-c', 'user.name=Simulator controls', '-c', 'user.email=sim@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Source fixture')
            commit()
            for name in ('scripts/sim/sim.py', 'scripts/sim/sim.sh', 'scripts/sim/paths.py'):
                before_m0 = m0.source_identity(root)
                before_contract = contracts.source_identity(root)
                self.assertFalse(before_contract['sourceDirty'])
                with (root / name).open('ab') as stream:
                    stream.write(b'helper-only modification\n')
                with self.assertRaises(EvidenceError):
                    m0.source_identity(root)
                dirty = contracts.source_identity(root)
                self.assertTrue(dirty['sourceDirty'])
                self.assertNotEqual(before_contract['sourceInputsSHA256'], dirty['sourceInputsSHA256'])
                commit()
                self.assertNotEqual(before_m0['sourceInputsSHA256'], m0.source_identity(root)['sourceInputsSHA256'])
                self.assertFalse(contracts.source_identity(root)['sourceDirty'])


if __name__ == '__main__':
    unittest.main()
