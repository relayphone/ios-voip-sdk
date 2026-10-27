"""Host replay of the Runtime watch step's prelaunch inventory failure."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_runtime_watch_runner', ROOT / 'Tests/RuntimeEvents/run.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
sim = runtime.simulator_infra
DEVICE = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'


class RuntimeWatchSetupTests(unittest.TestCase):
    def test_inventory_timeout_never_launches_and_retries_at_most_once(self):
        with tempfile.TemporaryDirectory(prefix='runtime-watch-setup-') as temporary:
            root = Path(temporary)
            commands = []
            def create(command, timeout):
                self.assertEqual(command[2], 'create')
                return sim.Result(command, 0, (DEVICE + '\n').encode())
            owner = sim.Session(root / 'state.json', runner=create)
            owner.call(['xcrun', 'simctl', 'create', 'watch-fixture', 'device', 'runtime'], 30)
            def transport(command, timeout, **kwargs):
                commands.append((command[2:], timeout))
                if command[2] == 'install':
                    return sim.Result(command, 0)
                if command[2:5] == ['list', 'devices', '-j']:
                    return sim.Result(command, 124, timed_out=True)
                raise AssertionError('Unexpected native operation: ' + repr(command))
            with patch.object(runtime, 'session_transport', side_effect=transport), \
                 patch.object(runtime, 'run', side_effect=AssertionError('launch after inventory timeout')), \
                 patch.object(runtime, 'publish'), patch.object(sim, 'summary') as summary:
                with self.assertRaises(runtime.CommandError) as raised:
                    runtime.launch_fixture(DEVICE, root / 'fixture.app', session=owner)
            self.assertTrue(raised.exception.result.timed_out)
            self.assertTrue(raised.exception.result.failure_classified)
            operations = [item[0][0] for item in commands]
            self.assertIn(operations, (['install', 'list'], ['list', 'list']))
            self.assertLessEqual(operations.count('list'), 2)
            self.assertNotIn('launch', operations)
            self.assertFalse(owner.is_checkpointed())
            self.assertFalse(owner.state['retry_used'])
            self.assertTrue(any(call.args[0] in ('infra:list', 'infra:inventory')
                                for call in summary.call_args_list))


if __name__ == '__main__': unittest.main()
