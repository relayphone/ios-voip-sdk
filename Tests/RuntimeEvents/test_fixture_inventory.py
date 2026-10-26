"""Fixture discovery must not contact CoreSimulator after app launch."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run


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


if __name__ == '__main__':
    unittest.main()
