import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class DryRunTests(unittest.TestCase):
    def run_plan(self, row, *args):
        return subprocess.run(["/bin/bash", str(HERE / "run.sh"), row, "--dry-run", *args],
                              capture_output=True, text=True, timeout=10)

    def test_full_matrix_and_no_credentials_required(self):
        for n in range(1, 17):
            result = self.run_plan(f"F{n:02}")
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual(plan["focus"], n > 8)
            self.assertEqual(plan["cn"], n % 2 == 0)
        self.assertTrue(json.loads(self.run_plan("F03").stdout)["app"])
        self.assertTrue(json.loads(self.run_plan("F05").stdout)["person"])

    def test_dry_run_does_not_execute_device_or_microphone_commands(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ["xcrun", "xcodebuild", "node", "swiftc"]:
                path = Path(folder) / name
                path.write_text("#!/bin/sh\necho UNEXPECTED_EXECUTION >&2\nexit 99\n")
                path.chmod(0o700)
            env = {**os.environ, "PATH": folder + ":" + os.environ["PATH"]}
            result = subprocess.run(["/bin/bash", str(HERE / "run.sh"), "F01", "--dry-run", "--locked-auto-answer", "--listen"],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("end UI session", result.stdout)
            self.assertNotIn("UNEXPECTED_EXECUTION", result.stderr)

    def test_unknown_rows_fail_and_restore_sends_no_push(self):
        self.assertNotEqual(self.run_plan("F99").returncode, 0)
        plan = json.loads(self.run_plan("restore-all").stdout)
        self.assertFalse(plan["sendVoIP"])


if __name__ == "__main__":
    unittest.main()
