#!/usr/bin/env python3
"""Execute M0's real shell seams against the fake native service."""
import json
from pathlib import Path
import shlex
import subprocess
import unittest

import test_sim as fixture_controls


ROOT = Path(__file__).resolve().parents[2]


class ShellAdoptionTests(unittest.TestCase):
    def test_actual_m0_cleanup_failure_is_only_classified_as_infrastructure(self):
        fixture = fixture_controls.LifecycleTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.rules(dict(step='delete', at=[1, 2], action='failure'))
        source = (ROOT / 'discovery/run_sdk_m0.sh').read_text()
        functions = source[source.index('limit() {'):source.index('echo "SDK M0 evidence:')]
        script = '''set -euo pipefail
source scripts/sim/sim.sh
OUT=''' + shlex.quote(str(fixture.root)) + '''
SIM_STATE="$OUT/owned.json"
UDID=''
INHERITED_DYLD=''
PRODUCT_CHECK=fixture-product
''' + functions + '''
UDID=$(limit 2 xcrun simctl create sdk-m0-host-test device runtime)
cleanup_simulator
'''
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=fixture.env,
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        summary = fixture.summary.read_text()
        self.assertIn('infra:delete', summary)
        self.assertNotIn('product:', summary, summary)
        self.assertEqual(len(fixture.calls('delete')), 2)
        fixture.rules()
        fixture.cli('cleanup', fixture.state)
        self.assertEqual(fixture.inventory(), [])

    def test_install_replacement_updates_shell_manifest_identity_and_trap_cleanup(self):
        fixture = fixture_controls.LifecycleTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.rules(dict(step='install', at=[2], action='failure'))
        source = (ROOT / 'discovery/run_sdk_m0.sh').read_text()
        limit = source[source.index('limit() {'):source.index('\ncleanup_simulator()')]
        changed = source[source.index('simulator_changed() {'):source.index('\nredact_external_paths()')]
        start = source.index('limit 180 xcrun simctl install "$UDID" "$SDK_M0_APP"')
        installs = source[start:source.index('\nPRODUCT_CHECK=sdk-m0', start)]
        script = '''set -euo pipefail
source scripts/sim/sim.sh
OUT=''' + shlex.quote(str(fixture.root)) + '''
SIM_STATE="$OUT/owned.json"
UDID=''
trap 'sim_cleanup' EXIT
''' + limit + '\n' + changed + '''
UDID=$(limit 2 xcrun simctl create sdk-m0-host-test device runtime)
OWNED_SIMULATOR=$UDID
printf '{"simulatorID":"%s"}' "$UDID" > "$OUT/environment.json"
printf '%s' "$UDID" > "$OUT/original-id"
limit 2 xcrun simctl boot "$UDID"
limit 2 xcrun simctl bootstatus "$UDID" -b
SDK_M0_APP=example.app
SDK_M0_BOOTSTRAP_APP=bootstrap.app
''' + installs + '''
printf '%s' "$UDID" > "$OUT/final-id"
printf '%s' "$OWNED_SIMULATOR" > "$OUT/manifest-id"
sim_checkpoint
'''
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=fixture.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = (fixture.root / 'original-id').read_text()
        final = (fixture.root / 'final-id').read_text()
        self.assertNotEqual(original, final)
        self.assertEqual((fixture.root / 'manifest-id').read_text(), final)
        self.assertEqual(json.loads((fixture.root / 'environment.json').read_text())['simulatorID'], final)
        self.assertEqual(fixture.calls('install'), [
            ['install', original, 'example.app'], ['install', original, 'bootstrap.app'],
            ['install', final, 'example.app'], ['install', final, 'bootstrap.app']])
        self.assertEqual(fixture.inventory(), [])
        self.assertTrue(json.loads((fixture.root / 'cleanup.json').read_text())['deleted'])
        self.assertIn('infra:install', fixture.summary.read_text())
        self.assertIn('recovered', fixture.summary.read_text())


if __name__ == '__main__':
    unittest.main()
