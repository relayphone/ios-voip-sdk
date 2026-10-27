"""Host foreground transport tests; fake publications do not prove UIKit state."""
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid


ROOT = Path(__file__).resolve().parents[2]
RUNNER = runpy.run_path(str(Path(__file__).with_name('run.py')))
sys.path.insert(0, str(Path(__file__).parent))
from foreground_control import activate_existing, read_identity
DEVICE = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
BUNDLE = 'dev.callkitsim.inspector'


class ForegroundControlTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name).resolve()
        self.documents = self.root / 'container/Documents'
        self.documents.mkdir(parents=True)
        self.session = dict(schemaVersion=1, runID=str(uuid.uuid4()), pid=123,
                            bundleID='dev.callkitsim.eventfixture', profile='ios-27.0')
        self.started = int(time.time() * 1000)
        self.identity = dict(schemaVersion=1, nonce=str(uuid.uuid4()), pid=42, bundleID=BUNDLE,
                             dataContainer=str(self.documents.parent), startedWallTimeMS=self.started,
                             session=self.session)
        self.write('identity', self.identity)
        self.stop, self.spawned = threading.Event(), threading.Event()
        self.processes, self.commands, self.publications = [], [], []
        self.real_spawn = subprocess.Popen
        self.child_code = 'import time; time.sleep(20)'
        self.child_exits = False
        self.header_expected = False
        self.addCleanup(self.cleanup)

    def write(self, kind, value):
        path = self.documents / ('cksim-foreground-phase-' + kind + '.json')
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(value))
        temporary.replace(path)

    def cleanup(self):
        self.stop.set()
        if hasattr(self, 'writer'):
            self.writer.join(timeout=2)
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, 9)
            process.wait(timeout=2)

    def spawn(self, command, **kwargs):
        self.commands.append(command)
        process = self.real_spawn([sys.executable, '-c', self.child_code], **kwargs)
        self.processes.append(process)
        if self.child_exits:
            process.wait(timeout=2)
        if self.header_expected:
            end = time.monotonic() + 2
            while BUNDLE.encode() not in (self.root / 'launch.log').read_bytes():
                if time.monotonic() >= end:
                    self.fail('inert child did not publish its PID header')
                time.sleep(.001)
        self.spawned.set()
        return process

    def start_writer(self, transform=lambda value: value, *, once=False):
        def publish():
            self.spawned.wait(2)
            while not self.stop.is_set():
                request_path = self.documents / 'cksim-foreground-phase-request.json'
                if request_path.exists():
                    request = json.loads(request_path.read_text())
                    value = dict(request, applicationState='active', publicationID=str(uuid.uuid4()),
                                 wallTimeMS=int(time.time() * 1000), uptimeNS=time.monotonic_ns(), activeGeneration=0)
                    value = transform(value)
                    self.write('ack', value)
                    self.publications.append(value)
                    if once:
                        return
                self.stop.wait(.005)
        self.writer = threading.Thread(target=publish)
        self.writer.start()

    def activate(self, **kwargs):
        with patch.object(subprocess, 'Popen', side_effect=self.spawn):
            return activate_existing(DEVICE, self.identity, 'incoming', time.monotonic() + kwargs.pop('budget', .25),
                                     consumer_started_wall_ms=kwargs.pop('consumer_started_wall_ms', self.started),
                                     log=self.root / 'launch.log', **kwargs)

    def test_native_active_publication_resolves_pending_host(self):
        self.start_writer()
        with patch.object(subprocess, 'Popen', side_effect=self.spawn):
            result = activate_existing(DEVICE, self.identity, 'incoming', time.monotonic() + .3,
                                       consumer_started_wall_ms=self.started, log=self.root / 'launch.log')
        self.assertEqual({key: result[key] for key in self.identity}, self.identity)
        self.assertTrue(self.publications)
        self.assertEqual(self.commands, [['xcrun', 'simctl', 'launch', DEVICE, BUNDLE]])
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertTrue(outcome['qualifiedNativeAcknowledgement'])
        self.assertGreaterEqual(result['wallTimeMS'], outcome['reapedWallTimeMS'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_boolean_schema_cannot_impersonate_native_identity(self):
        self.start_writer(lambda value: dict(value, schemaVersion=True))
        with patch.object(subprocess, 'Popen', side_effect=self.spawn):
            with self.assertRaisesRegex(RuntimeError, 'invalid|identity'):
                activate_existing(DEVICE, self.identity, 'incoming', time.monotonic() + .3,
                                  consumer_started_wall_ms=self.started, log=self.root / 'launch.log')

    def test_legacy_rpc_wait_times_out_despite_independent_active_publications(self):
        self.write('request', dict(self.identity, phase='incoming', challenge=str(uuid.uuid4())))
        self.start_writer()
        with patch.object(subprocess, 'Popen', side_effect=self.spawn):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                RUNNER['activate_existing'](DEVICE, BUNDLE, 42, time.monotonic() + .1)
        self.assertTrue(self.publications)
        self.assertEqual(self.commands, [['xcrun', 'simctl', 'launch', DEVICE, BUNDLE]])

    def test_missing_or_foreign_challenge_cannot_qualify(self):
        with self.assertRaises(RuntimeError):
            self.activate(budget=.08)
        self.start_writer(lambda value: dict(value, challenge=str(uuid.uuid4())))
        with self.assertRaises(RuntimeError):
            self.activate(budget=.12)
        self.assertEqual(len(self.commands), 2)
        self.assertFalse(json.loads((self.root / 'launch.json').read_text())['qualifiedNativeAcknowledgement'])

    def test_current_challenge_invalid_evidence_is_terminal(self):
        mutations = (dict(applicationState='background'), dict(phase='other'), dict(pid=99),
                     dict(wallTimeMS=self.started - 6000), dict(wallTimeMS=self.started + 2000),
                     dict(uptimeNS=True), dict(activeGeneration=True), dict(publicationID='short'),
                     dict(session=dict(self.session, schemaVersion=True)))
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.start_writer(lambda value: dict(value, **mutation))
                try:
                    with self.assertRaisesRegex(RuntimeError, 'invalid|foreign|stale'):
                        self.activate()
                finally:
                    self.stop.set()
                    self.writer.join(timeout=2)
                    self.stop.clear()

    def test_original_deadline_and_native_consumer_budget_are_not_reset(self):
        self.start_writer()
        with self.assertRaisesRegex(RuntimeError, 'budget'):
            self.activate(consumer_started_wall_ms=self.started - 25001)
        self.assertEqual(self.commands, [])
        # A blocked read crossing the caller's short absolute deadline cannot qualify.
        import foreground_control
        original_read = foreground_control._read
        def delayed(path):
            value = original_read(path)
            if path.name.endswith('-ack.json'):
                time.sleep(.15)
            return value
        with patch.object(foreground_control, '_read', side_effect=delayed):
            with self.assertRaisesRegex(RuntimeError, 'budget'):
                self.activate(budget=.1)

    def test_frozen_ack_cannot_prove_active_after_owned_host_reap(self):
        self.start_writer(once=True)
        with self.assertRaisesRegex(RuntimeError, 'budget|publication'):
            self.activate(budget=.15)
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertTrue(outcome['qualifiedNativeAcknowledgement'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_older_fixture_identity_retains_its_native_start_with_consumer_budget(self):
        self.identity = dict(self.identity, bundleID=self.session['bundleID'], pid=self.session['pid'],
                             nonce=self.session['runID'], startedWallTimeMS=self.started - 60000)
        self.write('identity', self.identity)
        self.start_writer()
        result = self.activate()
        self.assertEqual(result['startedWallTimeMS'], self.started - 60000)
        self.assertEqual(result['pid'], self.session['pid'])

    def test_real_caller_keeps_older_fixture_identity_and_original_consumer_budget(self):
        inspector_identity = self.identity
        self.identity = dict(self.identity, bundleID=self.session['bundleID'], pid=self.session['pid'],
                             nonce=self.session['runID'], startedWallTimeMS=self.started - 60000)
        self.write('identity', self.identity)
        inspector = self.root / 'inspector'
        (inspector / 'Documents').mkdir(parents=True)
        (inspector / 'Documents/cksim-foreground-phase-identity.json').write_text(
            json.dumps(dict(inspector_identity, dataContainer=str(inspector))))
        channel = self.documents / 'channel'
        channel.mkdir()
        (channel / 'session.json').write_text(json.dumps(self.session))
        out = self.root / 'caller'
        out.mkdir()
        probe = SimpleNamespace(container=inspector, pid=inspector_identity['pid'],
                                nonce=inspector_identity['nonce'], started=self.started)
        connection = SimpleNamespace(is_alive=lambda: True)
        factory = RUNNER['foreground_control']
        activate = RUNNER['phase_activate_existing']
        self.start_writer()
        with patch.object(subprocess, 'Popen', side_effect=self.spawn), \
             patch.dict(factory.__globals__, phase_activate_existing=Mock(wraps=activate)):
            foreground = factory(DEVICE, self.session, channel, time.monotonic() + .3, out, probe, connection)
            foreground(self.session['bundleID'], self.session['pid'])
            arguments = factory.__globals__['phase_activate_existing'].call_args
        self.assertEqual(arguments.kwargs['consumer_started_wall_ms'], self.started)
        self.assertIs(arguments.kwargs['bridge_alive'], connection.is_alive)
        self.assertEqual(arguments.args[1], self.identity)
        request = json.loads((out / 'foreground-01-fixture-request.json').read_text())
        ack = json.loads((out / 'foreground-01-fixture-ack.json').read_text())
        self.assertEqual(request, dict(self.identity, phase='01-fixture', challenge=ack['challenge']))
        self.assertEqual(ack['startedWallTimeMS'], self.started - 60000)
        self.assertEqual(self.commands, [['xcrun', 'simctl', 'launch', DEVICE, self.session['bundleID']]])
        outcome = json.loads((out / 'foreground-01-fixture.json').read_text())
        self.assertTrue(outcome['qualifiedNativeAcknowledgement'])
        self.assertGreater(ack['wallTimeMS'], outcome['reapedWallTimeMS'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_nonzero_exit_and_conflicting_pid_header_are_terminal(self):
        for code in ('raise SystemExit(7)', 'print("' + BUNDLE + ': 99",flush=True); import time; time.sleep(20)'):
            with self.subTest(code=code):
                self.child_code = code
                self.child_exits = code.startswith('raise')
                self.header_expected = not self.child_exits
                self.start_writer()
                try:
                    with self.assertRaisesRegex(RuntimeError, 'failed|conflict'):
                        self.activate()
                finally:
                    self.stop.set()
                    self.writer.join(timeout=2)
                    self.stop.clear()

    def test_zero_exit_requires_matching_pid_header(self):
        self.child_code = 'pass'
        self.child_exits = True
        self.start_writer()
        with self.assertRaisesRegex(RuntimeError, 'conflict'):
            self.activate()

    def test_zero_exit_with_matching_original_pid_and_fresh_active_succeeds(self):
        self.child_code = 'print("' + BUNDLE + ': 42",flush=True)'
        self.child_exits = True
        self.start_writer()
        result = self.activate()
        self.assertEqual(result['pid'], 42)
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertEqual(outcome['hostExitCode'], 0)
        self.assertFalse(outcome['qualifiedNativeAcknowledgement'])

    def test_native_identity_change_and_uncertain_reap_are_terminal(self):
        import inspector_startup
        real_reap = inspector_startup.reap_group
        def changed(process):
            real_reap(process)
            self.write('identity', dict(self.identity, startedWallTimeMS=self.started - 1))
        self.start_writer()
        with patch.object(inspector_startup, 'reap_group', side_effect=changed):
            with self.assertRaisesRegex(RuntimeError, 'identity changed'):
                self.activate()
        self.write('identity', self.identity)
        def uncertain(process):
            real_reap(process)
            raise RuntimeError('group absence uncertain')
        with patch.object(inspector_startup, 'reap_group', side_effect=uncertain):
            with self.assertRaisesRegex(RuntimeError, 'uncertain'):
                self.activate()

    def test_cancellation_reaps_owned_host_and_never_returns_active_success(self):
        self.start_writer()
        sent = []
        def alive():
            if not sent:
                sent.append(True)
                os.kill(os.getpid(), signal.SIGINT)
            return True
        with self.assertRaises(KeyboardInterrupt):
            self.activate(bridge_alive=alive)
        self.assertEqual(len(self.commands), 1)
        with self.assertRaises(ProcessLookupError):
            os.killpg(self.processes[0].pid, 0)

    def test_noncanonical_paths_and_identity_boolean_fields_fail_before_launch(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.documents.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            read_identity(alias, bundle=BUNDLE, pid=42, nonce=self.identity['nonce'], session=self.session)
        identity_path = self.documents / 'cksim-foreground-phase-identity.json'
        identity_path.rename(self.root / 'identity.json')
        identity_path.symlink_to(self.root / 'identity.json')
        with self.assertRaises(ValueError):
            self.activate()
        identity_path.unlink()
        self.write('identity', dict(self.identity, session=dict(self.session, schemaVersion=True)))
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            self.activate()
        self.assertEqual(self.commands, [])


if __name__ == '__main__':
    unittest.main()
