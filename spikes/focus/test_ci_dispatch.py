"""The optional Actions summary must not start a device session."""

import contextlib
import io
import unittest
from unittest.mock import patch

import ci_summary
import morning_batch as batch


class CIDispatchTests(unittest.TestCase):
    def test_summary_dispatch_never_enters_device_work(self):
        with patch.object(ci_summary, "main", return_value=0) as summary, \
             patch.object(batch, "make_plan", side_effect=AssertionError("unexpected plan")), \
             patch.object(batch, "run_batch", side_effect=AssertionError("unexpected device work")), \
             patch.object(batch, "archive_legacy", side_effect=AssertionError("unexpected archive")):
            self.assertEqual(batch.main(["--ci-summary", "123", "--repo", "owner/project"]), 0)
        summary.assert_called_once_with(["123", "--repo", "owner/project"])

    def test_invalid_combinations_stop_before_work(self):
        args = [
            ["--ci-summary", "123"],
            ["--repo", "owner/project"],
            ["--ci-summary", "123", "--repo", "owner/project", "--quiet"],
            ["--ci-summary", "123", "--repo", "owner/project", "--dry-run"],
            ["--ci-summary", "123", "--repo", "owner/project", "--archive-legacy"],
            ["--ci-summary", "123", "--repo", "owner/project", "--unknown-caller", "+15555550199"],
        ]
        with patch.object(ci_summary, "main", side_effect=AssertionError("unexpected query")), \
             patch.object(batch, "make_plan", side_effect=AssertionError("unexpected plan")), \
             patch.object(batch, "run_batch", side_effect=AssertionError("unexpected device work")), \
             patch.object(batch, "archive_legacy", side_effect=AssertionError("unexpected archive")), \
             contextlib.redirect_stderr(io.StringIO()):
            for value in args:
                with self.subTest(value=value), self.assertRaises(SystemExit) as raised:
                    batch.main(value)
                self.assertEqual(raised.exception.code, 2)

    def test_summary_return_code_is_preserved(self):
        with patch.object(ci_summary, "main", return_value=2):
            self.assertEqual(batch.main(["--ci-summary", "123", "--repo", "owner/project"]), 2)


if __name__ == "__main__":
    unittest.main()
