"""Runtime install recovery uses one persistent owned budget; all transports are fake."""
import copy
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

import sim


class Native:
    def __init__(self):
        self.devices, self.calls, self.counts, self.failures = {}, [], {}, {}
    def __call__(self, command, timeout):
        command = list(command)
        step = command[2]
        self.calls.append((command, timeout))
        self.counts[step] = count = self.counts.get(step, 0) + 1
        failure = self.failures.get((step, count))
        if step == 'create':
            device = str(uuid.UUID(int=count + (4 << 76) + (2 << 62)))
            self.devices[device] = command[3]
            output = (device + '\n').encode()
        elif step == 'list':
            output = json.dumps(dict(devices={'runtime': [dict(udid=device, name=name)
                for device, name in self.devices.items()]})).encode()
        else:
            output = b''
            if step == 'delete' and failure is None:
                self.devices.pop(command[3], None)
        return sim.Result(command, 124 if failure == 'timeout' else failure or 0,
                          stdout=output, timed_out=failure == 'timeout')


class RuntimeInstallCoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='runtime-install-core-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / 'owner.json'
        self.native = Native()
        self.environment = patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.root / 'summary'),
                                      SIM_FAILURE_MARKER=str(self.root / 'failure'))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.owner = sim.Session(self.path, runner=self.native)
        self.owner.call(['xcrun', 'simctl', 'create', 'M4 CI ', 'device', 'runtime'], 30)
        self.original = self.owner.current
        self.owner.call(['xcrun', 'simctl', 'boot', self.original], 60)
        self.owner.call(['xcrun', 'simctl', 'bootstatus', self.original, '-b'], 300)

    def resume(self, simulator=None):
        return sim.Session.resume(self.path, simulator=simulator, runner=self.native, inventory_timeout=60)

    def install(self, owner):
        return owner.call(['xcrun', 'simctl', 'install', owner.current, 'RuntimeFixture.app'], 180)

    def empty_owner(self):
        self.native = Native()
        self.path = self.root / 'empty-owner.json'
        return sim.Session(self.path, runner=self.native)

    def runtime_list(self, owner):
        return owner.call(['xcrun', 'simctl', 'list', 'runtimes', '-j'], 60)

    def test_initial_runtime_timeout_retries_query_only_and_exhausts_create_budget(self):
        owner = self.empty_owner()
        self.native.failures['list', 1] = 'timeout'
        self.assertEqual(self.runtime_list(owner).returncode, 0)
        self.assertEqual(self.native.counts, {'list': 2})
        self.assertIsNone(owner.current)
        self.assertTrue(owner.state['retry_used'])
        self.native.failures['create', 1] = 73
        self.assertEqual(owner.call(['xcrun', 'simctl', 'create', 'M4 CI ', 'device', 'runtime'], 30).returncode, 73)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertNotIn('delete', self.native.counts)

    def test_initial_runtime_retry_blocks_a_second_budget_for_install(self):
        owner = self.empty_owner()
        self.native.failures['list', 1] = 'timeout'
        self.assertEqual(self.runtime_list(owner).returncode, 0)
        owner.call(['xcrun', 'simctl', 'create', 'M4 CI ', 'device', 'runtime'], 30)
        self.native.failures['install', 1] = 'timeout'
        self.assertTrue(self.install(owner).timed_out)
        self.assertEqual(self.native.counts, {'list': 2, 'create': 1, 'install': 1})

    def test_owned_runtime_timeout_replaces_and_replays_preparation_before_query_retry(self):
        owner = self.resume(self.original)
        self.native.failures['list', 1] = 'timeout'
        self.assertEqual(self.runtime_list(owner).returncode, 0)
        self.assertNotEqual(owner.current, self.original)
        self.assertEqual(set(self.native.devices), {owner.current})
        self.assertEqual(self.native.counts, dict(create=2, boot=2, bootstatus=2, list=2, shutdown=1, delete=1))
        self.assertEqual([timeout for command, timeout in self.native.calls if command[2] == 'list'], [60, 60])

    def test_spent_install_budget_does_not_retry_runtime_query(self):
        owner = self.resume(self.original)
        self.native.failures['install', 1] = 'timeout'
        self.assertEqual(self.install(owner).returncode, 0)
        self.native.failures['list', 1] = 'timeout'
        self.assertTrue(self.runtime_list(owner).timed_out)
        self.assertEqual(self.native.counts['list'], 1)
        self.assertEqual(self.native.counts['create'], 2)

    def test_second_runtime_timeout_is_terminal_without_inventing_device_cleanup(self):
        owner = self.empty_owner()
        self.native.failures.update({('list', 1): 'timeout', ('list', 2): 'timeout'})
        result = self.runtime_list(owner)
        self.assertTrue(result.timed_out)
        self.assertTrue(result.failure_classified)
        self.assertEqual(self.native.counts, {'list': 2})
        self.assertTrue(owner.state['retry_used'])

    def test_borrowed_and_checkpointed_runtime_queries_never_retry(self):
        for borrowed in (True, False):
            with self.subTest(borrowed=borrowed):
                owner = (sim.Session.attach(self.path, self.original, runner=self.native) if borrowed else self.resume())
                if not borrowed:
                    owner.checkpoint()
                before = self.native.counts.get('list', 0)
                self.native.failures['list', before + 1] = 'timeout'
                self.assertTrue(self.runtime_list(owner).timed_out)
                self.assertEqual(self.native.counts['list'], before + 1)
                self.assertFalse(owner.state['retry_used'])
                self.assertEqual(self.native.counts['create'], 1)

    def test_other_list_shapes_or_non_timeout_statuses_never_retry(self):
        owner = self.resume()
        for command, failure in ((['list', 'devices', '-j'], 'timeout'),
                                 (['list', 'runtimes', '--json'], 'timeout'),
                                 (['list', 'runtimes', '-j'], 124),
                                 (['list', 'runtimes', '-j'], 73)):
            with self.subTest(command=command, failure=failure):
                before = self.native.counts.get('list', 0)
                self.native.failures['list', before + 1] = failure
                self.assertNotEqual(owner.call(['xcrun', 'simctl', *command], 60).returncode, 0)
                self.assertEqual(self.native.counts['list'], before + 1)
                self.assertFalse(owner.state['retry_used'])

    def test_cleanup_inventory_timeout_never_uses_runtime_retry(self):
        self.owner.state['owned'][0].update(id=None, uncertain=True)
        self.owner.save()
        self.native.failures['list', 1] = 'timeout'
        self.assertEqual(self.owner.cleanup().returncode, 1)
        self.assertEqual(self.native.counts['list'], 1)
        self.assertFalse(self.owner.state['retry_used'])
        self.assertEqual(len(json.loads(self.path.read_text())['owned']), 1)

    def test_resumed_install_timeout_replaces_only_owned_device_and_replays_once(self):
        self.native.failures['install', 1] = 'timeout'
        owner = self.resume(self.original)
        self.assertEqual(self.install(owner).returncode, 0)
        self.assertNotEqual(owner.current, self.original)
        self.assertEqual(set(self.native.devices), {owner.current})
        self.assertEqual(self.native.counts, dict(create=2, boot=2, bootstatus=2, install=2, shutdown=1, delete=1))
        self.assertEqual([command[3] for command, _ in self.native.calls if command[2] == 'install'],
                         [self.original, owner.current])
        bounds = dict(create=30, boot=60, bootstatus=300, install=180, shutdown=30, delete=30)
        for command, timeout in self.native.calls:
            self.assertEqual(timeout, bounds[command[2]])
        self.assertTrue(json.loads(self.path.read_text())['retry_used'])
        self.assertFalse((self.root / 'failure').exists())
        self.assertTrue(all(command[3].startswith('M4 CI ') and not command[3].startswith('M4 CI -')
                            for command, _ in self.native.calls if command[2] == 'create'))

    def test_second_failure_is_terminal_and_later_step_cannot_obtain_a_new_budget(self):
        self.native.failures.update({('install', 1): 'timeout', ('install', 2): 'timeout'})
        owner = self.resume(self.original)
        result = self.install(owner)
        self.assertTrue(result.timed_out)
        self.assertTrue(result.failure_classified)
        resumed = self.resume(owner.current)
        self.native.failures['boot', 3] = 73
        self.assertEqual(resumed.call(['xcrun', 'simctl', 'boot', resumed.current], 60).returncode, 73)
        self.assertEqual(self.native.counts['create'], 2)
        self.assertTrue((self.root / 'failure').exists())

    def test_checkpoint_from_another_owner_prevents_retry(self):
        owner = self.resume(self.original)
        self.owner.checkpoint()
        self.native.failures['install', 1] = 'timeout'
        self.assertTrue(self.install(owner).timed_out)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertFalse(json.loads(self.path.read_text())['retry_used'])

    def test_borrowed_session_never_replaces_or_deletes_ownership(self):
        borrowed = sim.Session.attach(self.path, self.original, runner=self.native)
        before = self.path.read_bytes()
        self.native.failures['install', 1] = 'timeout'
        self.assertTrue(self.install(borrowed).timed_out)
        self.assertEqual(self.native.counts['create'], 1)
        self.assertEqual(borrowed.cleanup().returncode, 0)
        self.assertNotIn('delete', self.native.counts)
        self.assertEqual(self.path.read_bytes(), before)

    def test_attach_resume_missing_or_wrong_expected_uuid_never_calls_native(self):
        before = len(self.native.calls)
        for factory in (sim.Session.attach, sim.Session.resume):
            with self.subTest(factory=factory):
                with self.assertRaises(ValueError):
                    factory(self.root / 'missing', self.original, runner=self.native)
                with self.assertRaises(ValueError):
                    factory(self.path, str(uuid.uuid4()), runner=self.native)
        self.assertFalse((self.root / 'missing').exists())
        self.assertEqual(len(self.native.calls), before)

    def test_stale_save_preserves_sticky_flags_and_refuses_changed_ownership(self):
        stale, newer = self.resume(), self.resume()
        newer.checkpoint()
        stale.save()
        self.assertTrue(json.loads(self.path.read_text())['checkpoint'])
        changed = copy.deepcopy(newer.state)
        changed['current'] = None
        changed['owned'] = []
        self.path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            stale.save()
        self.assertEqual(json.loads(self.path.read_text())['owned'], [])

    def test_changed_authoritative_current_refuses_native_call_and_checkpoint(self):
        owner = self.resume(self.original)
        borrowed = sim.Session.attach(self.path, self.original, runner=self.native)
        latest = json.loads(self.path.read_text())
        latest['current'] = str(uuid.uuid4())
        self.path.write_text(json.dumps(latest))
        before = len(self.native.calls)
        with self.assertRaises(ValueError):
            self.install(owner)
        with self.assertRaises(ValueError):
            owner.checkpoint()
        with self.assertRaises(ValueError):
            borrowed.save()
        self.assertEqual(len(self.native.calls), before)
        self.assertFalse(json.loads(self.path.read_text())['checkpoint'])

    def test_bounded_environment_uses_the_same_native_popen_topology(self):
        child = Mock(returncode=0)
        child.communicate.return_value = (b'original-output', b'')
        environment = {'PRIVATE_FIXTURE': 'host-value'}
        with patch.object(sim.subprocess, 'Popen', return_value=child) as popen:
            result = sim.bounded(['host-only-fixture'], 15, env=environment)
        self.assertEqual(result.stdout, b'original-output')
        popen.assert_called_once_with(['host-only-fixture'], stdout=sim.subprocess.PIPE,
            stderr=sim.subprocess.PIPE, start_new_session=True, env=environment)

    def test_atomic_reservation_has_no_second_budget_and_lock_fails_closed(self):
        first, stale = self.resume(), self.resume()
        self.assertTrue(first.reserve_retry())
        self.assertFalse(stale.reserve_retry())
        with open(str(self.path) + '.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                stale.reserve_retry()
        self.assertFalse(self.resume().reserve_retry())

    def test_resume_inventory_uses_exact_ci_bound_and_retains_other_owned_records(self):
        self.owner.state['owned'][0].update(id=None, uncertain=True)
        self.owner.save()
        owner = self.resume(self.original)
        self.assertEqual(owner.cleanup().returncode, 0)
        inventory = [(command, timeout) for command, timeout in self.native.calls if command[2] == 'list']
        self.assertEqual(len(inventory), 1)
        self.assertEqual(inventory[0][1], 60)
        self.assertEqual(self.native.devices, {})
        self.assertEqual(json.loads(self.path.read_text())['owned'], [])

    def test_privacy_keeps_main_nonretrying_nonprepared_behavior(self):
        owner = self.resume()
        prepared = copy.deepcopy(owner.state['prepared'])
        self.native.failures['privacy', 1] = 'timeout'
        self.assertTrue(owner.call(['xcrun', 'simctl', 'privacy', owner.current,
                                   'grant', 'microphone', 'fixture.bundle'], 60).timed_out)
        self.assertEqual(owner.state['prepared'], prepared)
        self.assertFalse(owner.state['retry_used'])
        self.assertEqual(self.native.counts['create'], 1)

    def test_known_transport_signal_is_infrastructure_even_after_checkpoint(self):
        owner = self.resume()
        owner.checkpoint()
        self.native.failures['launch', 1] = -signal.SIGALRM
        result = owner.call(['xcrun', 'simctl', 'launch', owner.current, 'fixture.bundle'], 15)
        self.assertTrue(result.failure_classified)
        summary = (self.root / 'summary').read_text()
        self.assertIn('infra:launch', summary)
        self.assertNotIn('product:', summary)

    def stateless_cli(self, result, command, accepted=False):
        stdout, stderr = Mock(), Mock()
        stderr.fileno.side_effect = OSError('host-only stream has no descriptor')
        arguments = ['call', *(['--accepted-status', '1'] if accepted else []), '', '3', *command]
        with patch.object(sim, 'bounded', return_value=result) as execute, \
             patch.object(sim.signal, 'signal'), patch.object(sim.sys, 'stdout', stdout), \
             patch.object(sim.sys, 'stderr', stderr):
            status = sim.main(arguments)
        execute.assert_called_once_with(command, 3)
        stdout.buffer.write.assert_called_once_with(result.stdout)
        stderr.buffer.write.assert_called_once_with(result.stderr)
        return status

    def test_stateless_known_transport_marks_terminal_host_failure_without_retry(self):
        for status, timed_out in ((124, True), (-signal.SIGALRM, False), (142, False)):
            with self.subTest(status=status):
                result = sim.Result(['private-host-sentinel'], status, b'original-output', b'', timed_out)
                self.assertEqual(self.stateless_cli(result, ['private-host-sentinel']), abs(status) if status >= 0 else 128 - status)
                self.assertTrue(result.failure_classified)
                self.assertTrue((self.root / 'failure').is_file())
                summary = (self.root / 'summary').read_text()
                self.assertIn('infra:host', summary)
                self.assertNotIn('private-host-sentinel', summary)

    def test_stateless_native_failure_marks_its_exact_operation(self):
        result = sim.Result([], 73, b'native-output', b'native-error')
        self.assertEqual(self.stateless_cli(result, ['xcrun', 'simctl', 'install', 'private-uuid', 'private-app']), 73)
        self.assertTrue(result.failure_classified)
        self.assertTrue((self.root / 'failure').is_file())
        summary = (self.root / 'summary').read_text()
        self.assertIn('infra:install', summary)
        self.assertNotIn('private-', summary)

    def test_stateless_ordinary_generic_statuses_and_accepted_one_remain_unclassified(self):
        for command, status, accepted in ((['host-only-fixture'], 73, False),
                (['host-only-fixture'], 124, False), (['host-only-fixture'], 127, False),
                (['host-only-fixture'], 1, True), (['xcrun', 'simctl', 'spawn', 'private-uuid'], 1, True)):
            with self.subTest(command=command, status=status):
                result = sim.Result(command, status)
                self.assertEqual(self.stateless_cli(result, command, accepted), status)
                self.assertFalse(result.failure_classified)
                self.assertFalse((self.root / 'failure').exists())
                self.assertFalse((self.root / 'summary').exists())

    def test_actual_host_signal_and_timeout_keep_status_and_terminal_marker(self):
        helper = Path(sim.__file__).resolve()
        for name, body, timeout, expected in (
                ('signal', 'import os,signal;os.kill(os.getpid(),signal.SIGALRM)', '3', 142),
                ('timeout', 'import time;time.sleep(5)', '.15', 124)):
            with self.subTest(name=name):
                (self.root / 'failure').unlink(missing_ok=True)
                result = subprocess.run([sys.executable, str(helper), 'call', '', timeout,
                                         sys.executable, '-c', body], capture_output=True, timeout=6)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertTrue((self.root / 'failure').is_file())
                self.assertIn('infra:host', (self.root / 'summary').read_text())


if __name__ == '__main__':
    unittest.main()
