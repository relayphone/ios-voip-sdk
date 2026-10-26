"""Host-only controls for non-authoritative legacy failure diagnostics."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import legacy_diagnostics as diagnostic
import sim

DEVICE = '11111111-1111-4111-8111-111111111111'


class LegacyDiagnosticTests(unittest.TestCase):
    def test_all_stages_are_attempted_after_exception_and_timeout_without_markers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = []
            def runner(command, timeout):
                calls.append((command, timeout))
                if command[0] == 'ps': raise OSError('unavailable')
                if command[2] == 'io': return sim.Result(command,124,timed_out=True)
                return sim.Result(command,0,b'owned app evidence')
            with patch.dict(os.environ, SIM_FAILURE_MARKER=str(root/'marker'), GITHUB_STEP_SUMMARY=str(root/'summary')):
                result = diagnostic.capture(root,DEVICE,runner=runner)
            self.assertEqual([bound for _,bound in calls],[5,20,20])
            self.assertEqual(result['processes'],dict(error='OSError'))
            self.assertTrue(result['screenshot']['timedOut'])
            self.assertEqual(result['logs']['exitCode'],0)
            self.assertEqual((root/'legacy-startup.log').read_bytes(),b'owned app evidence')
            self.assertFalse((root/'marker').exists())
            self.assertFalse((root/'summary').exists())
            self.assertTrue(all(command[3]==DEVICE for command,_ in calls[1:]))
            self.assertEqual(calls[-1][0][4:6],['log','show'])
            self.assertNotIn('get_app_container',repr(calls))

    def test_process_evidence_keeps_only_pid_and_allowlisted_names_and_io_errors_do_not_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def runner(command, timeout):
                return sim.Result(command,0,b'12 /path/SDKM1Contracts\n13 /path/unrelated\n14 /path/simctl\n')
            result = diagnostic.capture(root,DEVICE,runner=runner)
            self.assertEqual(result['processes']['processes'],[dict(pid=12,name='SDKM1Contracts'),dict(pid=14,name='simctl')])
            blocked = root/'blocked'
            blocked.write_text('not a directory')
            calls = []
            def failing_output(command, timeout):
                calls.append(command)
                return sim.Result(command,0)
            diagnostic.capture(blocked,DEVICE,runner=failing_output)
            self.assertEqual(len(calls),3)

    def test_invalid_simulator_refuses_before_any_process(self):
        calls=[]
        with self.assertRaises(ValueError):
            diagnostic.capture(Path('/unused'),'invalid',runner=lambda *args:calls.append(args))
        self.assertEqual(calls,[])


if __name__ == '__main__':
    unittest.main()
