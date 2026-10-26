#!/usr/bin/env python3
"""Host controls execute the legacy shell seams with inert native tools."""
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
        stream.write(json.dumps(dict(dyld=os.environ.get('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'), checkpoint=json.loads((root/'owned.json').read_text())['checkpoint'])) + '\n')
    sys.exit(int(os.environ.get('FAKE_SUPERVISOR_STATUS', '0')))
if arguments[0] == 'scripts/sim/legacy_diagnostics.py':
    with (root/'diagnostics.jsonl').open('a') as stream:
        stream.write(json.dumps(arguments[1:])+'\n')
    sys.exit(int(os.environ.get('FAKE_DIAGNOSTIC_STATUS','0')))
if arguments[0].endswith('/sim.py') and arguments[1] == 'call':
    with (root / 'helper-commands.jsonl').open('a') as stream:
        stream.write(json.dumps(arguments[1:]) + '\n')
if arguments[0].endswith('/sim.py') and arguments[1] == 'call' and arguments[4:] == ['xcrun','simctl','list','runtimes','-j']:
    assert arguments[3] == '60', arguments
    arguments[3] = '3'  # Exercise a real timeout without waiting sixty seconds.
if arguments[0].endswith('/sim.py') and arguments[1] == 'call' and 'scripts/sim/paths.py' in arguments and os.environ.get('FAKE_PATHS_TIMEOUT'):
    assert arguments[3] == '30', arguments
    arguments[3] = '3'
if arguments[0].endswith('/sim.py') and arguments[1] == 'cleanup':
    with (root / 'cleanup-commands.jsonl').open('a') as stream:
        stream.write(json.dumps(arguments[1:]) + '\n')
if arguments[0] == 'scripts/sim/paths.py':
    if os.environ.get('FAKE_PATHS_TIMEOUT'):
        import time
        time.sleep(60)
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

    def listing_capture(self, *rules):
        fixture = self.fixture()
        fixture.env['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] = ''
        fixture.rules(*rules)
        native = fixture.root / 'bin/xcrun'
        service = native.read_text().replace(
            "elif step == 'list': print(json.dumps(dict(devices={'runtime': native['devices']})))",
            "elif step == 'list': print(json.dumps(dict(runtimes=[dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-26-5',platform='iOS',isAvailable=True,version='26.5',buildversion='host')])) if command[1:] == ['runtimes','-j'] else json.dumps(dict(devices={'runtime': native['devices']})))")
        native.write_text(service)
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('RUNTIME_JSON=$(limit 60 ')
        preparation = source[start:source.index('sim_checkpoint ||', start)]
        script = self.prefix(fixture) + """
INHERITED_DYLD=''
RUN_ID=""" + RUN_ID + """
SDK_M1_CONTRACT_BUILD="$OUT/prebuilt-contract"
BUNDLE=dev.iosvoipsdk.m1contracts
NAME=sdk-m1-contract-audio-lifecycle
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5
""" + functions + '\n' + preparation
        return fixture, self.run_shell(fixture, script)

    def test_listing_timeout_recovers_before_create_without_inventing_owned_cleanup(self):
        fixture, result = self.listing_capture(dict(step='list', action='timeout'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([row[0] for row in fixture.calls()],
                         ['list','list','create','boot','bootstatus','install','shutdown','delete'])
        self.assertEqual(len(fixture.calls('create')), 1)
        state = json.loads(fixture.state.read_text())
        self.assertTrue(state['retry_used'])
        self.assertFalse(state['checkpoint'])
        commands = [json.loads(line) for line in (fixture.root/'helper-commands.jsonl').read_text().splitlines()]
        listing = next(row for row in commands if row[-3:] == ['list','runtimes','-j'])
        self.assertEqual(listing[listing.index('xcrun')-1], '60')
        self.assertIn('infra:list', fixture.summary.read_text())
        self.assertIn('recovered', fixture.summary.read_text())
        self.assertNotIn('product:', fixture.summary.read_text())
        self.assertEqual(fixture.inventory(), [])

    def test_listing_exhaustion_does_not_create_or_replay_an_app(self):
        fixture, result = self.listing_capture(dict(step='list', at=[1,2], action='timeout'))
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual([row[0] for row in fixture.calls()], ['list','list'])
        self.assertEqual(fixture.inventory(), [])
        self.assertTrue(json.loads(fixture.state.read_text())['retry_used'])
        self.assertFalse((fixture.root/'supervisors.jsonl').exists())
        self.assertIn('infra:list', fixture.summary.read_text())
        self.assertNotIn('product:', fixture.summary.read_text())

    def test_listing_retry_exhausts_the_later_install_budget(self):
        fixture, result = self.listing_capture(dict(step='list', action='timeout'),
                                             dict(step='install', action='failure'))
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(len(fixture.calls('list')), 2)
        self.assertEqual(len(fixture.calls('create')), 1)
        self.assertEqual(len(fixture.calls('install')), 1)
        self.assertEqual(len(fixture.calls('delete')), 1)
        self.assertFalse((fixture.root/'supervisors.jsonl').exists())
        self.assertEqual(fixture.inventory(), [])
        self.assertIn('infra:install', fixture.summary.read_text())
        self.assertNotIn('product:', fixture.summary.read_text())

    def test_successful_listing_leaves_one_install_recovery_available(self):
        fixture, result = self.listing_capture(dict(step='install', action='failure'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(fixture.calls('list')), 1)
        self.assertEqual(len(fixture.calls('create')), 2)
        self.assertEqual(len(fixture.calls('install')), 2)
        self.assertNotEqual(*[row[1] for row in fixture.calls('install')])
        self.assertEqual(fixture.inventory(), [])

    def test_non_timeout_listing_failure_has_no_automatic_retry(self):
        fixture, result = self.listing_capture(dict(step='list', action='failure'))
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual([row[0] for row in fixture.calls()], ['list'])
        self.assertFalse(json.loads(fixture.state.read_text())['retry_used'])
        self.assertEqual(fixture.inventory(), [])

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
        preparation = source[start:source.index('sim_checkpoint ||', start)]
        start = source.index('sim_checkpoint ||')
        scenario = source[start:source.index('\nPRODUCT_CHECK=legacy-journal-capture', start)]
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
        self.assertFalse(fixture.state.with_suffix(fixture.state.suffix + '.failure').exists())
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

    def completed_capture(self, invalidate=False, timeout=False, external_marker=False):
        fixture = self.fixture()
        capture = path_controls.make_capture(fixture.root)
        if invalidate:
            value = json.loads(capture['receipt'].read_text())
            value['launcherAppPID'] += 1
            path_controls.write_json(capture['receipt'], value)
        fixture.env['FAKE_HOME'] = str(capture['home'])
        if timeout:
            fixture.env['FAKE_PATHS_TIMEOUT'] = '1'
        if external_marker:
            fixture.env['SIM_FAILURE_MARKER'] = str(fixture.root/'external.failure')
        native = fixture.root / 'bin/xcrun'
        service = native.read_text().replace(
            "str(uuid.uuid5(uuid.NAMESPACE_URL, 'helper-fixture-' + str(occurrence)))",
            repr(capture['simulator']))
        service = service.replace("step = command[0]", "step = command[0]\nif step == 'get_app_container': sys.exit(142)")
        native.write_text(service)
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('sim_checkpoint ||')
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
        return fixture, result, capture

    def test_legacy_completed_capture_reads_journal_with_all_container_rpcs_refused(self):
        fixture, result, capture = self.completed_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = capture['trace'].with_suffix('.runtime.jsonl')
        self.assertEqual(copied.read_bytes(), capture['journal'].read_bytes())
        receipt = json.loads(capture['receipt'].read_text())
        self.assertEqual(receipt['journalSHA256'], hashlib.sha256(copied.read_bytes()).hexdigest())
        self.assertFalse(fixture.calls('get_app_container'))
        self.assertTrue(json.loads(fixture.state.read_text())['checkpoint'])
        self.assertEqual(fixture.inventory(), [])

    def test_invalid_completed_capture_preserves_product_classification_and_cleans_device(self):
        fixture, result, capture = self.completed_capture(invalidate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('product:legacy-journal-capture', fixture.summary.read_text())
        self.assertNotIn('infra:', fixture.summary.read_text())
        self.assertFalse(capture['trace'].with_suffix('.runtime.jsonl').exists())
        self.assertNotIn('journalSHA256', json.loads(capture['receipt'].read_text()))
        self.assertFalse(fixture.calls('get_app_container'))
        self.assertEqual(fixture.inventory(), [])

    def test_capture_host_timeout_is_infrastructure_without_product_fallback_or_app_replay(self):
        for external in (False, True):
            with self.subTest(external_marker=external):
                fixture, result, capture = self.completed_capture(timeout=True, external_marker=external)
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertIn('infra:host', fixture.summary.read_text())
                self.assertNotIn('product:', fixture.summary.read_text())
                marker = fixture.root/'external.failure' if external else Path(str(fixture.state)+'.failure')
                self.assertTrue(marker.exists())
                self.assertEqual(len((fixture.root/'supervisors.jsonl').read_text().splitlines()), 1)
                self.assertTrue(json.loads(fixture.state.read_text())['checkpoint'])
                self.assertFalse(json.loads(fixture.state.read_text())['retry_used'])
                self.assertFalse(capture['trace'].with_suffix('.runtime.jsonl').exists())
                self.assertFalse(fixture.calls('get_app_container'))
                self.assertEqual(fixture.inventory(), [])

    def test_legacy_supervisor_failure_is_not_replayed_and_cleans_owned_device(self):
        fixture = self.fixture()
        fixture.env['FAKE_SUPERVISOR_STATUS'] = '73'
        fixture.env['FAKE_DIAGNOSTIC_STATUS'] = '91'
        source = (ROOT / 'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('sim_checkpoint ||')
        scenario = source[start:source.index('\nPRODUCT_CHECK=legacy-journal-capture', start)]
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
        self.assertTrue(json.loads((fixture.root/'supervisor-environments.jsonl').read_text())['checkpoint'])
        self.assertEqual(len((fixture.root/'diagnostics.jsonl').read_text().splitlines()), 1)
        calls = [json.loads(line) for line in (fixture.root / 'supervisors.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index('--timeout') + 1], '90')
        self.assertIn('product:sdk-m1-contract-audio-lifecycle', fixture.summary.read_text())
        self.assertNotIn('infra:', fixture.summary.read_text())
        self.assertEqual(fixture.inventory(), [])

    def test_scenario_failure_survives_diagnostic_and_cleanup_failure(self):
        fixture = self.fixture()
        fixture.env['FAKE_SUPERVISOR_STATUS'] = '73'
        fixture.env['FAKE_DIAGNOSTIC_STATUS'] = '91'
        fixture.rules(dict(step='delete', at=[1], action='failure'))
        source = (ROOT/'discovery/run_audio_lifecycle_legacy.sh').read_text()
        functions = source[source.index('limit() {'):source.index('python3 - "$SDK_M1_CONTRACT_BUILD"')]
        start = source.index('sim_checkpoint ||')
        scenario = source[start:source.index('\nPRODUCT_CHECK=legacy-journal-capture', start)]
        script = self.prefix(fixture) + """
INHERITED_DYLD=''
RUN_ID=""" + RUN_ID + """
BUNDLE=dev.iosvoipsdk.m1contracts
NAME=sdk-m1-contract-audio-lifecycle
""" + functions + """
UDID=$(limit 2 xcrun simctl create legacy-host device runtime)
""" + scenario
        result = self.run_shell(fixture, script)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertTrue(json.loads((fixture.root/'supervisor-environments.jsonl').read_text())['checkpoint'])
        self.assertEqual(len((fixture.root/'diagnostics.jsonl').read_text().splitlines()), 1)
        self.assertIn('product:sdk-m1-contract-audio-lifecycle', fixture.summary.read_text())
        self.assertIn('infra:delete', fixture.summary.read_text())
        self.assertTrue(fixture.inventory(), 'failed cleanup must retain owned identity')
        fixture.rules()
        fixture.cli('cleanup',fixture.state)
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
