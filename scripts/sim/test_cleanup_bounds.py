#!/usr/bin/env python3
"""Interruption must retain the runner's cleanup bound in every CLI action."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).with_name('sim.py')
PROBE = '''
import json, runpy, sys
helper = runpy.run_path(sys.argv[1])
action, path = sys.argv[2:]
observed = dict(cleanups=[])
class Session:
    def __init__(self, path, recovery_timeout=30):
        self.recovery_timeout = float(recovery_timeout)
        observed['configured'] = self.recovery_timeout
    def call(self, *args): raise helper['Interrupted'](15)
    def checkpoint(self): raise helper['Interrupted'](15)
    @property
    def current(self): raise helper['Interrupted'](15)
    def cleanup(self, timeout=30):
        observed['cleanups'].append(timeout)
        if action == 'cleanup' and len(observed['cleanups']) == 1:
            raise helper['Interrupted'](15)
        return helper['Result']([], 0)
helper['main'].__globals__['Session'] = Session
argv = ([action, path, '2', 'native'] if action == 'call' else
        [action, path, '--timeout', '12'] if action == 'cleanup' else [action, path])
result = helper['main'](argv)
print(json.dumps(observed))
sys.exit(result)
'''


class InterruptedBoundsTests(unittest.TestCase):
    def test_all_interrupted_cli_actions_retain_the_configured_bound(self):
        with tempfile.TemporaryDirectory(prefix='sim-interruption-bounds-') as temporary:
            state = Path(temporary) / 'state.json'
            state.touch()
            for action in ('call', 'current', 'checkpoint', 'cleanup'):
                with self.subTest(action=action):
                    result = subprocess.run([sys.executable, '-c', PROBE, str(HELPER), action, str(state)],
                        env=dict(os.environ, SIM_RECOVERY_TIMEOUT='20'), capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 143, result.stderr)
                    observed = json.loads(result.stdout)
                    self.assertEqual(observed['configured'], 20)
                    self.assertEqual(observed['cleanups'], [12, 12] if action == 'cleanup' else [20])


if __name__ == '__main__':
    unittest.main()
