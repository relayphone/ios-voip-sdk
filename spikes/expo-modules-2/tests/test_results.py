import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'results', Path(__file__).parents[1] / 'scripts' / 'check-results.py')
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


class ResultsContract(unittest.TestCase):
    def entry(self, **changes):
        return dict({'id': 'snapshot', 'pass': True, 'values': {}, 'threads': []}, **changes)

    def check(self, entries, required={'snapshot'}, timeout=0):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'expo2-results.json'
            if entries is not None:
                path.write_text(json.dumps(entries))
            return results.read_results(path, required, timeout)

    def test_accepts_complete_success(self):
        self.assertEqual(self.check([self.entry()])[0]['id'], 'snapshot')

    def test_rejects_native_failure(self):
        item = self.entry()
        item['pass'] = False
        with self.assertRaises(ValueError):
            self.check([item])

    def test_rejects_missing_file_at_deadline(self):
        with self.assertRaises(TimeoutError):
            self.check(None)

    def test_rejects_missing_duplicate_or_unexpected_ids(self):
        for entries in [[], [self.entry(), self.entry()], [self.entry(id='wrong')]]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.check(entries)

    def test_rejects_non_boolean_pass_or_missing_evidence(self):
        for key, value in [('pass', 1), ('values', []), ('threads', {})]:
            item = self.entry()
            item[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check([item])


if __name__ == '__main__':
    unittest.main()
