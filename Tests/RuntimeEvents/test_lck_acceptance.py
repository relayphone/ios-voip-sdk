"""Independent journal-oracle controls; native callbacks supply the real acceptance data."""
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

import lck_acceptance as acceptance
from test_runtime_install_adapter import AdapterNative


class JournalOracleTests(unittest.TestCase):
    def test_changed_callback_without_matching_manager_snapshot_is_not_acceptance(self):
        rows = [dict(event='lck.fixture.changed', callUUID='A', state='joined'),
                dict(event='lck.fixture.snapshot', conversations=[dict(callUUID='A', state='idle')])]
        self.assertFalse(acceptance.snapshot_matches(rows, {'A': 'joined'}))
        rows[-1]['conversations'][0]['state'] = 'joined'
        self.assertTrue(acceptance.snapshot_matches(rows, {'A': 'joined'}))
        rows[-1]['conversations'] = []
        self.assertTrue(acceptance.snapshot_matches(rows, {'A': 'left'}))

    def test_reader_rejects_a_different_runtime_session(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            journey = acceptance.Journey('owned', root, root / 'out')
            journey.channel.mkdir(parents=True)
            journey.session = dict(runID='expected')
            (journey.channel / 'session.json').write_text(json.dumps(dict(runID='replacement')))
            with self.assertRaisesRegex(AssertionError, 'session changed'):
                journey.rows()


class ContainerDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.session = dict(schemaVersion=1, runID='fresh-run', bundleID=acceptance.BUNDLE, pid=123,
                            profile='ios-27.0', controlTransport='directory-watch-v1')

    def candidate(self, **changes):
        container = self.root / str(uuid.uuid4()).upper()
        session = dict(self.session, **changes)
        channel = container / 'Documents/.callkit-simulator'
        journal = channel / session['runID']
        journal.mkdir(parents=True)
        (channel / 'session.json').write_text(json.dumps(session))
        row = dict(session, event='lck.fixture.ready', sequence=1, main=True, t_ms=1, wallTimeMS=1)
        (journal / 'events.jsonl').write_text(json.dumps(row) + '\n')
        return container

    def resolve(self):
        return acceptance.resolve_container(self.root, 'fresh-run', acceptance.BUNDLE, 123)

    def native_session(self, identifier):
        session = acceptance.simulator_infra.Session(self.root / 'shared-session.json',
            runner=lambda command, timeout: acceptance.simulator_infra.Result(command, 0,
                stdout=(identifier + '\n').encode()))
        session.call(['xcrun', 'simctl', 'create', 'fixture', 'device-type', acceptance.RUNTIME], 5)
        return session

    def test_stale_session_does_not_resolve_the_initial_container(self):
        self.candidate(runID='stale-run')
        self.assertIsNone(self.resolve())
        actual = self.candidate()
        self.assertEqual(self.resolve(), (actual, self.session))

    def test_wrong_launch_pid_is_rejected(self):
        self.candidate(pid=456)
        with self.assertRaisesRegex(RuntimeError, 'PID'):
            self.resolve()

    def test_journal_identity_must_match_the_pinned_session(self):
        actual = self.candidate()
        journal = actual / 'Documents/.callkit-simulator/fresh-run/events.jsonl'
        row = json.loads(journal.read_text())
        row['pid'] = 456
        journal.write_text(json.dumps(row) + '\n')
        with self.assertRaisesRegex(RuntimeError, 'journal identity'):
            self.resolve()

    def test_ambiguous_matching_containers_are_rejected(self):
        self.candidate()
        self.candidate()
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            self.resolve()

    def test_diagnostics_do_not_follow_symlinked_journal_descendants(self):
        container = self.candidate()
        outside = self.root / 'outside-payload'
        outside.write_text('outside container')
        channel = container / 'Documents/.callkit-simulator'
        (channel / 'escaped-file').symlink_to(outside)
        journey = acceptance.Journey('owned', None, self.root / 'out', applications=self.root)
        journey.name, journey.run_id = 'startup', 'fresh-run'
        journey.save()
        copied = self.root / 'out/startup/unpinned-runtime-journals' / container.name
        self.assertFalse((copied / 'escaped-file').exists())
        self.assertFalse((copied / 'escaped-file').is_symlink())

    def test_unpinned_diagnostics_reject_escaped_session_path(self):
        container = self.candidate()
        session = container / 'Documents/.callkit-simulator/session.json'
        outside = self.root / 'outside-session.json'
        outside.write_text(session.read_text())
        session.unlink()
        session.symlink_to(outside)
        journey = acceptance.Journey('owned', None, self.root / 'out', applications=self.root)
        journey.name, journey.run_id = 'startup', 'fresh-run'
        journey.save()
        self.assertFalse((self.root / 'out/startup/unpinned-runtime-journals').exists())

    def test_borrowed_target_must_belong_to_ios_27_not_merely_have_it_installed(self):
        identifier = str(uuid.uuid4()).upper()
        inventory = dict(devices={'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
            dict(udid=identifier, state='Booted', dataPath=str(self.root / identifier / 'data'))]})
        session = Mock(current=identifier)
        with patch.object(acceptance, 'lifecycle', return_value=json.dumps(inventory)) as native:
            with self.assertRaisesRegex(RuntimeError, 'iOS 27.0'):
                acceptance.simulator_applications(identifier, session=session)
        self.assertIs(native.call_args.args[0], session)

    def test_inventory_cannot_cache_a_symlinked_application_directory(self):
        identifier = str(uuid.uuid4()).upper()
        data = self.root.resolve() / identifier / 'data'
        applications = data / 'Containers/Data/Application'
        applications.parent.mkdir(parents=True)
        outside = self.root.resolve() / 'elsewhere'
        outside.mkdir()
        applications.symlink_to(outside, target_is_directory=True)
        inventory = dict(devices={acceptance.RUNTIME: [
            dict(udid=identifier, state='Booted', dataPath=str(data))]})
        with patch.object(acceptance, 'lifecycle', return_value=json.dumps(inventory)):
            with self.assertRaisesRegex(RuntimeError, 'noncanonical'):
                acceptance.simulator_applications(identifier, session=Mock(current=identifier))

    def test_borrowed_simulator_is_never_created_or_cleaned_even_on_failure(self):
        identifier = str(uuid.uuid4()).upper()
        session = self.native_session(identifier)
        ledger = session.path
        session.reserve_retry()
        session.checkpoint()
        before = ledger.read_bytes()
        with patch.dict(os.environ, SIM_STATE=str(ledger)), \
             patch.object(acceptance, 'create') as create, patch.object(acceptance, 'cleanup') as cleanup:
            with self.assertRaisesRegex(ValueError, 'journey failed'):
                with acceptance.simulator_scope(identifier, self.root) as (resumed, owned):
                    self.assertEqual(resumed.current, identifier)
                    self.assertTrue(resumed.state['retry_used'])
                    self.assertTrue(resumed.is_checkpointed())
                    self.assertFalse(owned)
                    raise ValueError('journey failed')
        create.assert_not_called()
        cleanup.assert_not_called()
        self.assertEqual(ledger.read_bytes(), before)

    def test_borrowed_simulator_requires_the_existing_session_before_native_work(self):
        identifier = str(uuid.uuid4()).upper()
        with patch.dict(os.environ, {}, clear=True), patch.object(acceptance, 'lifecycle') as native:
            with self.assertRaisesRegex(ValueError, 'SIM_STATE'):
                with acceptance.simulator_scope(identifier, self.root):
                    self.fail('Borrowed simulator without its session was accepted')
        native.assert_not_called()

    def test_launch_records_the_checkpoint_in_the_existing_session(self):
        identifier = str(uuid.uuid4()).upper()
        session = self.native_session(identifier)
        journey = acceptance.Journey(identifier, self.root, self.root / 'out', native_session=session)
        def launched(command, timeout, **kwargs):
            self.assertTrue(session.is_checkpointed(), 'checkpoint must precede native launch')
            return acceptance.simulator_infra.Result(command, 0, stdout=(acceptance.BUNDLE + ': 123').encode())
        with patch.object(acceptance.simulator_infra, 'bounded', side_effect=launched) as native, \
             patch.object(acceptance, 'container_session', return_value=self.session), \
             patch.object(journey, 'save'), patch.object(journey, 'wait'), \
             patch.object(journey, 'rows', return_value=[dict(event='provider.created')]):
            journey.begin('launch-checkpoint')
        native.assert_called_once()
        self.assertEqual(native.call_args.args[0], ['xcrun', 'simctl', 'launch',
            '--terminate-running-process', identifier, acceptance.BUNDLE])
        self.assertEqual(native.call_args.kwargs['env']['SIMCTL_CHILD_CKSIM_RUN_ID'], journey.run_id)
        self.assertTrue(json.loads(session.path.read_text())['checkpoint'])
        self.assertFalse(session.state['retry_used'])

    def test_launch_timeout_cannot_replace_or_replay_the_existing_session(self):
        identifier = str(uuid.uuid4()).upper()
        session = self.native_session(identifier)
        session.checkpoint()
        journey = acceptance.Journey(identifier, self.root, self.root / 'out', native_session=session)
        def timed_out(command, timeout, **kwargs):
            return acceptance.simulator_infra.Result(command, 124, timed_out=True)
        with patch.object(acceptance.simulator_infra, 'bounded', side_effect=timed_out) as native, \
             patch.object(session, 'replacement') as replacement, patch.object(journey, 'save'):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                journey.begin('unknown-launch')
        native.assert_called_once()
        replacement.assert_not_called()
        self.assertEqual(session.current, identifier)
        self.assertTrue(json.loads(session.path.read_text())['checkpoint'])
        self.assertFalse(session.state['retry_used'])

    def test_stale_cached_simulator_cannot_launch_or_refresh_inventory(self):
        identifier = str(uuid.uuid4()).upper()
        session = self.native_session(identifier)
        journey = acceptance.Journey(str(uuid.uuid4()).upper(), None, self.root / 'out',
                                     applications=self.root, native_session=session)
        with patch.object(acceptance, 'lifecycle', side_effect=AssertionError('native work before cache validation')) as native, \
             patch.object(acceptance, 'simulator_applications', side_effect=AssertionError('inventory refresh')) as inventory:
            with self.assertRaisesRegex(ValueError, 'cached simulator'):
                journey.begin('stale-cached-device')
        native.assert_not_called()
        inventory.assert_not_called()


class PreinstallRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='lck-preinstall-owner-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.native = AdapterNative(self.root / 'container')
        self.installed = set()
        self.inventoried = []
        self.runtime = acceptance.RUNTIME
        self.app = self.root / 'LCKFixture.app'; self.app.mkdir()
        for guard in (patch.dict(os.environ, {}, clear=True),
                      patch.object(acceptance.simulator_infra, 'bounded', side_effect=self.transport)):
            guard.start(); self.addCleanup(guard.stop)
        self.owner = acceptance.simulator_infra.Session(self.root / 'owner.json', runner=acceptance.session_transport)
        acceptance.lifecycle(self.owner, 'create', 'LCK preinstall ', 'device', acceptance.RUNTIME, timeout=30)
        acceptance.lifecycle(self.owner, 'boot', self.owner.current, timeout=60)
        acceptance.lifecycle(self.owner, 'bootstatus', self.owner.current, '-b', timeout=300)

    def transport(self, command, timeout, **kwargs):
        if command[2:5] == ['list', 'devices', '-j']:
            self.assertFalse(self.installed.intersection(self.native.devices), 'LCK inventory after install')
            self.inventoried.append(next(iter(self.native.devices)))
            self.assertEqual(timeout, 180)
        result = self.native(command, timeout, **kwargs)
        if command[2:4] == ['list', 'runtimes']:
            result.stdout = json.dumps(dict(runtimes=[dict(identifier=acceptance.RUNTIME, isAvailable=True)])).encode()
        elif command[2:4] == ['list', 'devices']:
            rows = json.loads(result.stdout)['devices']['ios-27']
            result.stdout = json.dumps(dict(devices={self.runtime: rows})).encode()
        elif command[2] == 'install' and result.returncode == 0:
            self.installed.add(command[3])
        return result

    def run_to_consumer(self, *, wrong_runtime=False):
        class ConsumerReached(Exception):
            pass
        argv = ['lck_acceptance.py', '--app', str(self.app), '--out', str(self.root / 'out'),
                '--simulator', self.owner.current, '--filter-only']
        expected = RuntimeError if wrong_runtime else ConsumerReached
        with patch.dict(os.environ, SIM_STATE=str(self.owner.path)), \
             patch.object(acceptance.sys, 'argv', argv), patch.object(acceptance, 'Journey') as journey, \
             patch.object(acceptance, 'run_filter_case', side_effect=ConsumerReached()) as consumer:
            with self.assertRaises(expected):
                acceptance.main()
        if wrong_runtime:
            journey.assert_not_called(); consumer.assert_not_called()
            self.assertFalse(any(c[2] == 'install' for c, _ in self.native.calls))
            self.assertFalse(json.loads(self.owner.path.read_text())['retry_used'])
        else:
            final = json.loads(self.owner.path.read_text())['current']
            self.assertEqual(journey.call_args.args[0], final)
            self.assertEqual(journey.call_args.kwargs['applications'],
                             self.native.devices_root / final / 'data/Containers/Data/Application')
            consumer.assert_called_once()
            return final

    def test_owning_main_collects_inventory_before_first_install(self):
        original = self.owner.current
        self.assertEqual(self.run_to_consumer(), original)
        self.assertEqual(self.inventoried, [original])

    def test_owning_main_accepts_slow_preinstall_inventory(self):
        queries = []
        def slow(command, timeout, **kwargs):
            if command[2:4] == ['list', 'devices']:
                queries.append(timeout)
                if timeout < 91:
                    return acceptance.simulator_infra.Result(command, 124, timed_out=True)
            return self.transport(command, timeout, **kwargs)
        with patch.object(acceptance.simulator_infra, 'bounded', side_effect=slow):
            self.run_to_consumer()
        self.assertEqual(queries, [180])

    def test_owning_main_recovers_one_inventory_timeout(self):
        self.native.failures['list', 2] = 'timeout'  # Runtimes are queried first.
        original = self.owner.current
        self.assertEqual(self.run_to_consumer(), original)
        self.assertEqual(self.inventoried, [original, original])
        self.assertFalse(json.loads(self.owner.path.read_text())['retry_used'])

    def test_owning_main_passes_replacement_path_to_the_first_consumer(self):
        original = self.owner.current
        self.native.failures['install', 1] = 'timeout'
        final = self.run_to_consumer()
        self.assertNotEqual(final, original)
        self.assertEqual(self.inventoried, [original, final])

    def test_prepared_replay_and_retried_install_share_the_replacement_cache(self):
        original = self.owner.current
        acceptance.lifecycle(self.owner, 'install', original, self.app, timeout=180)
        self.installed.clear()
        self.native.failures['install', 2] = 'timeout'
        final = self.run_to_consumer()
        self.assertEqual(self.inventoried, [original, final])

    def test_wrong_os_metadata_cannot_install_or_start_a_consumer(self):
        self.runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
        self.run_to_consumer(wrong_runtime=True)


if __name__ == '__main__':
    unittest.main()
