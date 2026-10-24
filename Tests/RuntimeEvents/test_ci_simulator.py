import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ci_simulator


UID = 'CDE18392-916F-49F2-B324-B1EEC04D18A5'
NAME = 'M4 CI CDE18392-916F-49F2-B324-B1EEC04D18A5'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
RUNTIMES = json.dumps({'runtimes': [dict(identifier=RUNTIME, version='27.0',
                                        platform='iOS', isAvailable=True)]})


class SimulatorOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.record = Path(self.work.name) / 'owned-simulator'

    def test_create_records_only_owned_uuid_and_exports_it_without_booting(self):
        env_file = Path(self.work.name) / 'env'
        env_file.write_text('EXISTING=value\n')
        with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, UID]) as transport:
            self.assertEqual(ci_simulator.create(RUNTIME, self.record, env_file), UID)
        self.assertEqual(self.record.read_text(), UID + '\n')
        self.assertEqual(env_file.read_text(), 'EXISTING=value\nCKSIM_TEST_SIMULATOR=' + UID + '\n')
        self.assertEqual(len(transport.call_args_list), 2)
        for call in transport.call_args_list:
            self.assertEqual(call.kwargs, {'timeout': 60})
        create_args = transport.call_args_list[1].args
        self.assertEqual(create_args[:3], ('xcrun', 'simctl', 'create'))
        self.assertEqual(create_args[-2:], ('com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', RUNTIME))

    def test_env_failure_records_uuid_before_cleanup_and_preserves_original_error(self):
        def failed_cleanup(devices):
            self.assertEqual(devices, [UID])
            self.assertEqual(self.record.read_text(), UID + '\n')
            raise RuntimeError('cleanup also failed')
        bad_env = Path(self.work.name) / 'absent' / 'env'
        with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, UID]):
            with patch.object(ci_simulator, 'remove_simulators', side_effect=failed_cleanup):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(FileNotFoundError):
                    ci_simulator.create(RUNTIME, self.record, bad_env)
        self.assertEqual(self.record.read_text(), UID + '\n', 'retain ownership for a cleanup retry')

    def test_env_failure_removes_ownership_after_successful_cleanup(self):
        with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, UID]):
            with patch.object(ci_simulator, 'remove_simulators') as remove:
                with self.assertRaises(FileNotFoundError):
                    ci_simulator.create(RUNTIME, self.record, Path(self.work.name) / 'missing' / 'env')
        remove.assert_called_once_with([UID])
        self.assertFalse(self.record.exists())

    def test_record_persistence_failure_cleans_created_simulator(self):
        with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, UID]):
            with patch.object(ci_simulator.os, 'fsync', side_effect=[None, OSError('disk full')]):
                with patch.object(ci_simulator, 'remove_simulators') as remove:
                    with self.assertRaisesRegex(OSError, 'disk full'):
                        ci_simulator.create(RUNTIME, self.record)
        remove.assert_called_once_with([UID])
        self.assertFalse(self.record.exists())

    def test_create_timeout_recovers_only_exact_persisted_name(self):
        def transport(*args, **kwargs):
            self.assertEqual(kwargs, {'timeout': 60})
            if args[2:4] == ('list', 'runtimes'):
                return RUNTIMES
            if args[2] == 'create':
                self.assertEqual(args[3], NAME)
                self.assertEqual(self.record.read_text(), 'name:' + NAME + '\n')
                raise RuntimeError('create timed out')
            self.assertEqual(args[2:], ('list', 'devices', '-j'))
            return json.dumps({'devices': {RUNTIME: [dict(name=NAME + '-other', udid='unrelated'),
                                                    dict(name=NAME, udid=UID)]}})
        with patch.object(ci_simulator.uuid, 'uuid4', return_value=UID):
            with patch.object(ci_simulator, 'run', side_effect=transport):
                with patch.object(ci_simulator, 'remove_simulators') as remove:
                    with self.assertRaisesRegex(RuntimeError, 'create timed out'):
                        ci_simulator.create(RUNTIME, self.record)
        remove.assert_called_once_with([UID])
        self.assertFalse(self.record.exists())

    def test_create_timeout_keeps_name_when_inventory_recovery_fails(self):
        with patch.object(ci_simulator.uuid, 'uuid4', return_value=UID):
            with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, RuntimeError('create timeout'),
                                                               RuntimeError('inventory timeout')]):
                with patch.object(ci_simulator, 'remove_simulators') as remove:
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, 'create timeout'):
                        ci_simulator.create(RUNTIME, self.record)
        remove.assert_not_called()
        self.assertEqual(self.record.read_text(), 'name:' + NAME + '\n')

    def test_cleanup_pending_name_recovers_exact_uuid(self):
        self.record.write_text('name:' + NAME + '\n')
        devices = json.dumps({'devices': {RUNTIME: [dict(name=NAME, udid=UID)]}})
        with patch.object(ci_simulator, 'run', return_value=devices) as transport:
            with patch.object(ci_simulator, 'remove_simulators') as remove:
                ci_simulator.cleanup(self.record)
        transport.assert_called_once_with('xcrun', 'simctl', 'list', 'devices', '-j', timeout=60)
        remove.assert_called_once_with([UID])
        self.assertFalse(self.record.exists())

    def test_cleanup_pending_name_refuses_absent_duplicate_and_invalid_uuid(self):
        for devices in ([], [dict(name=NAME, udid=UID)] * 2, [dict(name=NAME, udid='booted')]):
            with self.subTest(devices=devices):
                self.record.write_text('name:' + NAME + '\n')
                with patch.object(ci_simulator, 'run', return_value=json.dumps({'devices': {RUNTIME: devices}})):
                    with patch.object(ci_simulator, 'remove_simulators') as remove:
                        with self.assertRaises((ValueError, RuntimeError)):
                            ci_simulator.cleanup(self.record)
                remove.assert_not_called()
                self.assertEqual(self.record.read_text(), 'name:' + NAME + '\n')

    def test_cleanup_rejects_unowned_name_before_inventory(self):
        for name in ('M4 CI booted', 'M4 CI ' + UID[:8], 'unrelated ' + UID, NAME + '-suffix'):
            with self.subTest(name=name):
                self.record.write_text('name:' + name + '\n')
                with patch.object(ci_simulator, 'run') as transport:
                    with self.assertRaises(ValueError):
                        ci_simulator.cleanup(self.record)
                transport.assert_not_called()

    def test_env_failure_survives_a_secondary_record_close_failure(self):
        fdopen = ci_simulator.os.fdopen
        class FailingClose:
            def __init__(self, *args):
                self.file = fdopen(*args)
            def __getattr__(self, name):
                return getattr(self.file, name)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.close()
            def close(self):
                self.file.close()
                raise OSError('secondary close error')
        with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, UID]):
            with patch.object(ci_simulator.os, 'fdopen', side_effect=FailingClose):
                with patch.object(ci_simulator, 'remove_simulators') as remove:
                    with self.assertRaises(FileNotFoundError):
                        ci_simulator.create(RUNTIME, self.record, Path(self.work.name) / 'missing' / 'env')
        remove.assert_called_once_with([UID])

    def test_cli_creates_then_cleans_the_same_owned_simulator(self):
        argv = ['ci_simulator.py', 'create', '--runtime', RUNTIME, '--id-file', str(self.record)]
        with patch.object(ci_simulator.sys, 'argv', argv):
            with patch.object(ci_simulator, 'run', side_effect=[RUNTIMES, UID]):
                ci_simulator.main()
        argv = ['ci_simulator.py', 'cleanup', '--id-file', str(self.record)]
        with patch.object(ci_simulator.sys, 'argv', argv):
            with patch.object(ci_simulator, 'remove_simulators') as remove:
                ci_simulator.main()
        remove.assert_called_once_with([UID])
        self.assertFalse(self.record.exists())

    def test_exact_unavailable_runtime_refuses_to_create(self):
        with patch.object(ci_simulator, 'run', return_value=RUNTIMES) as transport:
            with self.assertRaisesRegex(RuntimeError, 'No available iOS'):
                ci_simulator.create('com.apple.CoreSimulator.SimRuntime.iOS-26-0', self.record)
        self.assertEqual(transport.call_count, 1)
        self.assertFalse(self.record.exists())

    def test_empty_runtime_never_selects_latest(self):
        with patch.object(ci_simulator, 'run') as transport:
            with self.assertRaises(ValueError):
                ci_simulator.create('', self.record)
        transport.assert_not_called()

    def test_existing_record_is_never_overwritten(self):
        self.record.write_text('existing owner\n')
        with patch.object(ci_simulator, 'run') as transport:
            with self.assertRaises(FileExistsError):
                ci_simulator.create(RUNTIME, self.record)
        transport.assert_not_called()
        self.assertEqual(self.record.read_text(), 'existing owner\n')

    def test_cleanup_missing_record_does_nothing(self):
        with patch.object(ci_simulator, 'remove_simulators') as remove:
            ci_simulator.cleanup(self.record)
        remove.assert_not_called()

    def test_cleanup_refuses_selectors_and_malformed_ids(self):
        for invalid in ('booted', 'all', '', UID + '\n' + UID, '1234'):
            with self.subTest(invalid=invalid):
                self.record.write_text(invalid)
                with patch.object(ci_simulator, 'remove_simulators') as remove:
                    with self.assertRaises(ValueError):
                        ci_simulator.cleanup(self.record)
                remove.assert_not_called()
                self.assertTrue(self.record.exists())

    def test_cleanup_removes_only_recorded_uuid_then_deletes_record(self):
        self.record.write_text(UID + '\n')
        with patch.object(ci_simulator, 'remove_simulators') as remove:
            ci_simulator.cleanup(self.record)
        remove.assert_called_once_with([UID])
        self.assertFalse(self.record.exists())

    def test_failed_cleanup_retains_record_for_retry(self):
        self.record.write_text(UID + '\n')
        with patch.object(ci_simulator, 'remove_simulators', side_effect=RuntimeError('delete failed')):
            with self.assertRaisesRegex(RuntimeError, 'delete failed'):
                ci_simulator.cleanup(self.record)
        self.assertEqual(self.record.read_text(), UID + '\n')


if __name__ == '__main__':
    unittest.main()
