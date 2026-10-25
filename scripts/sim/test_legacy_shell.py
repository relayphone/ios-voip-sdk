#!/usr/bin/env python3
"""Host controls execute the ABI/legacy shell seams with inert native tools."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import unittest

import test_sim as fixture_controls
import test_paths as path_controls


ROOT = Path(__file__).resolve().parents[2]
RUN_ID = '5A8E803D-A3E3-4F25-B13D-D7E73762C8BA'

PYTHON = r'''
import json, os, pathlib, runpy, sys
arguments = sys.argv[1:]
root = pathlib.Path(os.environ['FAKE_SIM_ROOT'])
if arguments[0] == 'discovery/run_scenario.py':
    with (root / 'supervisors.jsonl').open('a') as stream:
        stream.write(json.dumps(arguments[1:]) + '\n')
    with (root / 'supervisor-environments.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(dyld=os.environ.get('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'))) + '\n')
    sys.exit(int(os.environ.get('FAKE_SUPERVISOR_STATUS', '0')))
if arguments[0].endswith('/sim.py') and arguments[1] == 'call':
    with (root / 'helper-commands.jsonl').open('a') as stream:
        stream.write(json.dumps(arguments[1:]) + '\n')
if arguments[0].endswith('/sim.py') and arguments[1] == 'cleanup':
    with (root / 'cleanup-commands.jsonl').open('a') as stream:
        stream.write(json.dumps(arguments[1:]) + '\n')
if arguments[0] == 'scripts/sim/paths.py':
    from unittest.mock import patch
    with patch('pathlib.Path.home', return_value=pathlib.Path(os.environ['FAKE_HOME'])):
        sys.argv = arguments
        runpy.run_path(arguments[0], run_name='__main__')
    sys.exit(0)
os.execv(sys.executable, [sys.executable, *arguments])
'''


class RunnerShellTests(unittest.TestCase):
    def fixture(self):
        fixture = fixture_controls.LifecycleTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        fixture.env.pop('CKSIM_ABI_ONLY', None)
        binary = fixture.root / 'bin'
        python = binary / 'python3'
        python.write_text('#!' + sys.executable + '\n' + PYTHON)
        python.chmod(0o755)
        uuidgen = binary / 'uuidgen'
        uuidgen.write_text('#!/bin/sh\nprintf "%s\\n" ' + RUN_ID + '\n')
        uuidgen.chmod(0o755)
        return fixture

    def run_shell(self, fixture, script):
        return subprocess.run(['/bin/bash', '-c', script], cwd=ROOT, env=fixture.env,
                              capture_output=True, text=True, timeout=30)

    def prefix(self, fixture):
        return '''set -euo pipefail
source scripts/sim/sim.sh
OUT=''' + shlex.quote(str(fixture.root)) + '''
SIM_STATE="$OUT/owned.json"
UDID=''
PRODUCT_CHECK=host-fixture
'''

    def environment_capture(self, mode='changed', override=None, supervisor_status='0'):
        fixture = self.fixture()
        fixture.env.pop('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES', None)
        if override is not None:
            fixture.env['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] = override
        fixture.env['FAKE_DYLD_MODE'] = mode
        fixture.env['FAKE_SUPERVISOR_STATUS'] = supervisor_status
        rules = [dict(step='install', action='failure')]
        if mode == 'exhausted-install':
            rules.append(dict(step='boot', at=[2], action='failure'))
        fixture.rules(*rules)
        native = fixture.root / 'bin/xcrun'
        service = native.read_text().replace("action = rule.get('action')", r'''
if step == 'spawn':
    assert command[2:] == ['launchctl', 'getenv', 'DYLD_INSERT_LIBRARIES'], command
    value = '/host/old/external-first.dylib' if occurrence == 1 else '/host/new/external-second.dylib'
    mode = os.environ['FAKE_DYLD_MODE']
    if occurrence > 1 and mode == 'query-fails':
        print(value)
        sys.stderr.write('environment-query-attempt-2: ' + value + ' unavailable\n')
        sys.exit(73)
    if occurrence > 1 and mode == 'injected': value = '/host/new/CKSimLoader.dylib'
    sys.stderr.write('environment-query-attempt-' + str(occurrence) + ': ' + value + '\n')
    if occurrence > 1 and mode == 'empty': sys.exit(1)
    print(value)
    sys.exit(1 if occurrence > 1 and mode == 'injected' else 0)
action = rule.get('action')
''')
        native.write_text(service)
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('UDID=$(limit 30 xcrun simctl create')
        preparation = source[start:source.index('PRODUCT_CHECK="$NAME"', start)]
        start = source.index('PRODUCT_CHECK="$NAME"')
        scenario = source[start:source.index('\nsim_checkpoint', start)]
        script = self.prefix(fixture) + '''
INHERITED_DYLD=''
RUN_ID=''' + RUN_ID + '''
SDK_M1_CONTRACT_BUILD="$OUT/prebuilt-contract"
BUNDLE=dev.iosvoipsdk.m1contracts
NAME=sdk-m1-contract-audio-lifecycle
RUNTIME=host-runtime
''' + functions + '\n' + preparation + '\n' + scenario
        return fixture, self.run_shell(fixture, script)

    def test_legacy_install_replacement_refreshes_launch_environment_and_redacts_both_values(self):
        fixture, result = self.environment_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        queries = fixture.calls('spawn')
        self.assertEqual(len(queries), 2)
        first, final = [row[1] for row in fixture.calls('install')]
        self.assertNotEqual(first, final)
        self.assertEqual([row[1] for row in queries], [first, final])
        environment = json.loads((fixture.root / 'supervisor-environments.jsonl').read_text())
        self.assertEqual(environment['dyld'], '/host/new/external-second.dylib')
        arguments = json.loads((fixture.root / 'supervisors.jsonl').read_text())
        self.assertEqual(arguments[arguments.index('--timeout') + 1], '90')
        self.assertEqual(arguments[arguments.index('--simulator-id') + 1], final)
        commands = [json.loads(line) for line in (fixture.root / 'helper-commands.jsonl').read_text().splitlines()]
        query_commands = [row for row in commands if 'spawn' in row]
        self.assertEqual([row[row.index('xcrun') - 1] for row in query_commands], ['180', '180'])
        log = (fixture.root / 'launch-environment-query.log').read_text()
        self.assertIn('environment-query-attempt-1', log)
        self.assertIn('environment-query-attempt-2', log)
        self.assertNotIn('/host/old/external-first.dylib', log)
        self.assertNotIn('/host/new/external-second.dylib', log)
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_replacement_sdk_injection_is_refused_before_launch_and_classified_as_product(self):
        fixture, result = self.environment_capture(mode='injected')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('external SDK runtime injection refused', (fixture.root / 'install.log').read_text())
        self.assertEqual(len(fixture.calls('spawn')), 2)
        self.assertFalse((fixture.root / 'supervisors.jsonl').exists())
        self.assertIn('product:legacy-launch-environment', fixture.summary.read_text())
        self.assertNotIn('infra:spawn', fixture.summary.read_text())
        self.assertTrue(fixture.state.with_suffix(fixture.state.suffix + '.failure').exists())
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_replacement_launch_environment_query_failure_cleans_device_without_launch(self):
        fixture, result = self.environment_capture(mode='query-fails')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(fixture.calls('spawn')), 2)
        self.assertFalse((fixture.root / 'supervisors.jsonl').exists())
        summary = fixture.summary.read_text()
        self.assertIn('infra:spawn', summary)
        self.assertNotIn('product:', summary)
        log = (fixture.root / 'launch-environment-query.log').read_text()
        self.assertIn('environment-query-attempt-1', log)
        self.assertIn('environment-query-attempt-2', log)
        self.assertNotIn('/host/old/external-first.dylib', log)
        self.assertNotIn('/host/new/external-second.dylib', log)
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_expected_unset_query_does_not_hide_a_later_product_failure(self):
        fixture, result = self.environment_capture(mode='empty', supervisor_status='73')
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(len(fixture.calls('spawn')), 2)
        environment = json.loads((fixture.root / 'supervisor-environments.jsonl').read_text())
        self.assertEqual(environment['dyld'], '')
        self.assertIn('product:sdk-m1-contract-audio-lifecycle', fixture.summary.read_text())
        self.assertNotIn('infra:spawn', fixture.summary.read_text())
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_exhausted_install_preserves_infrastructure_failure_without_environment_refresh(self):
        fixture, result = self.environment_capture(mode='exhausted-install')
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(len(fixture.calls('spawn')), 1, 'failed replay must not refresh or clear its failure marker')
        self.assertEqual(len(fixture.calls('create')), 2)
        self.assertEqual(len(fixture.calls('install')), 1)
        self.assertFalse((fixture.root / 'supervisors.jsonl').exists())
        summary = fixture.summary.read_text()
        self.assertIn('infra:install', summary)
        self.assertIn('infra:boot', summary)
        self.assertNotIn('product:', summary)
        self.assertTrue(fixture.state.with_suffix(fixture.state.suffix + '.failure').exists())
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_explicit_launch_environment_overrides_skip_both_device_queries(self):
        for override in ('', '/configured/external.dylib'):
            with self.subTest(override=override):
                fixture, result = self.environment_capture(override=override)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(fixture.calls('spawn'), [])
                environment = json.loads((fixture.root / 'supervisor-environments.jsonl').read_text())
                self.assertEqual(environment['dyld'], override)
                self.assertEqual(fixture.inventory(), [])

    def test_abi_install_recovery_binds_replacement_and_preserves_scenario_bounds(self):
        fixture = self.fixture()
        fixture.rules(dict(step='install', action='failure'))
        source = (ROOT / 'discovery/run_abi.sh').read_text()
        functions = source[source.index('limit() {'):source.index('echo "ABI evidence:')]
        start = source.index('UDID=$(limit 30 xcrun simctl create')
        preparation = source[start:source.index('\nfor scenario in ', start)]
        loop_start = source.index('for scenario in ')
        scenarios = source[loop_start:source.index('\nPRODUCT_CHECK=abi-conformance', loop_start)]
        build = fixture.root / 'build'
        (build / 'runtime').mkdir(parents=True)
        (build / 'runtime/CKSimRuntime.dylib').write_bytes(b'host runtime bytes')
        (build / 'Probe.app').mkdir()
        (build / 'Probe.app/Probe').write_bytes(b'host probe bytes')
        script = self.prefix(fixture) + '''
SIM_CLEANUP_TIMEOUT=20
BUILD="$OUT/build"
RUNTIME=host-runtime
''' + functions + preparation + '\n' + scenarios
        result = self.run_shell(fixture, script)
        self.assertEqual(result.returncode, 0, result.stderr)
        first, final = [row[1] for row in fixture.calls('install')]
        self.assertNotEqual(first, final)
        manifest = json.loads((fixture.root / 'manifest.json').read_text())
        self.assertEqual(manifest['simulatorID'], final)
        self.assertIn('runOwnedSimulator=' + final, (fixture.root / 'environment.txt').read_text())
        calls = [json.loads(line) for line in (fixture.root / 'supervisors.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 13)
        for arguments in calls:
            self.assertEqual(arguments[arguments.index('--timeout') + 1], '200')
            self.assertEqual(arguments[arguments.index('--simulator-id') + 1], final)
            self.assertEqual(arguments[arguments.index('--launch-command') + 1:],
                             ['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process',
                              final, 'dev.callkitsim.abi'])
        cleanups = [json.loads(line) for line in (fixture.root / 'cleanup-commands.jsonl').read_text().splitlines()]
        self.assertEqual(cleanups[-1][-2:], ['--timeout', '20'])
        self.assertTrue(json.loads(fixture.state.read_text())['checkpoint'])
        self.assertEqual(fixture.inventory(), [])
        self.assertFalse(build.exists(), 'the actual ABI trap must remove its build products')

    def test_legacy_completed_capture_reads_journal_with_all_container_rpcs_refused(self):
        fixture = self.fixture()
        capture = path_controls.make_capture(fixture.root)
        fixture.env['FAKE_HOME'] = str(capture['home'])
        native = fixture.root / 'bin/xcrun'
        service = native.read_text().replace(
            "str(uuid.uuid5(uuid.NAMESPACE_URL, 'helper-fixture-' + str(occurrence)))",
            repr(capture['simulator']))
        service = service.replace("step = command[0]", "step = command[0]\nif step == 'get_app_container': sys.exit(142)")
        native.write_text(service)
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('PRODUCT_CHECK="$NAME"')
        capture_block = source[start:source.index('\ncleanup_simulator\n', start)]
        script = self.prefix(fixture) + '''
INHERITED_DYLD=''
RUN_ID=''' + shlex.quote(capture['run_id']) + '''
BUNDLE=''' + shlex.quote(capture['bundle']) + '''
NAME=''' + shlex.quote(capture['trace'].stem) + '''
''' + functions + '''
UDID=$(limit 2 xcrun simctl create legacy-host device runtime)
OUT=''' + shlex.quote(str(capture['trace'].parent)) + '\n' + capture_block
        result = self.run_shell(fixture, script)
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = capture['trace'].with_suffix('.runtime.jsonl')
        self.assertEqual(copied.read_bytes(), capture['journal'].read_bytes())
        receipt = json.loads(capture['receipt'].read_text())
        self.assertEqual(receipt['journalSHA256'], hashlib.sha256(copied.read_bytes()).hexdigest())
        self.assertFalse(fixture.calls('get_app_container'))
        self.assertTrue(json.loads(fixture.state.read_text())['checkpoint'])
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_supervisor_failure_is_not_replayed_and_cleans_owned_device(self):
        fixture = self.fixture()
        fixture.env['FAKE_SUPERVISOR_STATUS'] = '73'
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('PRODUCT_CHECK="$NAME"')
        scenario = source[start:source.index('\nsim_checkpoint', start)]
        script = self.prefix(fixture) + '''
INHERITED_DYLD=''
RUN_ID=''' + RUN_ID + '''
BUNDLE=dev.iosvoipsdk.m1contracts
NAME=sdk-m1-contract-audio-lifecycle
''' + functions + '''
UDID=$(limit 2 xcrun simctl create legacy-host device runtime)
''' + scenario
        result = self.run_shell(fixture, script)
        self.assertEqual(result.returncode, 73, result.stderr)
        calls = [json.loads(line) for line in (fixture.root / 'supervisors.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index('--timeout') + 1], '90')
        self.assertIn('product:sdk-m1-contract-audio-lifecycle', fixture.summary.read_text())
        self.assertNotIn('infra:', fixture.summary.read_text())
        self.assertEqual(fixture.inventory(), [])

    def test_legacy_explicit_cleanup_failure_never_gets_a_product_label(self):
        fixture = self.fixture()
        fixture.rules(dict(step='delete', at=[1, 2], action='failure'))
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        script = self.prefix(fixture) + '''
INHERITED_DYLD=''
''' + functions + '''
UDID=$(limit 2 xcrun simctl create legacy-host device runtime)
cleanup_simulator
'''
        result = self.run_shell(fixture, script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('infra:delete', fixture.summary.read_text())
        self.assertNotIn('product:', fixture.summary.read_text())
        self.assertEqual(len(fixture.calls('delete')), 2)
        fixture.rules()
        fixture.cli('cleanup', fixture.state)
        self.assertEqual(fixture.inventory(), [])


if __name__ == '__main__':
    unittest.main()
