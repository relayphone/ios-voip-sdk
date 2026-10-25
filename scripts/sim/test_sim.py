#!/usr/bin/env python3
"""Host-only lifecycle controls. The fake simctl never accesses a simulator."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).with_name('sim.py')
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
DEVICE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
BUNDLE = 'dev.sim.helper.fixture'
FOREIGN = '11111111-1111-4111-8111-111111111111'

# Calls and inventory are deliberately independent of the helper's ownership
# record: tests observe actual commands, rather than trusting its state JSON.
FAKE = r'''
import json, os, pathlib, sys, time, uuid
root = pathlib.Path(os.environ['FAKE_SIM_ROOT'])
arguments = sys.argv[1:]
assert arguments[0] == 'simctl', arguments
command = arguments[1:]
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(command) + '\n')
path = root / 'native.json'
native = json.loads(path.read_text())
step = command[0]
native['counts'][step] = native['counts'].get(step, 0) + 1
occurrence = native['counts'][step]
rule = next((rule for rule in json.loads((root / 'rules.json').read_text())
             if rule['step'] == step and occurrence in rule.get('at', [1])
             and (not rule.get('match') or rule['match'] in command)), {})
if step == 'create':
    device = str(uuid.uuid5(uuid.NAMESPACE_URL, 'helper-fixture-' + str(occurrence)))
    if rule.get('action') not in ('timeout-no-create', 'signal-no-create', 'invalid-create'):
        native['devices'].append(dict(name=command[1], udid=device))
elif step == 'delete' and rule.get('action') != 'failure':
    native['devices'] = [device for device in native['devices'] if device['udid'] != command[1]]
path.write_text(json.dumps(native))
action = rule.get('action')
if action == 'timeout': time.sleep(30)
if action == 'timeout-no-create': time.sleep(30)
if action == 'signal-no-create':
    import signal
    os.kill(os.getpid(), signal.SIGTERM)
if action == 'invalid-create':
    print('not-a-simulator-uuid')
    sys.exit(0)
if action == 'failure': sys.exit(73)
if action == 'partial-launch':
    print('PROBE {"event":"app.entry"}', flush=True)
    sys.exit(3)
if action == 'pid-launch':
    print(command[-1] + ': 1234', flush=True)
    sys.exit(3)
if action == 'launch-rejection':
    bundle = command[-1]
    sys.stderr.write('An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
        'Simulator device failed to launch ' + bundle + '.\nNo such process\n'
        'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
        "\tApplication launch for '" + bundle + "' did not return a process handle nor launch error.\n\tNo such process\n")
    sys.exit(3)
if step == 'create': print(device)
elif step == 'list': print(json.dumps(dict(devices={'runtime': native['devices']})))
elif step == 'launch': print(command[-1] + ': 1234')
'''


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sim-helper-host-')
        self.root = Path(self.temporary.name)
        binary = self.root / 'bin'
        binary.mkdir()
        executable = binary / 'xcrun'
        executable.write_text('#!' + sys.executable + '\n' + FAKE)
        executable.chmod(0o755)
        self.state = self.root / 'owned.json'
        self.summary = self.root / 'summary.md'
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ.get('PATH', ''),
                        FAKE_SIM_ROOT=str(self.root), GITHUB_STEP_SUMMARY=str(self.summary))
        (self.root / 'native.json').write_text(json.dumps(dict(counts={}, devices=[])))
        self.rules()

    def tearDown(self):
        self.temporary.cleanup()

    def rules(self, *rules):
        (self.root / 'rules.json').write_text(json.dumps(rules))

    def cli(self, *arguments, expected=0):
        result = subprocess.run([sys.executable, str(HELPER), *map(str, arguments)],
                                env=self.env, capture_output=True, text=True, timeout=12)
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, 'failed operation was accepted: ' + result.stdout + result.stderr)
        return result

    def call(self, *command, timeout=2, expected=0):
        return self.cli('call', self.state, timeout, 'xcrun', 'simctl', *command, expected=expected)

    def current(self):
        return self.cli('current', self.state).stdout.strip()

    def create(self):
        created = self.call('create', 'host-owned', DEVICE, RUNTIME).stdout.strip()
        self.assertEqual(created, self.current())
        return created

    def calls(self, step=None):
        rows = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        return [row for row in rows if step is None or row[0] == step]

    def inventory(self):
        return json.loads((self.root / 'native.json').read_text())['devices']

    def test_generic_command_preserves_stdout_and_nonzero_status(self):
        result = self.cli('call', '', 2, sys.executable, '-c',
                          'import sys;sys.stdout.write("value");sys.exit(73)', expected=73)
        self.assertEqual(result.stdout, 'value')

    def test_timeout_kills_descendants_that_hold_output_pipes(self):
        sentinel = self.root / 'escaped-child'
        pid_file = self.root / 'child-pid'
        child = 'import pathlib,time;time.sleep(.8);pathlib.Path(' + repr(str(sentinel)) + ').touch()'
        parent = ('import pathlib,subprocess,sys,time;'
                  'child=subprocess.Popen([sys.executable,"-c",' + repr(child) + ']);'
                  'pathlib.Path(' + repr(str(pid_file)) + ').write_text(str(child.pid));'
                  'print("started",flush=True);time.sleep(30)')
        started = time.monotonic()
        try:
            result = self.cli('call', '', .3, sys.executable, '-c', parent, expected=124)
            self.assertLess(time.monotonic() - started, 5)
            self.assertIn('started', result.stdout)
            time.sleep(1)
            self.assertFalse(sentinel.exists(), 'timed-out descendant escaped process cleanup')
        finally:
            if pid_file.exists():
                try: os.kill(int(pid_file.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass

    def test_create_timeout_recovers_exact_name_and_retries_once(self):
        native = dict(counts={}, devices=[dict(name='host-owned-neighbor', udid=FOREIGN)])
        (self.root / 'native.json').write_text(json.dumps(native))
        self.rules(dict(step='create', action='timeout'))
        # Allow the fake interpreter's cold startup; the injected 30s stall
        # still proves this operation is killed at its caller's hard bound.
        created = self.call('create', 'host-owned', DEVICE, RUNTIME, timeout=2).stdout.strip()
        self.assertEqual(created, self.current())
        self.assertEqual(len(self.calls('create')), 2)
        first, second = self.calls('create')
        self.assertNotEqual(first[1], second[1], 'retry must reserve a fresh unique name')
        self.assertNotEqual(first[1], 'host-owned')
        self.assertEqual({row['udid'] for row in self.inventory()}, {created, FOREIGN})
        self.assertNotIn(['delete', FOREIGN], self.calls('delete'))
        self.assertIn('infra:create', self.summary.read_text())
        self.assertIn('recovered', self.summary.read_text())

    def test_create_failure_exhausts_after_one_retry_and_cleanup_clears_owned(self):
        self.rules(dict(step='create', at=[1, 2, 3], action='failure'))
        self.call('create', 'host-owned', DEVICE, RUNTIME, expected=None)
        self.assertEqual(len(self.calls('create')), 2)
        self.cli('cleanup', self.state, '--timeout', .2)
        self.assertEqual(self.inventory(), [])
        summary = self.summary.read_text()
        self.assertIn('infra:create', summary)
        self.assertIn('exhausted', summary)

    def test_unresolved_create_name_is_retained_until_late_registration_can_be_deleted(self):
        for action in ('timeout-no-create', 'signal-no-create', 'invalid-create'):
            with self.subTest(action=action):
                self.rules(dict(step='create', at=[1], action=action))
                self.call('create', 'late-owned', DEVICE, RUNTIME, timeout=.2)
                first_name = self.calls('create')[0][1]
                self.cli('cleanup', self.state, '--timeout', .2, expected=None)
                state = json.loads(self.state.read_text())
                self.assertEqual([record['name'] for record in state['owned']], [first_name])
                self.assertTrue(state['owned'][0]['uncertain'])
                self.assertFalse(json.loads((self.root / 'cleanup.json').read_text())['deleted'])
                late = '22222222-2222-4222-8222-222222222222'
                native = json.loads((self.root / 'native.json').read_text())
                native['devices'] += [dict(name=first_name, udid=late),
                                      dict(name=first_name + '-neighbor', udid=FOREIGN)]
                (self.root / 'native.json').write_text(json.dumps(native))
                self.cli('cleanup', self.state, '--timeout', .2)
                self.assertIn(['delete', late], self.calls('delete'))
                self.assertNotIn(['delete', FOREIGN], self.calls('delete'))
                self.assertEqual([device['udid'] for device in self.inventory()], [FOREIGN])
                self.assertTrue(json.loads((self.root / 'cleanup.json').read_text())['deleted'])
                self.assertEqual(json.loads(self.state.read_text())['owned'], [])
                # Each injected failure starts at a fresh service/session seam.
                self.state.unlink()
                (self.root / 'calls.jsonl').unlink()
                (self.root / 'native.json').write_text(json.dumps(dict(counts={}, devices=[])))

    def test_boot_timeout_replaces_device_and_replays_boot_once(self):
        original = self.create()
        self.rules(dict(step='boot', action='timeout'))
        self.call('boot', original, timeout=.2)
        replacement = self.current()
        self.assertNotEqual(original, replacement)
        self.assertEqual(self.calls('boot'), [['boot', original], ['boot', replacement]])
        self.assertIn(['delete', original], self.calls())
        self.assertEqual([row['udid'] for row in self.inventory()], [replacement])
        self.assertIn('infra:boot', self.summary.read_text())
        self.assertIn('recovered', self.summary.read_text())

    def test_bootstatus_timeout_replays_boot_on_fresh_device(self):
        original = self.create()
        self.call('boot', original)
        self.rules(dict(step='bootstatus', action='timeout'))
        self.call('bootstatus', original, '-b', timeout=.2)
        replacement = self.current()
        self.assertNotEqual(original, replacement)
        self.assertEqual(self.calls('boot'), [['boot', original], ['boot', replacement]])
        self.assertEqual(self.calls('bootstatus'), [['bootstatus', original, '-b'], ['bootstatus', replacement, '-b']])

    def test_install_timeout_replays_boot_and_prior_installations(self):
        original = self.create()
        self.call('boot', original)
        self.call('bootstatus', original, '-b')
        self.call('install', original, 'first.app')
        self.rules(dict(step='install', at=[2], action='timeout'))
        self.call('install', original, 'second.app', timeout=.2)
        replacement = self.current()
        self.assertNotEqual(original, replacement)
        self.assertEqual(self.calls('install'), [
            ['install', original, 'first.app'], ['install', original, 'second.app'],
            ['install', replacement, 'first.app'], ['install', replacement, 'second.app']])
        self.assertEqual(self.calls('boot')[-1], ['boot', replacement])
        self.assertEqual(self.calls('bootstatus')[-1], ['bootstatus', replacement, '-b'])
        self.assertIn('infra:install', self.summary.read_text())

    def test_retry_budget_is_shared_across_preapp_steps(self):
        self.rules(dict(step='create', action='failure'), dict(step='boot', action='failure'))
        created = self.create()
        self.call('boot', created, expected=None)
        self.assertEqual(len(self.calls('create')), 2)
        self.assertEqual(self.calls('boot'), [['boot', created]])

    def test_failure_during_replay_does_not_start_a_third_attempt(self):
        original = self.create()
        self.call('boot', original, timeout=.2)
        self.rules(dict(step='install', action='failure'), dict(step='boot', at=[2], action='timeout'))
        started = time.monotonic()
        self.call('install', original, 'fixture.app', expected=None)
        self.assertLess(time.monotonic() - started, 3, 'replay must retain the original .2s boot budget')
        self.assertEqual(len(self.calls('create')), 2)
        self.assertEqual(len(self.calls('boot')), 2)
        self.assertEqual(len(self.calls('install')), 1)
        self.cli('cleanup', self.state, '--timeout', .2)
        self.assertEqual(self.inventory(), [])

    def test_checkpoint_permanently_disables_infrastructure_retries(self):
        created = self.create()
        self.cli('checkpoint', self.state)
        self.rules(dict(step='install', action='failure'))
        self.call('install', created, 'fixture.app', expected=None)
        self.assertEqual(len(self.calls('create')), 1)
        self.assertEqual(len(self.calls('install')), 1)

    def test_exact_preapp_launch_rejection_can_retry_once(self):
        created = self.create()
        self.rules(dict(step='launch', action='launch-rejection'))
        self.call('launch', created, BUNDLE)
        self.assertEqual(len(self.calls('launch')), 2)
        self.assertEqual(len(self.calls('create')), 1, 'launch retry must not replace the device')
        self.assertIn('infra:launch', self.summary.read_text())
        self.assertIn('recovered', self.summary.read_text())

    def test_launch_with_any_app_evidence_or_unknown_outcome_is_never_retried(self):
        created = self.create()
        for index, action in enumerate(('partial-launch', 'pid-launch', 'timeout'), 1):
            with self.subTest(action=action):
                self.rules(dict(step='launch', at=[index], action=action))
                self.call('launch', created, BUNDLE, timeout=.2, expected=None)
                self.assertEqual(len(self.calls('launch')), index)
                self.assertEqual(len(self.calls('create')), 1)

    def test_post_checkpoint_exact_launch_rejection_is_not_retried(self):
        created = self.create()
        self.cli('checkpoint', self.state)
        self.rules(dict(step='launch', action='launch-rejection'))
        self.call('launch', created, BUNDLE, expected=None)
        self.assertEqual(len(self.calls('launch')), 1)

    def test_launch_retry_is_exhausted_after_two_exact_rejections(self):
        created = self.create()
        self.rules(dict(step='launch', at=[1, 2, 3], action='launch-rejection'))
        self.call('launch', created, BUNDLE, expected=None)
        self.assertEqual(len(self.calls('launch')), 2)
        self.assertIn('infra:launch', self.summary.read_text())
        self.assertIn('exhausted', self.summary.read_text())

    def test_terminate_and_screenshot_failures_are_bounded_and_not_retried(self):
        created = self.create()
        self.rules(dict(step='terminate', action='timeout'), dict(step='io', action='timeout'))
        self.call('terminate', created, BUNDLE, timeout=.2, expected=None)
        self.call('io', created, 'screenshot', str(self.root / 'shot.png'), timeout=.2, expected=None)
        self.assertEqual(len(self.calls('terminate')), 1)
        self.assertEqual(len(self.calls('io')), 1)
        self.assertEqual(len(self.calls('create')), 1)

    def test_cleanup_attempts_delete_even_when_shutdown_times_out(self):
        created = self.create()
        self.rules(dict(step='shutdown', action='timeout'))
        self.cli('cleanup', self.state, '--timeout', .2)
        self.assertEqual(self.calls('delete'), [['delete', created]])
        self.assertEqual(self.inventory(), [])
        cleanup = json.loads((self.root / 'cleanup.json').read_text())
        self.assertEqual(cleanup['simulatorID'], created)
        self.assertEqual(cleanup['shutdownExitCode'], 124)
        self.assertEqual(cleanup['deleteExitCode'], 0)
        self.assertTrue(cleanup['deleted'])

    def test_failed_delete_retains_ownership_for_later_cleanup(self):
        created = self.create()
        self.rules(dict(step='delete', action='failure'))
        self.cli('cleanup', self.state, '--timeout', .2, expected=None)
        self.assertEqual([row['udid'] for row in self.inventory()], [created])
        self.rules()
        self.cli('cleanup', self.state, '--timeout', .2)
        self.assertEqual(self.calls('delete'), [['delete', created], ['delete', created]])
        self.assertEqual(self.inventory(), [])

    def test_forbidden_transport_rpcs_are_refused_before_execution(self):
        created = self.create()
        for command in (('spawn', created, 'launchctl', 'getenv', 'ANYTHING'),
                        ('get_app_container', created, BUNDLE, 'data')):
            self.call(*command, expected=None)
        self.assertEqual(len(self.calls()), 1)

    def test_foreign_or_multiple_simulator_targets_are_refused_before_execution(self):
        created = self.create()
        commands = [
            ('boot', FOREIGN, created), ('bootstatus', FOREIGN, '-b', created),
            ('install', FOREIGN, created), ('launch', FOREIGN, created, BUNDLE),
            ('terminate', FOREIGN, created), ('shutdown', FOREIGN, created),
            ('delete', FOREIGN, created), ('delete', created, FOREIGN),
            ('io', FOREIGN, 'screenshot', created),
            ('privacy', FOREIGN, 'grant', 'microphone', created),
        ]
        for command in commands:
            with self.subTest(command=command):
                self.call(*command, expected=None)
        self.assertEqual(len(self.calls()), 1, 'a foreign simulator operation reached the native service')

    def test_product_classification_never_executes_or_retries_a_command(self):
        self.cli('product', 'sdk-m0-conformance')
        self.assertIn('product:sdk-m0-conformance', self.summary.read_text())
        self.assertFalse((self.root / 'calls.jsonl').exists())

    def test_sigterm_during_native_call_cleans_owned_simulator(self):
        created = self.create()
        self.rules(dict(step='install', action='timeout'))
        process = subprocess.Popen([sys.executable, str(HELPER), 'call', str(self.state),
                                    '30', 'xcrun', 'simctl', 'install', created, 'fixture.app'],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not self.calls('install') and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertEqual(len(self.calls('install')), 1, 'fake install never entered')
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assertIn(['delete', created], self.calls())
            self.assertEqual(self.inventory(), [])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_nonfinite_or_nonpositive_bounds_are_refused_before_native_call(self):
        for timeout in ('0', '-1', 'nan', 'inf'):
            with self.subTest(timeout=timeout):
                self.cli('call', self.state, timeout, 'xcrun', 'simctl', 'list', 'devices', '-j', expected=None)
        self.assertFalse((self.root / 'calls.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
