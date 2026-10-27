"""Fixture discovery must not contact CoreSimulator after app launch."""
import json
import os
import signal
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run
from test_runtime_install_adapter import AdapterNative


DEVICE = '11111111-1111-4111-8111-111111111111'
CONTAINER = '22222222-2222-4222-8222-222222222222'


class FixtureInventoryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='runtime-prelaunch-inventory-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.data = self.root / 'Devices' / DEVICE / 'data'
        self.applications = self.data / 'Containers/Data/Application'
        self.channel = self.applications / CONTAINER / 'Documents/.callkit-simulator'
        self.channel.mkdir(parents=True)
        self.commands = []
        self.launched = False
        self.inventory = dict(devices={'ios-27': [dict(udid=DEVICE, state='Booted', dataPath=str(self.data))]})

    def native(self, *command, **kwargs):
        self.commands.append(command)
        if command[:4] == ('xcrun', 'simctl', 'list', 'devices'):
            self.assertFalse(self.launched, 'post-launch CoreSimulator inventory RPC')
            self.assertEqual(kwargs['timeout'], 60)
            return json.dumps(self.inventory)
        if command[:3] == ('xcrun', 'simctl', 'launch'):
            self.assertFalse(self.launched, 'fixture launch must not be replayed')
            self.launched = True
            run_id = kwargs['env']['SIMCTL_CHILD_CKSIM_RUN_ID']
            (self.channel / run_id).mkdir()
            (self.channel / 'session.json').write_text(json.dumps(dict(
                schemaVersion=1, runID=run_id, pid=42, bundleID=run.BUNDLE)))
            (self.channel / run_id / 'events.jsonl').write_text('{"partial":')
            return run.BUNDLE + ': 42'
        raise AssertionError('Unexpected native command: ' + repr(command))

    def test_inventory_is_cached_before_the_only_launch(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(run, 'run', side_effect=self.native):
            channel, run_id = run.launch_fixture(DEVICE, self.root / 'Fixture.app', install=False)
        self.assertEqual(channel, self.channel)
        self.assertEqual([command[2] for command in self.commands], ['list', 'launch'])
        self.assertEqual((channel / run_id / 'events.jsonl').read_text(), '{"partial":')

    def test_invalid_device_metadata_cannot_launch_the_fixture(self):
        for change in (dict(udid=CONTAINER), dict(state='Shutdown'),
                       dict(dataPath=str(self.root / CONTAINER / 'data'))):
            with self.subTest(change=change):
                self.commands = []
                self.inventory['devices']['ios-27'][0] = dict(
                    udid=DEVICE, state='Booted', dataPath=str(self.data))
                self.inventory['devices']['ios-27'][0].update(change)
                with patch.dict(os.environ, {}, clear=True), patch.object(run, 'run', side_effect=self.native):
                    with self.assertRaises(RuntimeError):
                        run.launch_fixture(DEVICE, self.root / 'Fixture.app', install=False)
                self.assertFalse(self.launched)
                self.assertEqual([command[2] for command in self.commands], ['list'])

    def test_cached_discovery_retains_pid_run_and_canonical_file_guards_without_rpc(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(run, 'run', side_effect=self.native):
            channel, run_id = run.launch_fixture(DEVICE, self.root / 'Fixture.app', install=False)
        identity = json.loads((channel / 'session.json').read_text())
        def immediate(predicate):
            found = predicate()
            if found is None:
                raise RuntimeError('not ready')
            return found
        with patch.object(run, 'run', side_effect=AssertionError('post-launch native RPC')), \
             patch.object(run, 'lifecycle', side_effect=AssertionError('post-launch lifecycle RPC')), \
             patch.object(run, 'wait', side_effect=immediate):
            for change in (dict(runID='stale'), dict(pid=43), dict(pid='42'),
                           dict(bundleID='other.app'), dict(schemaVersion=True)):
                with self.subTest(change=change):
                    (channel / 'session.json').write_text(json.dumps(dict(identity, **change)))
                    with self.assertRaisesRegex(RuntimeError, 'not ready'):
                        run.discover_fixture_channel(self.applications, run_id, 42)

            (channel / 'session.json').write_text(json.dumps(identity))
            journal = channel / run_id / 'events.jsonl'
            saved = self.root / 'saved-journal'
            journal.rename(saved)
            journal.symlink_to(saved)
            with self.assertRaisesRegex(RuntimeError, 'not ready'):
                run.discover_fixture_channel(self.applications, run_id, 42)


class PreinstallInventoryTests(unittest.TestCase):
    """Exercise the real lifecycle owner, including its replacement replay."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='runtime-preinstall-owner-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.app = self.root / 'Fixture.app'
        self.app.mkdir()
        self.native = AdapterNative(self.root / 'container')
        self.installed = set()
        self.inventoried = []
        for guard in (
                patch.dict(os.environ, {}, clear=True),
                patch.object(run.simulator_infra, 'bounded', side_effect=self.transport),
                patch.object(run, 'discover_fixture_channel', return_value=self.root / 'channel')):
            guard.start()
            self.addCleanup(guard.stop)
        self.owner = run.simulator_infra.Session(self.root / 'owner.json', runner=run.session_transport)
        run.lifecycle(self.owner, 'create', 'Preinstall ', 'device', 'ios-27', timeout=30)
        run.lifecycle(self.owner, 'boot', self.owner.current, timeout=60)
        run.lifecycle(self.owner, 'bootstatus', self.owner.current, '-b', timeout=300)

    def transport(self, command, timeout, **kwargs):
        if command[2:5] == ['list', 'devices', '-j']:
            self.assertFalse(self.installed.intersection(self.native.devices),
                             'inventory after a successful install on the current device')
            self.inventoried.append(self.owner.current)
        result = self.native(command, timeout, **kwargs)
        if command[2] == 'install' and result.returncode == 0:
            self.installed.add(command[3])
        return result

    def launch(self):
        with patch.object(run, 'discover_fixture_channel', return_value=self.root / 'channel') as discover:
            channel, _ = run.launch_fixture(self.owner.current, self.app, session=self.owner)
        expected = self.native.devices_root / self.owner.current / 'data/Containers/Data/Application'
        self.assertEqual(discover.call_args.args[0], expected)
        self.assertEqual(channel, self.root / 'channel')
        launches = [command for command, _ in self.native.calls if command[2] == 'launch']
        self.assertEqual(len(launches), 1)
        self.assertEqual(launches[0][4], self.owner.current)
        self.assertTrue(self.owner.state['checkpoint'])

    def test_first_install_uses_inventory_before_install_and_local_validation_afterward(self):
        original = self.owner.current
        self.launch()
        self.assertEqual(self.inventoried, [original])
        self.assertFalse(self.owner.state['retry_used'])

    def test_slow_preinstall_inventory_has_its_own_budget(self):
        queries = []
        def slow_inventory(command, timeout, **kwargs):
            if command[2:5] == ['list', 'devices', '-j']:
                queries.append(timeout)
                # Model a loaded host taking 91s without sleeping in the suite.
                if timeout < 91:
                    return run.simulator_infra.Result(command, 124, timed_out=True)
            return self.transport(command, timeout, **kwargs)
        with patch.object(run.simulator_infra, 'bounded', side_effect=slow_inventory):
            self.launch()
        self.assertEqual(queries, [180])
        self.assertFalse(self.owner.state['retry_used'])
        installs = [bound for command, bound in self.native.calls if command[2] == 'install']
        self.assertEqual(installs, [180])

    def test_inventory_timeout_recovers_once_without_spending_install_recovery(self):
        original = self.owner.current
        self.native.failures['list', 1] = 'timeout'
        marker = self.root / 'terminal-failure'
        with patch.dict(os.environ, SIM_FAILURE_MARKER=str(marker)), \
             patch.object(run.simulator_infra, 'summary') as summary:
            self.launch()
        self.assertEqual(self.inventoried, [original, original])
        queries = [bound for command, bound in self.native.calls if command[2:4] == ['list', 'devices']]
        self.assertEqual(queries, [180, 180])
        self.assertFalse(self.owner.state['retry_used'])
        self.assertFalse(marker.exists(), 'a recovered inventory timeout is not terminal')
        messages = [call.args[1] for call in summary.call_args_list if call.args[0] == 'infra:inventory']
        self.assertTrue(any('timeout' in message for message in messages))
        self.assertTrue(any('recovered' in message for message in messages))

    def test_install_replacement_collects_the_replacement_path_before_its_install(self):
        original = self.owner.current
        self.native.failures['install', 1] = 'timeout'
        self.launch()
        self.assertNotEqual(self.owner.current, original)
        self.assertEqual(self.inventoried, [original, self.owner.current])
        self.assertTrue(self.owner.state['retry_used'])

    def test_prepared_install_replay_reuses_inventory_for_the_retried_install(self):
        original = self.owner.current
        run.lifecycle(self.owner, 'install', original, self.app, timeout=180)
        self.installed.clear()  # Observe only the following launch preparation.
        self.native.failures['install', 2] = 'timeout'
        self.launch()
        self.assertEqual(self.inventoried, [original, self.owner.current])
        installs = [(command, bound) for command, bound in self.native.calls if command[2] == 'install']
        self.assertEqual(len(installs), 4)
        self.assertEqual([bound for _, bound in installs], [180] * 4)

    def test_failed_preinstall_inventory_cannot_install_or_launch(self):
        self.native.failures.update({('list', 1): 'timeout', ('list', 2): 'timeout'})
        marker = self.root / 'terminal-failure'
        with patch.dict(os.environ, SIM_FAILURE_MARKER=str(marker)), \
             patch.object(run.simulator_infra, 'summary') as summary:
            with self.assertRaises(run.CommandError) as caught:
                run.launch_fixture(self.owner.current, self.app, session=self.owner)
        self.assertEqual(caught.exception.result.args[2:4], ['list', 'devices'])
        self.assertEqual(self.inventoried, [self.owner.current] * 2)
        self.assertTrue(marker.exists())
        self.assertTrue(any(call.args[0] == 'infra:inventory' and 'timeout' in call.args[1]
                            and 'exhausted' in call.args[1] for call in summary.call_args_list))
        self.assertFalse(any(command[2] in ('install', 'launch') for command, _ in self.native.calls))
        self.assertFalse(self.owner.state['retry_used'])
        self.assertFalse(self.owner.state['checkpoint'])

    def test_replacement_inventory_failure_retains_the_original_install_result(self):
        self.native.failures.update({('install', 1): 'timeout', ('list', 2): 'timeout', ('list', 3): 'timeout'})
        with self.assertRaises(run.CommandError) as caught:
            run.launch_fixture(self.owner.current, self.app, session=self.owner)
        original = next(result for result in self.native.results if result.args[2] == 'install')
        self.assertIs(caught.exception.result, original)
        self.assertIs(caught.exception, original.transport_error)
        self.assertFalse(any(command[2] == 'launch' for command, _ in self.native.calls))
        self.assertTrue(self.owner.state['retry_used'])
        self.assertFalse(self.owner.state['checkpoint'])

    def test_inventory_recovery_allowance_is_shared_with_replacement(self):
        self.native.failures.update({('list', 1): 'timeout', ('install', 1): 'timeout',
                                     ('list', 3): 'timeout'})
        with self.assertRaises(run.CommandError) as caught:
            run.launch_fixture(self.owner.current, self.app, session=self.owner)
        original = next(result for result in self.native.results if result.args[2] == 'install')
        self.assertIs(caught.exception.result, original)
        queries = [bound for command, bound in self.native.calls if command[2:4] == ['list', 'devices']]
        self.assertEqual(queries, [180, 180, 180])
        self.assertEqual(len(self.inventoried), 3)
        self.assertTrue(self.owner.state['retry_used'])
        self.assertFalse(self.owner.state['checkpoint'])
        self.assertFalse(any(command[2] == 'launch' for command, _ in self.native.calls))

    def test_non_timeout_inventory_failure_is_not_retried(self):
        for status in (73, 124):
            with self.subTest(status=status):
                self.native.failures['list', self.native.counts.get('list', 0) + 1] = status
                before = len(self.inventoried)
                with self.assertRaises(run.CommandError) as caught:
                    run.launch_fixture(self.owner.current, self.app, session=self.owner)
                self.assertEqual(caught.exception.result.returncode, status)
                self.assertFalse(caught.exception.result.timed_out)
                self.assertEqual(len(self.inventoried), before + 1)
        self.assertFalse(self.owner.state['retry_used'])
        self.assertFalse(any(command[2] in ('install', 'launch') for command, _ in self.native.calls))

    def test_inventory_timeout_with_uncertain_cleanup_is_not_retried(self):
        queries = []
        def uncertain(command, timeout, **kwargs):
            if command[2:4] == ['list', 'devices']:
                queries.append(timeout)
                return run.simulator_infra.Result(command, 124, timed_out=True, cleanup_uncertain=True)
            return self.transport(command, timeout, **kwargs)
        with patch.object(run.simulator_infra, 'bounded', side_effect=uncertain):
            with self.assertRaises(run.CommandError) as caught:
                run.launch_fixture(self.owner.current, self.app, session=self.owner)
        self.assertTrue(caught.exception.result.cleanup_uncertain)
        self.assertEqual(queries, [180])
        self.assertFalse(any(command[2] in ('install', 'launch') for command, _ in self.native.calls))

    def test_another_owners_checkpoint_blocks_inventory_recovery(self):
        queries = []
        def checkpointed(command, timeout, **kwargs):
            if command[2:4] == ['list', 'devices']:
                queries.append(timeout)
                other = run.simulator_infra.Session.resume(self.owner.path, self.owner.current,
                                                          runner=self.transport)
                other.checkpoint()
                return run.simulator_infra.Result(command, 124, timed_out=True)
            return self.transport(command, timeout, **kwargs)
        with patch.object(run.simulator_infra, 'bounded', side_effect=checkpointed):
            with self.assertRaises(run.CommandError):
                run.launch_fixture(self.owner.current, self.app, session=self.owner)
        self.assertEqual(queries, [180])
        self.assertTrue(json.loads(self.owner.path.read_text())['checkpoint'])
        self.assertFalse(any(command[2] in ('install', 'launch') for command, _ in self.native.calls))

    def test_inventory_cancellation_propagates_without_another_query(self):
        for attempt in (1, 2):
            for error in (KeyboardInterrupt(), SystemExit(130),
                          run.simulator_infra.Interrupted(signal.SIGINT),
                          run.simulator_infra.Interrupted(signal.SIGTERM)):
                with self.subTest(attempt=attempt, error=type(error).__name__):
                    queries = []
                    def cancel(command, timeout, **kwargs):
                        if command[2:4] == ['list', 'devices']:
                            queries.append(timeout)
                            if len(queries) == attempt:
                                raise error
                            return run.simulator_infra.Result(command, 124, timed_out=True)
                        return self.transport(command, timeout, **kwargs)
                    with patch.object(run.simulator_infra, 'bounded', side_effect=cancel):
                        with self.assertRaises(type(error)) as caught:
                            run.launch_fixture(self.owner.current, self.app, session=self.owner)
                    self.assertIs(caught.exception, error)
                    self.assertEqual(queries, [180] * attempt)
        self.assertFalse(any(command[2] in ('install', 'launch') for command, _ in self.native.calls))

    def replacement_metadata_failure(self, change):
        self.native.failures['install', 1] = 'timeout'
        def invalid(command, timeout, **kwargs):
            result = self.transport(command, timeout, **kwargs)
            if command[2:5] == ['list', 'devices', '-j'] and len(self.inventoried) == 2:
                if isinstance(change, int):
                    raise run.simulator_infra.Interrupted(change)
                if change == 'cancel':
                    raise KeyboardInterrupt()
                inventory = json.loads(result.stdout)
                row = inventory['devices']['ios-27'][0]
                if change == 'duplicate':
                    inventory['devices']['ios-27'].append(dict(row))
                elif change == 'missing-path':
                    row.pop('dataPath')
                else:
                    row['state'] = 'Shutdown'
                result.stdout = json.dumps(inventory).encode()
            return result
        expected = (run.simulator_infra.Interrupted if isinstance(change, int) else
                    KeyboardInterrupt if change == 'cancel' else run.CommandError)
        with patch.object(run.simulator_infra, 'bounded', side_effect=invalid):
            with self.assertRaises(expected) as caught:
                run.launch_fixture(self.owner.current, self.app, session=self.owner)
        if isinstance(change, int):
            self.assertEqual(caught.exception.signum, change)
        elif change != 'cancel':
            original = next(result for result in self.native.results if result.args[2] == 'install')
            self.assertIs(caught.exception.result, original)
            self.assertIs(caught.exception, original.transport_error)
        self.assertFalse(any(c[2] == 'launch' for c, _ in self.native.calls))
        self.assertTrue(self.owner.state['retry_used'])
        self.assertFalse(self.owner.state['checkpoint'])

    def test_replacement_shutdown_metadata_retains_install_failure(self):
        self.replacement_metadata_failure('shutdown')

    def test_replacement_duplicate_metadata_retains_install_failure(self):
        self.replacement_metadata_failure('duplicate')

    def test_replacement_missing_metadata_retains_install_failure(self):
        self.replacement_metadata_failure('missing-path')

    def test_replacement_inventory_cancellation_propagates(self):
        self.replacement_metadata_failure('cancel')

    def test_replacement_inventory_sigint_propagates(self):
        self.replacement_metadata_failure(signal.SIGINT)

    def test_replacement_inventory_sigterm_propagates(self):
        self.replacement_metadata_failure(signal.SIGTERM)

    def test_invalid_inventory_metadata_stops_before_install(self):
        for change in (dict(udid=CONTAINER), dict(state='Shutdown'),
                       dict(dataPath=str(self.root / CONTAINER / 'data')), dict(duplicate=True)):
            with self.subTest(change=change):
                def wrong(command, timeout, **kwargs):
                    result = self.transport(command, timeout, **kwargs)
                    if command[2:5] == ['list', 'devices', '-j']:
                        inventory = json.loads(result.stdout)
                        row = inventory['devices']['ios-27'][0]
                        if change.get('duplicate'):
                            inventory['devices']['ios-27'].append(dict(row))
                        else:
                            row.update(change)
                        result.stdout = json.dumps(inventory).encode()
                    return result
                with patch.object(run.simulator_infra, 'bounded', side_effect=wrong):
                    with self.assertRaises(RuntimeError):
                        run.launch_fixture(self.owner.current, self.app, session=self.owner)
                self.assertFalse(any(c[2] in ('install', 'launch') for c, _ in self.native.calls))
                self.assertFalse(self.owner.state['checkpoint'])

    def test_postinstall_canonical_path_guard_cannot_be_bypassed_by_cached_metadata(self):
        native = self.transport
        def replace_directory(command, timeout, **kwargs):
            result = native(command, timeout, **kwargs)
            if command[2] == 'install' and result.returncode == 0:
                applications = self.native.devices_root / command[3] / 'data/Containers/Data/Application'
                applications.rmdir()
                elsewhere = self.root / 'elsewhere'; elsewhere.mkdir()
                applications.symlink_to(elsewhere, target_is_directory=True)
            return result
        with patch.object(run.simulator_infra, 'bounded', side_effect=replace_directory):
            with self.assertRaisesRegex(RuntimeError, 'noncanonical'):
                run.launch_fixture(self.owner.current, self.app, session=self.owner)
        self.assertFalse(any(c[2] == 'launch' for c, _ in self.native.calls))
        self.assertFalse(self.owner.state['checkpoint'])


if __name__ == '__main__':
    unittest.main()
