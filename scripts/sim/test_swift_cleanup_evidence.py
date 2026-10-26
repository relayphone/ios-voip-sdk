#!/usr/bin/env python3
"""Cleanup evidence failures never prevent owned native teardown (host only)."""
from contextlib import contextmanager
import io
from pathlib import Path
import re
import signal
import subprocess
import unittest
from unittest.mock import patch

import test_swift_livekit_setup as setup
from summarize import EvidenceError


class SwiftCleanupEvidenceTests(unittest.TestCase):
    setUp = setup.SwiftLiveKitSetupTests.setUp
    capture = setup.SwiftLiveKitSetupTests.capture

    def fresh_output(self, name):
        self.out = self.root / name
        self.case_calls.clear()
        (self.root / 'job-summary.md').unlink(missing_ok=True)

    @contextmanager
    def evidence_failure(self, relative, error):
        target = self.out / relative
        opened = Path.open

        def open_path(path, mode='r', *arguments, **options):
            if path == target and any(flag in mode for flag in 'wax+'):
                raise error
            return opened(path, mode, *arguments, **options)

        with patch.object(Path, 'open', open_path):
            yield

    def labels(self):
        summary = self.root / 'job-summary.md'
        return re.findall(r'`((?:infra|product):[^`]+)`', summary.read_text()) if summary.exists() else []

    def assert_deleted(self, native, *, final_teardown=True):
        self.assertEqual(native.devices, {}, 'evidence I/O must not skip native deletion')
        self.assertEqual([call['arguments'][2] for call in native.calls[-3:]],
                         ['shutdown', 'delete', 'list'])
        for call in native.calls:
            if call['arguments'][2] in ('shutdown', 'delete', 'list'):
                self.assertEqual(call['timeout'], 60, call)
        final_calls = native.calls[-3:] if final_teardown else native.calls[-1:]
        for call in final_calls:
            self.assertTrue(all(handler == signal.SIG_IGN for handler in call['handlers'].values()))

    def assert_failed_evidence(self):
        self.assertIn('infra:evidence-write', self.labels())
        self.assertTrue(Path(str(self.out) + '.failure-classified').exists())
        self.assertFalse((self.out / 'manifest.json').exists())
        self.assertFalse((self.out / 'summary.json').exists())

    def test_shutdown_stdout_write_failure_still_deletes_and_checks_final_inventory(self):
        original = OSError('private shutdown evidence path')
        native = setup.NativeService()
        with self.evidence_failure('shutdown.stdout', original):
            self.assertIs(self.capture(native, override=''), original)
        self.assert_deleted(native)
        self.assert_failed_evidence()

    def test_cleanup_artifact_write_failures_cannot_skip_teardown_or_qualify(self):
        artifacts = ('shutdown.stderr', 'shutdown.status.json', 'delete.stdout',
                     'delete.stderr', 'delete.status.json', 'simulator-state/cleanup.log',
                     'simulator-state/cleanup.json', 'cleanup.json', 'devices-after.stdout',
                     'devices-after.stderr', 'devices-after.status.json', 'devices-after.json')
        for index, artifact in enumerate(artifacts):
            with self.subTest(artifact=artifact):
                self.fresh_output('write-' + str(index))
                original = OSError('private artifact path: ' + artifact)
                native = setup.NativeService()
                with self.evidence_failure(artifact, original):
                    self.assertIs(self.capture(native, override=''), original)
                self.assert_deleted(native)
                self.assertEqual(native.counts['shutdown'], 1)
                self.assertEqual(native.counts['delete'], 1)
                self.assertEqual(self.labels(), ['infra:evidence-write'])
                self.assert_failed_evidence()

    def test_product_and_cancellation_objects_survive_independent_cleanup_evidence_failures(self):
        for kind, original in (('product', RuntimeError('original product assertion')),
                               ('term', SystemExit(143)), ('int', KeyboardInterrupt())):
            for index, artifact in enumerate(('shutdown.stdout', 'simulator-state/cleanup.log',
                                               'simulator-state/cleanup.json', 'cleanup.json',
                                               'devices-after.json')):
                with self.subTest(primary=kind, artifact=artifact):
                    self.fresh_output(kind + '-' + str(index))
                    evidence = OSError('independent private evidence path')
                    native = setup.NativeService()
                    with self.evidence_failure(artifact, evidence):
                        self.assertIs(self.capture(native, override='', case_failure=original), original)
                    self.assert_deleted(native)
                    label = 'product:swift-livekit-healthy' if kind == 'product' else 'infra:runner-cancelled'
                    self.assertEqual(self.labels(), [label, 'infra:evidence-write'])
                    self.assertEqual(len(self.case_calls), 1)
                    self.assert_failed_evidence()

    def test_aggregate_log_failure_does_not_abandon_later_owned_or_uncertain_devices(self):
        original = OSError('private aggregate cleanup log')
        native = setup.NativeService([
            dict(step='create', timeout=True),
            # A timed-out creation may appear after the first recovery inventory.
            dict(step='list', at=[2], stdout=b'{"devices": {}}')])
        with self.evidence_failure('simulator-state/cleanup.log', original):
            self.assertIs(self.capture(native, override=''), original)
        self.assertEqual(len(native.created), 2)
        self.assertEqual(native.counts['shutdown'], 2)
        self.assertEqual(native.counts['delete'], 2)
        self.assert_deleted(native)
        inventories = [call for call in native.calls if call['arguments'][2:4] == ['list', 'devices']]
        self.assertEqual(len(inventories), 3, 'initial recovery, late name recovery, and final absence must all run')
        self.assert_failed_evidence()

    def test_replacement_cleanup_evidence_failure_stops_replay_after_native_teardown(self):
        for index, artifact in enumerate(('shutdown.stdout', 'delete.stdout',
                                          'simulator-state/cleanup.log', 'simulator-state/cleanup.json')):
            with self.subTest(artifact=artifact):
                self.fresh_output('replacement-' + str(index))
                original = OSError('private replacement evidence path')
                native = setup.NativeService([dict(step='install', code=73)])
                with self.evidence_failure(artifact, original):
                    self.assertIs(self.capture(native, override=''), original)
                self.assert_deleted(native, final_teardown=False)
                self.assertEqual(len(native.created), 1)
                self.assertEqual(native.counts['install'], 1)
                self.assertFalse(self.case_calls, 'failed cleanup evidence must not allow a setup replay')
                self.assert_failed_evidence()

    def test_recovery_inventory_evidence_failure_does_not_lose_the_native_owned_identity(self):
        for suffix in ('.stdout', '.stderr', '.status.json'):
            with self.subTest(suffix=suffix):
                self.fresh_output('recovery' + suffix)
                original = OSError('private recovery inventory evidence path')
                native = setup.NativeService([dict(step='create', timeout=True)])
                with self.evidence_failure('creation-recovery' + suffix, original):
                    self.assertIs(self.capture(native, override=''), original)
                self.assert_deleted(native, final_teardown=False)
                self.assertEqual(len(native.created), 1)
                self.assertFalse(self.case_calls)
                inventories = [call for call in native.calls if call['arguments'][2:4] == ['list', 'devices']]
                self.assertGreaterEqual(len(inventories), 2, 'recovery and final absence inventory must run')
                self.assert_failed_evidence()

    def test_marker_write_failure_and_closed_stderr_preserve_product_error_and_native_cleanup(self):
        original = RuntimeError('original product assertion before marker failure')
        native = setup.NativeService()
        marker = Path(str(self.out) + '.failure-classified')
        touch = Path.touch
        stderr = io.StringIO(); stderr.close()

        def touch_path(path, *arguments, **options):
            if path == marker:
                raise OSError('private marker evidence path')
            return touch(path, *arguments, **options)

        with patch.object(Path, 'touch', touch_path), patch.object(setup.runner.sys, 'stderr', stderr):
            self.assertIs(self.capture(native, override='', case_failure=original), original)
        self.assert_deleted(native)
        self.assertIn('product:swift-livekit-healthy', self.labels())
        self.assertIn('infra:evidence-write', self.labels())
        self.assertFalse((self.out / 'manifest.json').exists())
        self.assertFalse((self.out / 'summary.json').exists())

    def test_cross_layer_cleanup_failures_preserve_first_occurrence_and_existing_product_error(self):
        for first_layer in ('core', 'adapter'):
            for primary in (None, RuntimeError('original product failure before cleanup')):
                with self.subTest(first_layer=first_layer, product_primary=primary is not None):
                    self.fresh_output(first_layer + ('-product' if primary else '-cleanup'))
                    core = OSError('first device core cleanup log')
                    adapter = OSError('adapter delete stdout')
                    native = setup.NativeService([
                        dict(step='create', timeout=True),
                        dict(step='list', at=[2], stdout=b'{"devices": {}}')])
                    opened, observed = Path.open, []

                    def open_path(path, mode='r', *arguments, **options):
                        if any(flag in mode for flag in 'wax+'):
                            if (path == self.out / 'simulator-state/cleanup.log'
                                    and native.counts['delete'] == 1 and core not in observed):
                                observed.append(core)
                                raise core
                            adapter_delete = 2 if first_layer == 'core' else 1
                            if (path == self.out / 'delete.stdout'
                                    and native.counts['delete'] == adapter_delete and adapter not in observed):
                                observed.append(adapter)
                                raise adapter
                        return opened(path, mode, *arguments, **options)

                    with patch.object(Path, 'open', open_path):
                        caught = self.capture(native, override='', case_failure=primary or False)
                    self.assert_deleted(native)
                    self.assertEqual(len(native.created), 2)
                    self.assertEqual(native.counts['shutdown'], 2)
                    self.assertEqual(native.counts['delete'], 2)
                    expected_order = [core, adapter] if first_layer == 'core' else [adapter, core]
                    self.assertEqual(observed, expected_order, 'faults must actually occur in the requested order')
                    self.assertIs(caught, primary if primary is not None else expected_order[0])
                    if primary is not None:
                        self.assertIn('product:swift-livekit-healthy', self.labels())
                    self.assert_failed_evidence()

    def test_post_delete_native_timeout_precedes_its_evidence_write_failure(self):
        original = subprocess.TimeoutExpired(['xcrun', 'simctl', 'list', 'devices', '-j'], 60,
                                            output=b'partial inventory', stderr=b'native timeout')

        class TimedOutInventory(setup.NativeService):
            def __call__(self, arguments, timeout, *, env=None):
                result = super().__call__(arguments, timeout, env=env)
                if list(arguments)[2:4] == ['list', 'devices']:
                    raise original
                return result

        native = TimedOutInventory()
        evidence = OSError('later devices-after stdout write')
        with self.evidence_failure('devices-after.stdout', evidence):
            caught = self.capture(native, override='')
        self.assert_deleted(native)
        self.assertIs(caught, original)
        self.assertIn('infra:post-delete-inventory', self.labels())
        self.assert_failed_evidence()

    def test_post_delete_failed_status_precedes_its_evidence_write_failure(self):
        native = setup.NativeService([dict(step='list', at=[2], code=73)])
        evidence = OSError('later failed inventory stdout write')
        require, factory_errors = setup.runner.require, []

        def require_unchanged(condition, message):
            try:
                return require(condition, message)
            except EvidenceError as error:
                if message == 'devices-after failed: 73':
                    factory_errors.append(error)
                raise

        with self.evidence_failure('devices-after.stdout', evidence), \
             patch.object(setup.runner, 'require', side_effect=require_unchanged):
            caught = self.capture(native, override='')
        self.assert_deleted(native)
        self.assertEqual(len(factory_errors), 1)
        self.assertEqual(str(factory_errors[0]), 'devices-after failed: 73')
        self.assertIs(caught, factory_errors[0])
        self.assertIn('infra:post-delete-inventory', self.labels())
        self.assert_failed_evidence()

    def test_terminal_privacy_fault_keeps_identity_and_precedes_cleanup_evidence_failure(self):
        native = setup.NativeService([dict(step='privacy', at=[1, 2], timeout=True)])
        evidence = OSError('later final inventory evidence write')
        require, primary_errors = setup.runner.require, []

        def require_unchanged(condition, message):
            try:
                return require(condition, message)
            except EvidenceError as error:
                if message == 'privacy failed: 124':
                    primary_errors.append(error)
                raise

        with self.evidence_failure('devices-after.stdout', evidence), \
             patch.object(setup.runner, 'require', side_effect=require_unchanged):
            caught = self.capture(native, override='')
        self.assert_deleted(native)
        self.assertEqual(len(primary_errors), 1)
        self.assertIs(caught, primary_errors[0])
        self.assertIsNot(caught, evidence)
        self.assertEqual(self.labels(), ['infra:privacy', 'infra:privacy', 'infra:evidence-write'])
        self.assertEqual(len(native.created), 2)
        self.assertEqual(native.counts['privacy'], 2)
        self.assertEqual(native.counts['shutdown'], 2)
        self.assertEqual(native.counts['delete'], 2)
        self.assertFalse(self.case_calls)
        self.assert_failed_evidence()

    def test_shutdown_timeout_stays_tolerated_while_its_evidence_failure_is_fatal(self):
        native = setup.NativeService([dict(step='shutdown', timeout=True,
                                          stdout=b'partial stop', stderr=b'native timeout')])
        original = OSError('shutdown timeout evidence write')
        with self.evidence_failure('shutdown.stdout', original):
            caught = self.capture(native, override='')
        self.assert_deleted(native)
        self.assertIs(caught, original)
        self.assertIn('infra:shutdown', self.labels())
        self.assert_failed_evidence()

    def test_teardown_archive_failure_still_runs_shutdown_delete_and_inventory(self):
        for operation in ('shutdown', 'delete'):
            for action in ('mkdir', 'rename'):
                with self.subTest(operation=operation, action=action):
                    self.fresh_output(operation + '-' + action)
                    original = OSError('private cleanup archive path')
                    native = setup.NativeService([dict(step='install', code=73)])
                    mkdir, rename = Path.mkdir, Path.rename
                    failures = []

                    def make_directory(path, *arguments, **options):
                        if (action == 'mkdir' and path.parent == self.out / 'infrastructure-attempts'
                                and path.name.endswith('-' + operation)):
                            failures.append(path)
                            raise original
                        return mkdir(path, *arguments, **options)

                    def rename_path(path, *arguments, **options):
                        if action == 'rename' and path == self.out / (operation + '.stdout'):
                            failures.append(path)
                            raise original
                        return rename(path, *arguments, **options)

                    with patch.object(Path, 'mkdir', make_directory), patch.object(Path, 'rename', rename_path):
                        self.assertIs(self.capture(native, override=''), original)
                    self.assertTrue(failures, 'the canonical teardown archive must exercise the fault')
                    self.assert_deleted(native)
                    self.assertEqual(len(native.created), 2)
                    self.assertEqual(native.counts['shutdown'], 2)
                    self.assertEqual(native.counts['delete'], 2)
                    self.assert_failed_evidence()


if __name__ == '__main__':
    unittest.main()
