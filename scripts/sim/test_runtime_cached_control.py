"""Invoke Runtime and the real cached CLI against a host-only fixture channel."""
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import sim
from test_runtime_install_adapter import AdapterNative, runtime


ROOT = Path(__file__).resolve().parents[2]
CLI = runpy.run_path(str(ROOT / 'Tools/cksim'))


class ChannelDiscoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='runtime-channel-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.device = str(uuid.uuid4()).upper()
        self.data = self.root / 'Devices' / self.device / 'data'
        self.apps = self.data / 'Containers/Data/Application'
        self.apps.mkdir(parents=True)
        self.identity = dict(schemaVersion=1, runID='fixture-fresh', bundleID=runtime.BUNDLE, pid=42)
        inventory = json.dumps(dict(devices={'ios-27': [dict(udid=self.device, state='Booted', dataPath=str(self.data))]}))
        for guard in (patch.object(runtime, 'lifecycle', return_value=inventory),
                      patch.object(subprocess, 'run', side_effect=AssertionError('native subprocess forbidden')),
                      patch.object(subprocess, 'Popen', side_effect=AssertionError('native Popen forbidden'))):
            guard.start(); self.addCleanup(guard.stop)
        def immediate(predicate):
            found = predicate()
            if found is None:
                raise RuntimeError('not ready')
            return found
        guard = patch.object(runtime, 'wait', side_effect=immediate)
        guard.start(); self.addCleanup(guard.stop)

    def channel(self, **changes):
        channel = self.apps / str(uuid.uuid4()) / 'Documents/.callkit-simulator'
        (channel / 'fixture-fresh').mkdir(parents=True)
        (channel / 'session.json').write_text(json.dumps(dict(self.identity, **changes)))
        (channel / 'fixture-fresh/events.jsonl').write_text('{"partial":')
        return channel

    def discover(self):
        return runtime.discover_fixture_channel(self.device, 'fixture-fresh', 42)

    def test_new_process_identity_retains_the_original_partial_journal(self):
        channel = self.channel()
        self.assertEqual(self.discover(), channel)
        self.assertEqual((channel / 'fixture-fresh/events.jsonl').read_text(), '{"partial":')

    def test_stale_or_mismatched_sessions_cannot_bind_the_new_process(self):
        for changes in (dict(runID='old'), dict(pid=43), dict(pid='42'),
                        dict(bundleID='other.app'), dict(schemaVersion=True)):
            channel = self.channel(**changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(RuntimeError, 'not ready'):
                self.discover()
            shutil.rmtree(channel.parents[1])

    def test_ambiguous_channels_fail_closed(self):
        self.channel(); self.channel()
        with self.assertRaisesRegex(RuntimeError, 'Ambiguous'):
            self.discover()

    def test_symlinked_session_and_journal_are_not_accepted(self):
        for name in ('session.json', 'fixture-fresh/events.jsonl'):
            channel = self.channel()
            path = channel / name
            saved = self.root / 'saved'
            path.rename(saved); path.symlink_to(saved)
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'not ready'):
                self.discover()
            shutil.rmtree(channel.parents[1]); saved.unlink()

    def test_inventory_path_must_belong_to_the_selected_simulator(self):
        self.channel()
        wrong = self.root / 'Devices' / str(uuid.uuid4()) / 'data'
        inventory = json.dumps(dict(devices={'ios-27': [dict(udid=self.device, state='Booted', dataPath=str(wrong))]}))
        with patch.object(runtime, 'lifecycle', return_value=inventory):
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                self.discover()


class CachedRuntimeTests(unittest.TestCase):
    def test_every_control_and_final_watch_reuse_replacement_channel_without_target_rpc(self):
        with tempfile.TemporaryDirectory(prefix='runtime-cached-cli-') as temporary:
            root = Path(temporary).resolve()
            package = root / 'package'
            package.mkdir()
            files = ('CKSimRuntime.dylib', 'CKSimLoader.dylib', 'cksim-notify', 'cksim',
                     'profiles/ios-27.0.json', 'VERSION')
            for name in files:
                path = package / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('1.0.0' if name == 'VERSION' else 'host fixture')
            (package / 'build-info.json').write_text(json.dumps(dict(schemaVersion=1, version='1.0.0',
                files={name: hashlib.sha256((package / name).read_bytes()).hexdigest() for name in files})))
            app = root / 'Fixture.app'
            app.mkdir()
            state_path = root / 'owner.json'
            rows, calls, cli_calls, processed = [], {}, [], set()
            session, channel = {}, None

            def event(name, **fields):
                rows.append(dict(session, event=name, sequence=len(rows) + 1,
                                 t_ms=len(rows), wallTimeMS=1000 + len(rows), **fields))
                (channel / session['runID'] / 'events.jsonl').write_text(
                    ''.join(json.dumps(row) + '\n' for row in rows))

            def changed(identifier, **values):
                calls[identifier].update(values)
                event('call.changed', uuid=identifier, **calls[identifier])

            def respond(_seconds):
                if channel is None:
                    raise AssertionError('control before channel publication')
                mailbox = channel / session['runID']
                for path in sorted((mailbox / 'requests').glob('*.json')):
                    if path.name in processed:
                        continue
                    processed.add(path.name)
                    request = json.loads(path.read_text())
                    operation = request['operation']
                    identifier = request.get('callUUID')
                    if operation == 'push':
                        identifier = str(uuid.uuid4()).upper()
                        calls[identifier] = dict(ended=False, connected=False, held=False, muted=False)
                        outgoing = request['payload']['operation'] == 'outgoing'
                        for name in ('push.received', 'push.completed', 'report.incoming',
                                     'report.completed', 'report.updated'):
                            event(name)
                        if outgoing:
                            event('report.connecting')
                            event('report.connected')
                        changed(identifier, connected=outgoing)
                    elif operation == 'answer':
                        changed(identifier, connected=True)
                        event('audio.activated')
                    elif operation == 'mute':
                        changed(identifier, muted=request['muted'])
                    elif operation == 'tones':
                        fields = dict(kind='tones', origin='host', callUUID=identifier,
                            transactionID='transaction', apiKind='fixture', deadlineMS=1000,
                            deadlineSeconds=1, latencyMS=100)
                        event('action.deadline', **fields)
                        event('action.settled', fulfilled=False, **fields)
                    elif operation in ('end', 'decline'):
                        changed(identifier, ended=True)
                    else:
                        self.assertIn(operation, ('hold-and-accept', 'end-and-accept'))
                        changed(request['activeCallUUID'], **({'held': True} if operation == 'hold-and-accept' else {'ended': True}))
                        changed(identifier, connected=True)
                    (mailbox / 'responses' / path.name).write_text(json.dumps(dict(request, success=True)))
                time.sleep(.001)

            class Native(AdapterNative):
                def __call__(self, command, timeout, *, env=None):
                    nonlocal channel
                    if command[2] == 'launch':
                        device = command[4]
                        self.container = root / 'Devices' / device / 'data/Containers/Data/Application' / str(uuid.uuid4())
                        channel = self.container / 'Documents/.callkit-simulator'
                        session.update(schemaVersion=1, runID=env['SIMCTL_CHILD_CKSIM_RUN_ID'],
                                       bundleID=runtime.BUNDLE, pid=os.getpid(), controlTransport='directory-watch-v1')
                        mailbox = channel / session['runID']
                        for name in ('requests', 'responses'):
                            (mailbox / name).mkdir(parents=True)
                        (channel / 'session.json').write_text(json.dumps(session))
                        (mailbox / 'events.jsonl').write_text('')
                    result = super().__call__(command, timeout, env=env)
                    if command[2] == 'launch' and result.returncode == 0:
                        result.stdout = (runtime.BUNDLE + ': ' + str(os.getpid()) + '\n').encode()
                    return result

            native = Native(root / 'unused')
            native.failures['install', 1] = 'timeout'
            original_run = runtime.run
            def transport(*args, **kwargs):
                if args == ('xcodebuild', '-version'):
                    return 'host fake Xcode'
                if args[0] != ROOT / 'Tools/cksim':
                    return original_run(*args, **kwargs)
                cli_calls.append(list(map(str, args)))
                output = io.StringIO()
                with patch.object(sys, 'argv', list(map(str, args))), redirect_stdout(output):
                    self.assertEqual(CLI['main'](), 0)
                return output.getvalue().strip()

            env = dict(GITHUB_STEP_SUMMARY=str(root / 'summary'), SIM_FAILURE_MARKER=str(root / 'marker'))
            with patch.dict(os.environ, env, clear=True), \
                 patch.object(sim, 'bounded', side_effect=native), \
                 patch.object(subprocess, 'run', side_effect=AssertionError('unmocked host/native subprocess')), \
                 patch.object(subprocess, 'Popen', side_effect=AssertionError('unmocked native Popen')):
                owner = sim.Session(state_path, runner=runtime.session_transport)
                runtime.lifecycle(owner, 'create', 'Cached fixture ', 'device', 'ios-27', timeout=30)
                original = owner.current
                runtime.lifecycle(owner, 'boot', original, timeout=60)
                runtime.lifecycle(owner, 'bootstatus', original, '-b', timeout=300)
                argv = ['run.py', '--package', str(package), '--app', str(app), '--out', str(root / 'out'),
                        '--simulator', original, '--simulator-state', str(state_path)]
                with patch.object(sys, 'argv', argv), patch.object(runtime, 'run', side_effect=transport), \
                     patch.object(runtime, 'record_environment'), patch.object(runtime, 'capture_diagnostics') as diagnostics, \
                     patch.dict(CLI['main'].__globals__, simctl=lambda *a, **k: self.fail('cached CLI attempted target RPC'),
                                time=SimpleNamespace(monotonic=time.monotonic, sleep=respond)), redirect_stdout(io.StringIO()):
                    runtime.main()
            current = json.loads(state_path.read_text())['current']
            self.assertNotEqual(current, original)
            self.assertTrue(cli_calls)
            for argv in cli_calls:
                self.assertEqual(argv[argv.index('--simulator') + 1], current)
                self.assertEqual(argv[argv.index('--app-container') + 1], str(channel.parent.parent))
            operations = [argv[argv.index('--app-container') + 2] for argv in cli_calls]
            self.assertEqual(operations.count('watch'), 1)
            self.assertEqual(set(operations), {'push', 'answer', 'mute', 'tones', 'decline',
                                             'hold-and-accept', 'end-and-accept', 'end', 'watch'})
            self.assertNotIn('get_app_container', native.counts)
            self.assertEqual(native.counts['launch'], 1)
            self.assertEqual(native.counts['create'], 2)
            self.assertEqual(diagnostics.call_args.kwargs['channel'], channel)
            self.assertEqual(diagnostics.call_args.args[1], current)
            self.assertFalse(diagnostics.call_args.kwargs['failed'])


if __name__ == '__main__':
    unittest.main()
