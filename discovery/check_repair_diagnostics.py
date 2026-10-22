#!/usr/bin/env python3
"""Offline controls for repair evidence; inherited injector paths stay private."""
import hashlib
import json
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest

import run_repair


class RepairDiagnosticsChecks(unittest.TestCase):
    def test_cli_journey_rejects_success_status_environment_read_diagnostics(self):
        # The journey has launch side effects at module scope. Compile its real
        # public reader alone and replace only the external process boundary.
        path = Path(__file__).with_name('cli_conformance.py')
        tree = ast.parse(path.read_text())
        reader = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'managed_environment')
        for status, stderr in [(0, ''), (0, 'launchctl read diagnostic\n'), (7, '')]:
            with self.subTest(status=status, stderr=stderr):
                process = SimpleNamespace(run=lambda *args, **kwargs: SimpleNamespace(returncode=status, stdout='', stderr=stderr))
                namespace = dict(subprocess=process, os=SimpleNamespace(environ={}), device='owned-fixture')
                exec(compile(ast.Module(body=[reader], type_ignores=[]), str(path), 'exec'), namespace)
                if status or stderr:
                    with self.assertRaisesRegex(AssertionError, 'cannot inspect managed environment'):
                        namespace['managed_environment']()
                else:
                    self.assertEqual(set(namespace['managed_environment']()), set(run_repair.KEYS))

    def test_missing_loader_is_identifiable_without_inherited_paths(self):
        inherited = '/private/customer-sensitive/Argent.dylib'
        before, loader = '/fixture/before.dylib', '/fixture/CKSimLoader.dylib'
        expected = {key: None for key in run_repair.KEYS}
        expected['DYLD_INSERT_LIBRARIES'] = ':'.join([inherited, before, loader])
        actual = dict(expected, DYLD_INSERT_LIBRARIES=':'.join([inherited, before]))
        evidence = run_repair.environment_diagnostic(actual, expected, {'before': before, 'loader': loader})
        self.assertNotIn(inherited, json.dumps(evidence))
        self.assertFalse(evidence['matchingKeys']['DYLD_INSERT_LIBRARIES'])
        self.assertTrue(evidence['matchingKeys']['CKSIM_PROFILE'])
        self.assertEqual(evidence['actualSHA256']['DYLD_INSERT_LIBRARIES'],
                         hashlib.sha256(actual['DYLD_INSERT_LIBRARIES'].encode()).hexdigest())
        self.assertEqual(evidence['expectedSHA256']['DYLD_INSERT_LIBRARIES'],
                         hashlib.sha256(expected['DYLD_INSERT_LIBRARIES'].encode()).hexdigest())
        self.assertEqual([row['role'] for row in evidence['dyld']['actualEntries']], ['inherited', 'before'])
        self.assertEqual([row['role'] for row in evidence['dyld']['expectedEntries']], ['inherited', 'before', 'loader'])
        self.assertFalse(evidence['dyld']['sameEntryInventory'])

    def test_exact_value_order_duplicates_and_transport_differences_remain_visible(self):
        before, loader = '/fixture/before.dylib', '/fixture/CKSimLoader.dylib'
        original = '/private/customer-sensitive/Argent.dylib'
        expected = {key: None for key in run_repair.KEYS}
        expected['DYLD_INSERT_LIBRARIES'] = ':'.join([original, before, loader])
        fixtures = dict(before=before, loader=loader)
        cases = [
            ('same', expected['DYLD_INSERT_LIBRARIES'], True, True),
            ('reordered', ':'.join([before, original, loader]), False, True),
            ('duplicate', expected['DYLD_INSERT_LIBRARIES']+':'+loader, False, False),
            ('newline', expected['DYLD_INSERT_LIBRARIES']+'\n', False, False),
            ('empty-component', expected['DYLD_INSERT_LIBRARIES']+':', False, False),
            ('path-alias', expected['DYLD_INSERT_LIBRARIES'].replace('/fixture/', '/fixture/./'), False, False),
        ]
        for name, value, ordered, inventory in cases:
            with self.subTest(name=name):
                evidence = run_repair.environment_diagnostic(dict(expected, DYLD_INSERT_LIBRARIES=value), expected, fixtures)
                self.assertEqual(evidence['dyld']['sameEntryOrder'], ordered)
                self.assertEqual(evidence['dyld']['sameEntryInventory'], inventory)
                self.assertEqual(evidence['matchingKeys']['DYLD_INSERT_LIBRARIES'], ordered)
                self.assertNotIn(original, json.dumps(evidence))
        reordered = run_repair.environment_diagnostic(
            dict(expected, DYLD_INSERT_LIBRARIES=':'.join([before, original, loader])), expected, fixtures)
        self.assertEqual([row['expectedIndices'] for row in reordered['dyld']['actualEntries']], [[1], [0], [2]])

    def test_absent_and_empty_values_are_distinct(self):
        expected = {key: None for key in run_repair.KEYS}
        actual = dict(expected, DYLD_INSERT_LIBRARIES='', CKSIM_ENABLED='')
        evidence = run_repair.environment_diagnostic(actual, expected, {})
        self.assertIsNone(evidence['expectedSHA256']['DYLD_INSERT_LIBRARIES'])
        self.assertEqual(evidence['actualSHA256']['DYLD_INSERT_LIBRARIES'], hashlib.sha256(b'').hexdigest())
        self.assertFalse(evidence['dyld']['sameEntryOrder'])
        self.assertFalse(evidence['dyld']['sameEntryInventory'])
        self.assertFalse(evidence['matchingKeys']['CKSIM_ENABLED'])


if __name__ == '__main__':
    unittest.main()
