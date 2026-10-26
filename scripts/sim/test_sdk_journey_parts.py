"""The opt-in partition preserves the default complete M1 capture seam."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
from check_sdk_m1_container_capture import capture_block


class JourneyPartsTests(unittest.TestCase):
    def test_other_parts_do_not_start_an_m1_journey_or_query_its_container(self):
        for part in ('contracts', 'push-entry'):
            with self.subTest(part=part), tempfile.TemporaryDirectory(prefix='sdk-part-host-') as temporary:
                script = ('set -euo pipefail\nlimit() { return 91; }\npython3() { return 92; }\n' + capture_block())
                result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT,
                    env={**os.environ, 'SDK_M1_ACCEPTANCE': '1', 'SDK_M1_PART': part, 'OUT': temporary},
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(list((Path(temporary) / 'm1').iterdir()), [])

    def test_unknown_part_refuses_before_creating_output_or_contacting_a_simulator(self):
        required = ('SDK_M0_APP', 'SDK_M0_BOOTSTRAP_APP', 'SDK_M0_DEVICE_PROBE',
                    'SDK_M0_SPM_DEVICE_DIR', 'SDK_M0_BUILD_RECEIPT', 'SDK_M0_BUILD_LOGS')
        with tempfile.TemporaryDirectory(prefix='sdk-invalid-part-') as temporary:
            out = Path(temporary) / 'out'
            result = subprocess.run(['/bin/bash', 'discovery/run_sdk_m0.sh'], cwd=ROOT,
                env={**os.environ, **dict.fromkeys(required, 'not-used'), 'SDK_M1_PART': 'unknown', 'OUT': str(out)},
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('Unknown M1 journey part', result.stderr)
            self.assertFalse(out.exists())


if __name__ == '__main__':
    unittest.main()
