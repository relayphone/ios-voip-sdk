"""Host foreground transport tests; fake publications do not prove UIKit state."""
from contextlib import contextmanager
import errno
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

    def start_writer(self):
        def publish():
            self.spawned.wait(2)
            while not self.stop.is_set():
                request_path = self.documents / 'cksim-foreground-phase-request.json'
                if request_path.exists():
                    request = json.loads(request_path.read_text())
                    value = dict(request, applicationState='active', publicationID=str(uuid.uuid4()),
                                 wallTimeMS=int(time.time() * 1000), uptimeNS=time.monotonic_ns(), activeGeneration=0)
                    self.write('ack', value)
                    self.publications.append(value)
                self.stop.wait(.005)
        self.writer = threading.Thread(target=publish)
        self.writer.start()

    def activate(self, **kwargs):
        clock = kwargs.pop('clock', time)
        with patch.object(subprocess, 'Popen', side_effect=self.spawn):
            return activate_existing(DEVICE, self.identity, 'incoming', clock.monotonic() + kwargs.pop('budget', .25),
                                     consumer_started_wall_ms=kwargs.pop('consumer_started_wall_ms', self.started),
                                     log=self.root / 'launch.log', **kwargs)

    @contextmanager
    def controlled_clock(self):
        import foreground_control
        import inspector_startup
        clock = SimpleNamespace(now=0.0)
        clock.monotonic = lambda: clock.now
        clock.time = lambda: self.started / 1000 + clock.now
        def advance(seconds):
            clock.now += seconds
        clock.sleep = advance
        # Fixture time controls these phase-specific deadlines; child ownership
        # and cleanup remain real.
        with patch.object(foreground_control, 'time', clock), \
             patch.object(inspector_startup, 'time', clock), \
             patch.object(inspector_startup.threading, 'Timer', return_value=Mock(ident=None)), \
             patch.dict(RUNNER['foreground_control'].__globals__, time=clock):
            yield clock

    def publish_ack(self, elapsed=0, *, transform=lambda value: value):
        request = json.loads((self.documents / 'cksim-foreground-phase-request.json').read_text())
        value = dict(request, applicationState='active', publicationID=str(uuid.uuid4()),
                     wallTimeMS=self.started + round(elapsed * 1000), uptimeNS=time.monotonic_ns(), activeGeneration=0)
        value = transform(value)
        self.write('ack', value)
        self.publications.append(value)

    @contextmanager
    def active_receipts(self, transform=lambda value: value):
        import foreground_control
        read = foreground_control._read
        def publish_before_read(path):
            if path.name.endswith('-ack.json'):
                clock.now += .01
                self.publish_ack(clock.now, transform=transform)
            return read(path)
        with self.controlled_clock() as clock, \
             patch.object(foreground_control, '_read', side_effect=publish_before_read):
            yield clock

    def test_native_active_publication_resolves_pending_host(self):
        with self.active_receipts() as clock:
            result = self.activate(clock=clock, budget=.3)
        self.assertEqual({key: result[key] for key in self.identity}, self.identity)
        self.assertTrue(self.publications)
        self.assertEqual(self.commands, [['xcrun', 'simctl', 'launch', DEVICE, BUNDLE]])
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertTrue(outcome['qualifiedNativeAcknowledgement'])
        self.assertGreaterEqual(result['wallTimeMS'], outcome['reapedWallTimeMS'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_fresh_active_after_twenty_five_seconds_uses_host_deadline(self):
        with self.active_receipts() as clock:
            clock.now = 30
            result = self.activate(clock=clock, budget=1)
        self.assertEqual(result['startedWallTimeMS'], self.started)
        self.assertGreater(result['wallTimeMS'] - self.started, 25000)
        self.assertEqual(len(self.commands), 1)
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertGreater(result['wallTimeMS'], outcome['reapedWallTimeMS'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_boolean_schema_cannot_impersonate_native_identity(self):
        with self.active_receipts(lambda value: dict(value, schemaVersion=True)) as clock:
            with self.assertRaisesRegex(RuntimeError, 'invalid|identity'):
                self.activate(clock=clock, budget=.3)

    def test_legacy_rpc_wait_times_out_despite_independent_active_publications(self):
        self.write('request', dict(self.identity, phase='incoming', challenge=str(uuid.uuid4())))
        self.start_writer()
        with patch.object(subprocess, 'Popen', side_effect=self.spawn):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                RUNNER['activate_existing'](DEVICE, BUNDLE, 42, time.monotonic() + .1)
        self.assertTrue(self.publications)
        self.assertEqual(self.commands, [['xcrun', 'simctl', 'launch', DEVICE, BUNDLE]])

    def test_missing_or_foreign_challenge_cannot_qualify(self):
        with self.controlled_clock() as clock:
            with self.assertRaises(RuntimeError):
                self.activate(clock=clock, budget=.08)
        with self.active_receipts(lambda value: dict(value, challenge=str(uuid.uuid4()))) as clock:
            with self.assertRaises(RuntimeError):
                self.activate(clock=clock, budget=.12)
        self.assertEqual(len(self.commands), 2)
        self.assertFalse(json.loads((self.root / 'launch.json').read_text())['qualifiedNativeAcknowledgement'])

    def test_current_challenge_invalid_evidence_is_terminal(self):
        mutations = (dict(applicationState='background'), dict(phase='other'), dict(pid=99),
                     dict(wallTimeMS=self.started - 6000), dict(wallTimeMS=self.started + 2000),
                     dict(uptimeNS=True), dict(activeGeneration=True), dict(publicationID='short'),
                     dict(session=dict(self.session, schemaVersion=True)))
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with self.active_receipts(lambda value: dict(value, **mutation)) as clock:
                    with self.assertRaisesRegex(RuntimeError, 'invalid|foreign|stale'):
                        self.activate(clock=clock)

    def test_original_host_deadline_is_not_reset_and_future_start_is_rejected(self):
        import foreground_control
        with self.active_receipts() as clock:
            with self.assertRaisesRegex(RuntimeError, 'budget'):
                self.activate(clock=clock, budget=0)
            with self.assertRaisesRegex(RuntimeError, 'future'):
                self.activate(clock=clock, consumer_started_wall_ms=self.started + 1001)
            self.assertEqual(self.commands, [])
            # A blocked read crossing the caller's short absolute deadline cannot qualify.
            original_read = foreground_control._read
            def delayed(path):
                value = original_read(path)
                if path.name.endswith('-ack.json'):
                    self.assertIsNotNone(value)
                    clock.now += .15
                return value
            with patch.object(foreground_control, '_read', side_effect=delayed):
                with self.assertRaisesRegex(RuntimeError, 'budget'):
                    self.activate(clock=clock, budget=.1)

    def test_frozen_ack_cannot_prove_active_after_owned_host_reap(self):
        def spawn_with_frozen_ack(command, **kwargs):
            process = self.spawn(command, **kwargs)
            self.publish_ack()
            return process
        with self.controlled_clock(), \
             patch.object(subprocess, 'Popen', side_effect=spawn_with_frozen_ack):
            with self.assertRaisesRegex(RuntimeError, 'budget|publication'):
                activate_existing(DEVICE, self.identity, 'incoming', .15,
                                  consumer_started_wall_ms=self.started, log=self.root / 'launch.log')
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertTrue(outcome['qualifiedNativeAcknowledgement'])
        self.assertFalse(outcome['timedOut'])
        self.assertEqual(len(self.publications), 1)
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_older_fixture_identity_retains_its_native_start_with_consumer_budget(self):
        self.identity = dict(self.identity, bundleID=self.session['bundleID'], pid=self.session['pid'],
                             nonce=self.session['runID'], startedWallTimeMS=self.started - 60000)
        self.write('identity', self.identity)
        with self.active_receipts() as clock:
            result = self.activate(clock=clock)
        self.assertEqual(result['startedWallTimeMS'], self.started - 60000)
        self.assertEqual(result['pid'], self.session['pid'])

    def test_first_atomic_ack_publication_can_follow_a_missing_metadata_read(self):
        import foreground_control
        path = self.documents / 'cksim-foreground-phase-ack.json'
        publication = dict(self.identity, challenge=str(uuid.uuid4()))
        original_stat = Path.stat
        published = False

        def publish_after_missing_stat(candidate, *args, **kwargs):
            nonlocal published
            if candidate == path and not published:
                published = True
                self.write('ack', publication)
                raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), path)
            return original_stat(candidate, *args, **kwargs)

        with patch.object(Path, 'stat', publish_after_missing_stat):
            self.assertIsNone(foreground_control._read(path))
        self.assertTrue(published)
        self.assertEqual(foreground_control._read(path), publication)

    def test_non_regular_foreground_evidence_is_terminal(self):
        import foreground_control
        path = self.documents / 'cksim-foreground-phase-ack.json'
        path.mkdir()
        with self.assertRaisesRegex(RuntimeError, 'not a regular file'):
            foreground_control._read(path)

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
        with self.active_receipts() as clock, \
             patch.object(subprocess, 'Popen', side_effect=self.spawn), \
             patch.dict(factory.__globals__, phase_activate_existing=Mock(wraps=activate)):
            foreground = factory(DEVICE, self.session, channel, clock.monotonic() + .3, out, probe, connection)
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
                with self.active_receipts() as clock:
                    with self.assertRaisesRegex(RuntimeError, 'failed|conflict'):
                        self.activate(clock=clock)

    def test_zero_exit_requires_matching_pid_header(self):
        self.child_code = 'pass'
        self.child_exits = True
        with self.active_receipts() as clock:
            with self.assertRaisesRegex(RuntimeError, 'conflict'):
                self.activate(clock=clock)

    def test_zero_exit_with_matching_original_pid_and_fresh_active_succeeds(self):
        self.child_code = 'print("' + BUNDLE + ': 42",flush=True)'
        self.child_exits = True
        with self.active_receipts() as clock:
            result = self.activate(clock=clock)
        self.assertEqual(result['pid'], 42)
        outcome = json.loads((self.root / 'launch.json').read_text())
        self.assertEqual(outcome['hostExitCode'], 0)
        self.assertFalse(outcome['qualifiedNativeAcknowledgement'])
        self.assertNotEqual(result['publicationID'], self.publications[0]['publicationID'])
        self.assertGreater(result['wallTimeMS'], outcome['reapedWallTimeMS'])
        with self.assertRaises(ProcessLookupError):
            os.killpg(outcome['hostPID'], 0)

    def test_native_identity_change_and_uncertain_reap_are_terminal(self):
        import inspector_startup
        real_reap = inspector_startup.reap_group
        def changed(process):
            real_reap(process)
            self.write('identity', dict(self.identity, startedWallTimeMS=self.started - 1))
        with self.active_receipts() as clock, \
             patch.object(inspector_startup, 'reap_group', side_effect=changed):
            with self.assertRaisesRegex(RuntimeError, 'identity changed'):
                self.activate(clock=clock)
        self.write('identity', self.identity)
        def uncertain(process):
            real_reap(process)
            raise RuntimeError('group absence uncertain')
        with self.active_receipts() as clock, \
             patch.object(inspector_startup, 'reap_group', side_effect=uncertain):
            with self.assertRaisesRegex(RuntimeError, 'uncertain'):
                self.activate(clock=clock)

    def test_cancellation_reaps_owned_host_and_never_returns_active_success(self):
        sent = []
        def alive():
            if not sent:
                sent.append(True)
                os.kill(os.getpid(), signal.SIGINT)
            return True
        with self.active_receipts() as clock:
            with self.assertRaises(KeyboardInterrupt):
                self.activate(clock=clock, bridge_alive=alive)
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
        with self.controlled_clock() as clock:
            with self.assertRaises(ValueError):
                self.activate(clock=clock)
        identity_path.unlink()
        self.write('identity', dict(self.identity, session=dict(self.session, schemaVersion=True)))
        with self.controlled_clock() as clock:
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                self.activate(clock=clock)
        self.assertEqual(self.commands, [])


if __name__ == '__main__':
    unittest.main()
