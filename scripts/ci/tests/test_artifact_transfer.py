import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artifact_transfer_status as transfer


class ArtifactTransferTests(unittest.TestCase):
    def run_status(self, first, retry):
        with tempfile.TemporaryDirectory() as root:
            summary = Path(root) / 'summary'
            with patch.dict(os.environ, {'TRANSFER_FIRST': first, 'TRANSFER_RETRY': retry,
                                        'GITHUB_STEP_SUMMARY': str(summary)}), contextlib.redirect_stdout(io.StringIO()):
                status = transfer.main()
            return status, summary.read_text()

    def test_first_success_requires_no_retry(self):
        status, summary = self.run_status('success', 'skipped')
        self.assertEqual(status, 0)
        self.assertNotIn('retry succeeded', summary)
        self.assertNotIn('infra:', summary)

    def test_recovered_transport_is_visible_without_a_product_failure(self):
        status, summary = self.run_status('failure', 'success')
        self.assertEqual(status, 0)
        self.assertIn('infra:artifact-upload', summary)
        self.assertIn('retry succeeded', summary)
        self.assertNotIn('product:', summary)

    def test_failed_missing_cancelled_or_invalid_retry_never_passes(self):
        for first, retry in [('failure', 'failure'), ('failure', 'skipped'),
                             ('failure', 'cancelled'), ('cancelled', 'skipped'),
                             ('skipped', 'skipped'), ('success', 'failure'), ('', '')]:
            with self.subTest(first=first, retry=retry):
                status, summary = self.run_status(first, retry)
                self.assertEqual(status, 1)
                self.assertIn('infra:artifact-upload', summary)


if __name__ == '__main__':
    unittest.main()
