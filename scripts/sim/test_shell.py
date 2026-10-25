#!/usr/bin/env python3
"""Execute M0's real shell seams against the fake native service."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
import unittest

import test_sim as fixture_controls


ROOT = Path(__file__).resolve().parents[2]


class ShellAdoptionTests(unittest.TestCase):
    def capture_launch_environment(self, rules=(), override=None, replacement=True,
                                   install_failures=(2,), helper_error=False):
        fixture = fixture_controls.LifecycleTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        if replacement:
            fixture.rules(dict(step='install', at=list(install_failures), action='failure'))
        (fixture.root / 'environment-rules.json').write_text(json.dumps(rules))
        native = fixture.root / 'bin/xcrun-native'
        (fixture.root / 'bin/xcrun').rename(native)
        query = fixture.root / 'bin/xcrun'
        query.write_text('#!' + sys.executable + '\n' + '''
import json,os,pathlib,sys,time
root=pathlib.Path(os.environ['FAKE_SIM_ROOT'])
if sys.argv[1:3] != ['simctl','spawn']:
    os.execv(str(root/'bin/xcrun-native'),[str(root/'bin/xcrun-native'),*sys.argv[1:]])
assert sys.argv[4:] == ['launchctl','getenv','DYLD_INSERT_LIBRARIES']
path=root/'environment-queries.jsonl'
rows=path.read_text().splitlines() if path.exists() else []
with path.open('a') as stream: stream.write(json.dumps(sys.argv[3:])+'\\n')
rules=json.loads((root/'environment-rules.json').read_text())
rule=rules[len(rows)] if len(rows)<len(rules) else {}
if rule.get('timeout'): time.sleep(30)
value=rule.get('value','/external/'+sys.argv[3]+'/host.dylib')
if value: print(value)
sys.exit(rule.get('status',0))
''')
        query.chmod(0o755)
        # Assert the production query still requests 180s, then shorten only
        # this host fixture so a real timeout remains a fast regression.
        python = fixture.root / 'bin/python3'
        python.write_text('#!' + sys.executable + '\n' + '''
import os,sys
args=sys.argv[1:]
if len(args)>7 and args[0].endswith('/scripts/sim/sim.py') and args[1]=='call':
    state=2
    if args[2]=='--accepted-status':
        assert args[3]=='1',args
        state=4
    if args[state]=='' and args[state+2:state+5]==['xcrun','simctl','spawn']:
        assert args[state+1]=='180',args
        args[state+1]='2'
        if os.environ.get('FAKE_QUERY_HELPER_ERROR')=='1':
            import runpy
            helper=runpy.run_path(args[0])
            def broken(*arguments): raise OSError('host-only bounded transport failure')
            helper['main'].__globals__['bounded']=broken
            sys.exit(helper['main'](args[1:]))
os.execv(sys.executable,[sys.executable,*args])
''')
        python.chmod(0o755)
        source = (ROOT / 'discovery/run_sdk_m0.sh').read_text()
        functions = source[source.index('limit() {'):source.index('echo "SDK M0 evidence:')]
        if 'read_launch_environment() {' not in functions:
            start = source.index('if [[ -n "${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES+x}" ]]; then')
            end = source.index('python3 - "$OUT" "$UDID"', start)
            functions += '\nread_launch_environment() {\n' + source[start:end] + '\n}\n'
        start = source.index('limit 180 xcrun simctl install "$UDID" "$SDK_M0_APP"')
        installs = source[start:source.index('\nPRODUCT_CHECK=sdk-m0', start)]
        script = '''set -euo pipefail
source scripts/sim/sim.sh
OUT=''' + shlex.quote(str(fixture.root)) + '''
SIM_STATE="$OUT/owned.json"
UDID=''
INHERITED_DYLD=''
PRODUCT_CHECK=preflight
''' + functions + '''
UDID=$(limit 2 xcrun simctl create sdk-m0-host-test device runtime)
OWNED_SIMULATOR=$UDID
printf '{"simulatorID":"%s"}' "$UDID" > "$OUT/environment.json"
printf '%s' "$UDID" > "$OUT/original-id"
limit 2 xcrun simctl boot "$UDID"
limit 2 xcrun simctl bootstatus "$UDID" -b
read_launch_environment
printf '%s' "$INHERITED_DYLD" > "$OUT/original-dyld"
SDK_M0_APP=example.app
SDK_M0_BOOTSTRAP_APP=bootstrap.app
''' + installs + '''
printf '%s' "$UDID" > "$OUT/final-id"
printf '%s' "$INHERITED_DYLD" > "$OUT/final-dyld"
printf '%s\\n%s\\n' "$(cat "$OUT/original-dyld")" "$INHERITED_DYLD" > "$OUT/host-paths.log"
[[ ! -f "$SIM_STATE.failure" ]]
printf 'launch boundary reached' > "$OUT/launched"
'''
        environment = dict(fixture.env)
        environment.pop('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES', None)
        if override is not None:
            environment['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] = override
        if helper_error:
            environment['FAKE_QUERY_HELPER_ERROR'] = '1'
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=environment,
                                capture_output=True, text=True, timeout=20)
        queries = fixture.root / 'environment-queries.jsonl'
        observed = [json.loads(line) for line in queries.read_text().splitlines()] if queries.exists() else []
        self.assertEqual(fixture.inventory(), [], result.stderr)
        return result, fixture, observed

    def test_replacement_refreshes_device_environment_and_redacts_both_values(self):
        result, fixture, queries = self.capture_launch_environment()
        self.assertEqual(result.returncode, 0, result.stderr)
        old = (fixture.root / 'original-id').read_text()
        new = (fixture.root / 'final-id').read_text()
        self.assertNotEqual(old, new)
        self.assertEqual([query[0] for query in queries], [old, new])
        self.assertEqual((fixture.root / 'final-dyld').read_text(), '/external/' + new + '/host.dylib')
        log = (fixture.root / 'host-paths.log').read_text()
        self.assertEqual(log.count('<inherited-external-library>'), 2)
        self.assertNotIn('/external/', log)
        query_log = (fixture.root / 'launch-environment-query.log').read_text()
        self.assertEqual(query_log.count('Query exit code:'), 2)

    def test_replacement_sdk_injection_is_refused_before_launch(self):
        result, fixture, queries = self.capture_launch_environment([
            {}, dict(value='/external/replacement/CKSimLoader.dylib')])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(queries), 2)
        self.assertFalse((fixture.root / 'launched').exists())
        self.assertIn('product:preflight', fixture.summary.read_text())

    def test_replacement_environment_query_failure_or_timeout_refuses_launch(self):
        for rule in (dict(status=73), dict(status=125), dict(timeout=True)):
            with self.subTest(rule=rule):
                result, fixture, queries = self.capture_launch_environment([{}, rule])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(queries), 2)
                self.assertFalse((fixture.root / 'launched').exists())
                self.assertIn('infra:spawn', fixture.summary.read_text())
                self.assertTrue(Path(str(fixture.state) + '.failure').exists())
                self.assertNotIn('product:', fixture.summary.read_text())

    def test_initial_environment_query_failure_still_precedes_every_install(self):
        result, fixture, queries = self.capture_launch_environment([dict(status=73)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(queries), 1)
        self.assertEqual(fixture.calls('install'), [])
        self.assertFalse((fixture.root / 'launched').exists())

    def test_initial_sdk_injection_refusal_still_precedes_every_install(self):
        library = '/external/CKSimRuntime.dylib'
        for override in (None, library):
            with self.subTest(explicit_override=override is not None):
                result, fixture, queries = self.capture_launch_environment([dict(value=library)], override=override)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(queries), 1 if override is None else 0)
                self.assertEqual(fixture.calls('install'), [])
                self.assertFalse((fixture.root / 'launched').exists())
                self.assertIn('product:preflight', fixture.summary.read_text())

    def test_same_device_does_not_repeat_environment_query(self):
        result, fixture, queries = self.capture_launch_environment(replacement=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(queries), 1)
        self.assertEqual((fixture.root / 'original-id').read_text(), (fixture.root / 'final-id').read_text())

    def test_explicit_empty_override_avoids_initial_and_replacement_queries(self):
        result, fixture, queries = self.capture_launch_environment(override='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(queries, [])
        self.assertEqual((fixture.root / 'final-dyld').read_text(), '')
        self.assertTrue((fixture.root / 'launched').exists())

    def test_last_install_refresh_accepts_unset_exit_without_failure_marker(self):
        result, fixture, queries = self.capture_launch_environment([{}, dict(status=1, value='')])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(queries), 2)
        self.assertEqual((fixture.root / 'final-dyld').read_text(), '')
        self.assertFalse(Path(str(fixture.state) + '.failure').exists())
        self.assertNotIn('infra:spawn', fixture.summary.read_text())

    def test_exhausted_install_preserves_infrastructure_marker_and_skips_refresh(self):
        result, fixture, queries = self.capture_launch_environment(install_failures=(2, 3))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(queries), 1)
        self.assertFalse((fixture.root / 'launched').exists())
        self.assertTrue(Path(str(fixture.state) + '.failure').exists())
        summary = fixture.summary.read_text()
        self.assertIn('infra:install', summary)
        self.assertNotIn('product:', summary)
        current = json.loads((fixture.root / 'environment.json').read_text())['simulatorID']
        self.assertNotEqual(current, (fixture.root / 'original-id').read_text())
        self.assertEqual(json.loads((fixture.root / 'cleanup.json').read_text())['simulatorID'], current)

    def test_initial_unset_environment_has_no_infrastructure_label(self):
        result, fixture, queries = self.capture_launch_environment([dict(status=1, value='')], replacement=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(queries), 1)
        self.assertFalse(fixture.summary.exists(), fixture.summary.read_text() if fixture.summary.exists() else '')

    def test_helper_transport_error_is_not_accepted_as_unset_environment(self):
        result, fixture, queries = self.capture_launch_environment(helper_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(queries, [])
        self.assertEqual(fixture.calls('install'), [])
        self.assertFalse((fixture.root / 'launched').exists())
        self.assertTrue(Path(str(fixture.state) + '.failure').exists())
        self.assertIn('infra:helper', fixture.summary.read_text())
        self.assertNotIn('product:', fixture.summary.read_text())

    def test_accepted_status_scope_does_not_accept_lifecycle_failure(self):
        fixture = fixture_controls.LifecycleTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.rules(dict(step='install', at=[1, 2], action='failure'))
        script = '''set -euo pipefail
source scripts/sim/sim.sh
SIM_STATE=''' + shlex.quote(str(fixture.state)) + '''
UDID=''
trap 'sim_cleanup' EXIT
UDID=$(sim_limit 2 xcrun simctl create test-owned device runtime)
SIM_ACCEPTED_STATUS=73 sim_limit 2 xcrun simctl install "$UDID" fixture.app
'''
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=fixture.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(len(fixture.calls('install')), 2)
        self.assertTrue(Path(str(fixture.state) + '.failure').exists())
        self.assertIn('infra:install', fixture.summary.read_text())
        self.assertEqual(fixture.inventory(), [])

    def test_invalid_stateless_scope_does_not_accept_reserved_helper_status(self):
        fixture = fixture_controls.LifecycleTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.rules(dict(step='spawn', action='reserved-failure'))
        script = '''set -euo pipefail
source scripts/sim/sim.sh
SIM_STATE=''' + shlex.quote(str(fixture.state)) + '''
UDID=''
trap 'sim_cleanup' EXIT
UDID=$(sim_limit 2 xcrun simctl create test-owned device runtime)
SIM_ACCEPTED_STATUS=125 sim_limit 2 xcrun simctl spawn "$UDID" launchctl getenv ANYTHING
'''
        result = subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=fixture.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertEqual(len(fixture.calls('spawn')), 1)
        self.assertTrue(Path(str(fixture.state) + '.failure').exists())
        self.assertIn('infra:spawn', fixture.summary.read_text())
        self.assertEqual(fixture.inventory(), [])

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
