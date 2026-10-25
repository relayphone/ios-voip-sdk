"""Runtime fixture install ownership controls; every native transport is fake."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sim
from test_runtime_install_core import Native


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('runtime_install_adapter_runner', ROOT / 'Tests/RuntimeEvents/run.py')
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
CI_SPEC = importlib.util.spec_from_file_location('runtime_install_adapter_ci', ROOT / 'Tests/RuntimeEvents/ci_simulator.py')
ci = importlib.util.module_from_spec(CI_SPEC)
with patch.dict(sys.modules, {'run': runtime}):
    CI_SPEC.loader.exec_module(ci)


class AdapterNative(Native):
    def __init__(self, container):
        super().__init__()
        self.container, self.environments, self.results, self.booted = container, [], [], set()

    def __call__(self, command, timeout, *, env=None):
        command = list(map(str, command))
        if command[:2] != ['xcrun', 'simctl']:
            raise AssertionError('unexpected native transport')
        self.environments.append(env)
        result = super().__call__(command, timeout)
        if command[2:4] == ['list', 'runtimes']:
            result.stdout = json.dumps(dict(runtimes=[dict(identifier='ios-27', platform='iOS',
                isAvailable=True, version='27.0')])).encode()
        elif command[2:4] == ['list', 'devices']:
            result.stdout = json.dumps(dict(devices={'ios-27': [dict(udid=device, name=name,
                state='Booted' if device in self.booted else 'Shutdown') for device, name in self.devices.items()]})).encode()
        elif command[2] == 'boot' and result.returncode == 0:
            self.booted.add(command[3])
        elif command[2] == 'launch' and result.returncode == 0:
            result.stdout = b'fixture: 42\n'
        elif command[2] == 'get_app_container' and result.returncode == 0:
            result.stdout = (str(self.container) + '\n').encode()
        self.results.append(result)
        return result


class RuntimeInstallAdapterTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='runtime-install-adapter-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path, self.id_file, self.env_file = (self.root / name for name in ('owner.json', 'simulator.id', 'github.env'))
        self.app = self.root / 'RuntimeFixture.app'; self.app.mkdir()
        self.native = AdapterNative(self.root / 'container')
        environment = dict(CKSIM_SIMULATOR_ID_FILE=str(self.id_file), GITHUB_ENV=str(self.env_file),
                           GITHUB_STEP_SUMMARY=str(self.root / 'summary'), SIM_FAILURE_MARKER=str(self.root / 'failure'))
        for guard in (patch.dict(os.environ, environment, clear=True),
                      patch.object(sim, 'bounded', side_effect=self.native),
                      patch.object(subprocess, 'run', side_effect=AssertionError('unbounded native run forbidden')),
                      patch.object(subprocess, 'Popen', side_effect=AssertionError('native Popen forbidden'))):
            guard.start(); self.addCleanup(guard.stop)

    def owner(self):
        owner = sim.Session(self.path, runner=runtime.session_transport)
        runtime.lifecycle(owner, 'create', 'Adapter CI ', 'device', 'ios-27', timeout=30)
        runtime.lifecycle(owner, 'boot', owner.current, timeout=60)
        runtime.lifecycle(owner, 'bootstatus', owner.current, '-b', timeout=300)
        return owner

    def state(self):
        return json.loads(self.path.read_text())

    def step_calls(self, step):
        return [(command, timeout) for command, timeout in self.native.calls if command[2] == step]

    def test_native_failure_preserves_typed_result_legacy_message_and_environment(self):
        self.native.failures['bootstatus', 1] = 'timeout'
        environment = {'SIMCTL_CHILD_FIXTURE': 'host-only'}
        with self.assertRaises(RuntimeError) as caught:
            runtime.run('xcrun', 'simctl', 'bootstatus', 'borrowed', '-b', timeout=300, env=environment)
        self.assertIsInstance(caught.exception, runtime.CommandError)
        self.assertIs(caught.exception.result, self.native.results[0])
        self.assertIs(caught.exception.result.transport_error, caught.exception)
        self.assertEqual(str(caught.exception), "xcrun timed out after 300s: b''\nb''")
        self.assertEqual(self.native.environments, [environment])
        self.assertEqual(self.native.calls[0][1], 300)

    def test_install_timeout_replaces_owner_and_publishes_new_identity_before_launch_and_rpc(self):
        owner = self.owner(); original = owner.current
        self.native.failures['install', 1] = 'timeout'
        os.environ['SIM_STATE'] = str(self.path)
        channel, run_id = runtime.launch_fixture(original, self.app)
        current = self.state()['current']
        self.assertNotEqual(current, original)
        self.assertEqual(set(self.native.devices), {current})
        self.assertEqual([call[0][3] for call in self.step_calls('install')], [original, current])
        self.assertEqual(self.step_calls('launch')[0][0][4], current)
        self.assertEqual(self.step_calls('get_app_container')[0][0][3], current)
        self.assertEqual(channel, self.native.container / 'Documents/.callkit-simulator')
        launch_index = next(index for index, (command, _) in enumerate(self.native.calls) if command[2] == 'launch')
        self.assertEqual(self.native.environments[launch_index]['SIMCTL_CHILD_CKSIM_RUN_ID'], run_id)
        self.assertEqual(self.id_file.read_text(), current + '\n')
        exports = dict(line.split('=', 1) for line in self.env_file.read_text().splitlines())
        self.assertEqual(exports['CKSIM_TEST_SIMULATOR'], current)
        self.assertEqual(exports['SIM_STATE'], str(self.path.resolve()))
        self.assertTrue(self.state()['retry_used']); self.assertTrue(self.state()['checkpoint'])
        self.assertEqual([timeout for _, timeout in self.step_calls('install')], [180, 180])
        summary = (self.root / 'summary').read_text()
        self.assertEqual(summary.count('measurement:fixture-install'), 2)
        self.assertIn('bound=180.0s status=124 timed_out=True', summary)
        self.assertIn('bound=180.0s status=0 timed_out=False', summary)

    def test_create_recovery_spends_the_same_budget_before_a_later_install_failure(self):
        self.native.failures['create', 1] = 'timeout'
        owner = self.owner()
        self.native.failures['install', 1] = 'timeout'
        with self.assertRaises(runtime.CommandError):
            runtime.launch_fixture(owner.current, self.app, session=owner)
        self.assertEqual(self.native.counts['create'], 2)
        self.assertEqual(self.native.counts['install'], 1)
        self.assertNotIn('launch', self.native.counts)
        self.assertTrue(self.state()['retry_used'])

    def test_failed_recovery_cleanup_preserves_the_original_install_error_and_lease(self):
        owner = self.owner(); original = owner.current
        self.native.failures.update({('install', 1): 'timeout', ('delete', 1): 73})
        with self.assertRaises(runtime.CommandError) as caught:
            runtime.lifecycle(owner, 'install', original, self.app, timeout=120)
        first = next(result for result in self.native.results if result.args[2] == 'install')
        self.assertIs(caught.exception, first.transport_error)
        self.assertTrue(caught.exception.result.timed_out)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertEqual(self.native.counts['install'], 1)
        self.assertEqual(self.state()['owned'][0]['id'], original)
        self.assertEqual(set(self.native.devices), {original})
        self.assertNotIn('launch', self.native.counts)

    def test_recovery_cleanup_write_errors_preserve_install_error_identity(self):
        owner = self.owner()
        self.native.failures['install', 1] = 'timeout'
        original = OSError('cleanup recording unavailable')
        opened = Path.open
        def refuse(path, *args, **kwargs):
            if path == self.path.with_name('cleanup.log'):
                raise original
            return opened(path, *args, **kwargs)
        with patch.object(Path, 'open', refuse):
            with self.assertRaises(runtime.CommandError) as caught:
                runtime.lifecycle(owner, 'install', owner.current, self.app, timeout=120)
        first = next(result for result in self.native.results if result.args[2] == 'install')
        self.assertIs(caught.exception, first.transport_error)
        self.assertIs(caught.exception.__cause__, original)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertEqual(self.native.counts['delete'], 1)
        self.assertFalse(self.state()['owned'])
        self.assertFalse(self.native.devices)
        self.assertTrue(self.state()['retry_used'])
        self.assertNotIn('launch', self.native.counts)

    def test_bootstrap_recovery_cannot_give_install_another_retry(self):
        self.native.failures['bootstatus', 1] = 'timeout'
        owner = self.owner()
        self.native.failures['install', 1] = 'timeout'
        with self.assertRaises(runtime.CommandError):
            runtime.launch_fixture(owner.current, self.app, session=owner)
        self.assertEqual(self.native.counts['create'], 2)
        self.assertEqual(self.native.counts['bootstatus'], 2)
        self.assertEqual(self.native.counts['install'], 1)
        self.assertNotIn('launch', self.native.counts)

    def test_borrowed_and_stateless_install_failures_never_replace_or_delete(self):
        owner = self.owner(); before = self.path.read_bytes()
        borrowed = sim.Session.attach(self.path, owner.current, runner=runtime.session_transport)
        for index, session in enumerate((None, borrowed), 1):
            with self.subTest(session=session):
                self.native.failures['install', index] = 'timeout'
                with self.assertRaises(runtime.CommandError):
                    runtime.launch_fixture(owner.current, self.app, session=session)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertNotIn('delete', self.native.counts)
        self.assertNotIn('launch', self.native.counts)
        self.assertEqual(self.path.read_bytes(), before)

    def test_another_owner_checkpoint_prevents_install_recovery(self):
        owner = self.owner()
        resumed = sim.Session.resume(self.path, owner.current, runner=runtime.session_transport)
        owner.checkpoint()
        self.native.failures['install', 1] = 'timeout'
        with self.assertRaises(runtime.CommandError):
            runtime.launch_fixture(resumed.current, self.app, session=resumed)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertFalse(self.state()['retry_used'])
        self.assertNotIn('launch', self.native.counts)

    def test_direct_launch_failure_leaves_checkpoint_sticky_without_launch_retry(self):
        owner = self.owner()
        self.native.failures['launch', 1] = 'timeout'
        with self.assertRaises(runtime.CommandError) as caught:
            runtime.launch_fixture(owner.current, self.app, session=owner)
        self.assertIs(caught.exception.result, self.native.results[-1])
        self.assertTrue(self.state()['checkpoint'])
        self.native.failures['install', 2] = 'timeout'
        with self.assertRaises(runtime.CommandError):
            runtime.lifecycle(owner, 'install', owner.current, self.app)
        self.assertEqual(self.native.counts['launch'], 1)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertNotIn('get_app_container', self.native.counts)

    def test_measurement_bound_600_applies_to_both_attempts_and_larger_bounds_refuse_before_native(self):
        owner = self.owner()
        self.native.failures['install', 1] = 'timeout'
        os.environ['CKSIM_FIXTURE_INSTALL_TIMEOUT'] = '600'
        runtime.launch_fixture(owner.current, self.app, session=owner)
        self.assertEqual([timeout for _, timeout in self.step_calls('install')], [600, 600])
        summary = (self.root / 'summary').read_text()
        self.assertEqual(summary.count('measurement:fixture-install'), 2)
        self.assertEqual(summary.count('bound=600.0s'), 2)
        before = len(self.native.calls)
        for bound in ('600.01', '601', 'inf', 'nan', '0', '-1'):
            with self.subTest(bound=bound):
                os.environ['CKSIM_FIXTURE_INSTALL_TIMEOUT'] = bound
                with self.assertRaises(ValueError):
                    runtime.launch_fixture(owner.current, self.app, session=owner)
        self.assertEqual(len(self.native.calls), before)

    def test_publish_failure_cannot_mask_the_exact_terminal_native_error(self):
        owner = self.owner(); owner.checkpoint()
        self.native.failures['install', 1] = 'timeout'
        with patch.object(runtime, 'publish', side_effect=OSError('secondary publication failure')):
            with self.assertRaises(runtime.CommandError) as caught:
                runtime.lifecycle(owner, 'install', owner.current, self.app)
        self.assertIs(caught.exception, self.native.results[-1].transport_error)
        self.assertIs(caught.exception.result, self.native.results[-1])
        self.assertIn('infra:ownership-export', (self.root / 'summary').read_text())
        self.assertEqual(self.native.counts['create'], 1)

    def test_main_fresh_owner_cleanup_failure_preserves_original_product_exception(self):
        original = RuntimeError('original fixture session failure')
        self.native.failures['delete', 1] = 73
        out = self.root / 'capture'
        argv = ['run.py', '--package', str(self.root), '--app', str(self.app), '--out', str(out)]
        with patch.object(runtime.sys, 'argv', argv), patch.object(runtime, 'record_environment'), \
             patch.object(runtime, 'fixture_session', side_effect=original), patch.object(runtime, 'capture_diagnostics'):
            with self.assertRaises(RuntimeError) as caught:
                runtime.main()
        self.assertIs(caught.exception, original)
        self.assertEqual(self.native.counts['shutdown'], 1)
        self.assertEqual(self.native.counts['delete'], 1)
        self.assertEqual([timeout for _, timeout in self.step_calls('delete')], [30])
        self.assertTrue(json.loads((out / 'simulator-state.json').read_text())['owned'])

    def test_main_wrong_resumed_uuid_refuses_before_install_and_preserves_authority(self):
        owner = self.owner(); before = self.path.read_bytes()
        argv = ['run.py', '--package', str(self.root), '--app', str(self.app), '--out', str(self.root / 'capture'),
                '--simulator-state', str(self.path), '--simulator', '00000000-0000-4000-8000-000000000099']
        with patch.object(runtime.sys, 'argv', argv), patch.object(runtime, 'record_environment'):
            with self.assertRaises(ValueError):
                runtime.main()
        self.assertNotIn('install', self.native.counts)
        self.assertNotIn('delete', self.native.counts)
        self.assertEqual(self.path.read_bytes(), before)

    def test_ci_inventory_recovery_spends_the_budget_seen_by_runtime_install(self):
        producer_calls = []

        def producer(*command, timeout=120):
            producer_calls.append((command, timeout))
            if command[2:4] == ('list', 'runtimes') and len(producer_calls) == 1:
                raise subprocess.TimeoutExpired(command, timeout, output=b'partial runtime inventory')
            return runtime.run(*command, timeout=timeout)

        with patch.object(ci, 'run', side_effect=producer):
            original = ci.create('ios-27', self.id_file, self.env_file)
        self.path = ci.state_path(self.id_file)
        exports = dict(line.split('=', 1) for line in self.env_file.read_text().splitlines())
        self.assertEqual(self.id_file.read_text(), original + '\n')
        self.assertEqual(exports['CKSIM_TEST_SIMULATOR'], original)
        self.assertEqual(exports['SIM_STATE'], str(self.path.resolve()))
        self.assertTrue(self.state()['retry_used'])
        inventory = [(command, timeout) for command, timeout in producer_calls if command[2:4] == ('list', 'runtimes')]
        self.assertEqual(len(inventory), 2)
        self.assertEqual([timeout for _, timeout in inventory], [60, 60])
        owner = sim.Session.resume(exports['SIM_STATE'], original, runner=runtime.session_transport)
        self.native.failures['install', 1] = 'timeout'
        with self.assertRaises(runtime.CommandError):
            runtime.launch_fixture(original, self.app, session=owner)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertEqual(self.native.counts['install'], 1)
        self.assertEqual([timeout for _, timeout in self.step_calls('install')], [180])
        self.assertNotIn('delete', self.native.counts)
        self.assertNotIn('launch', self.native.counts)
        self.assertEqual(self.state()['current'], original)

    def test_ci_producer_ledger_follows_install_replacement_through_ci_cleanup(self):
        with patch.object(ci, 'run', side_effect=runtime.run):
            original = ci.create('ios-27', self.id_file, self.env_file)
        self.path = ci.state_path(self.id_file)
        os.environ['SIM_STATE'] = str(self.path)
        owner = sim.Session.resume(self.path, original, runner=runtime.session_transport)
        runtime.lifecycle(owner, 'boot', original, timeout=60)
        runtime.lifecycle(owner, 'bootstatus', original, '-b', timeout=300)
        self.native.failures['install', 1] = 'timeout'
        runtime.launch_fixture(original, self.app)
        current = self.state()['current']
        self.assertNotEqual(current, original)
        self.assertEqual(self.id_file.read_text(), current + '\n')
        exports = dict(line.split('=', 1) for line in self.env_file.read_text().splitlines())
        self.assertEqual(exports['SIM_STATE'], str(self.path.resolve()))
        self.assertEqual(exports['CKSIM_TEST_SIMULATOR'], current)
        self.assertEqual(set(self.native.devices), {current})
        self.assertEqual(self.step_calls('launch')[0][0][4], current)
        self.assertEqual(self.step_calls('get_app_container')[0][0][3], current)
        with patch.object(ci, 'run', side_effect=runtime.run):
            ci.cleanup(self.id_file)
        self.assertEqual([command[3] for command, _ in self.step_calls('delete')], [original, current])
        self.assertEqual([timeout for _, timeout in self.step_calls('delete')], [30, 30])
        self.assertEqual(self.native.devices, {})
        self.assertEqual(self.state()['owned'], [])
        self.assertIsNone(self.state()['current'])
        self.assertFalse(self.id_file.exists())


if __name__ == '__main__':
    unittest.main()
