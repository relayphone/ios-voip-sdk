#!/usr/bin/env python3
"""The push-entry source proof must bind its transitive console helper."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
import check_push_report_entry as push


class PushSourceInputTests(unittest.TestCase):
    def test_helper_only_edit_invalidates_push_capture_identity(self):
        names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
        with tempfile.TemporaryDirectory(prefix='sim-push-source-') as temporary:
            root = Path(temporary)
            for name in filter(None, names):
                source = ROOT / name
                if source.is_file():
                    target = root / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.read_bytes())
            def git(*args):
                return subprocess.run(['git', '-C', str(root), *args], check=True,
                                      capture_output=True, timeout=30)
            def commit():
                git('add', '.')
                git('-c', 'user.name=Source controls', '-c', 'user.email=sim@example.invalid',
                    '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                    'commit', '-qm', 'Source fixture')
            git('init', '-q')
            git('config', 'gc.auto', '0')
            git('config', 'maintenance.auto', 'false')
            git('config', 'core.fsmonitor', 'false')
            commit()
            with patch.object(push, 'ROOT', root):
                before = push.native_source_identity()
                with (root / 'scripts/sim/sim.py').open('ab') as stream:
                    stream.write(b'\n# helper-only source change\n')
                with self.assertRaises(RuntimeError):
                    push.native_source_identity()
                commit()
                after = push.native_source_identity()
                self.assertNotEqual(before['sourceInputsSHA256'], after['sourceInputsSHA256'])
                self.assertIn('scripts/sim/sim.py', after['inputs'])


if __name__ == '__main__':
    unittest.main()
