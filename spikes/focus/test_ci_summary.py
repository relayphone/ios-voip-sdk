"""Read-only Actions summary behavior."""

import contextlib
import io
import json
import subprocess
import unittest
from unittest.mock import patch

from ci_summary import billing_rejection, main, summarize


class CISummaryTests(unittest.TestCase):
    def test_billing_requires_an_actual_annotation(self):
        self.assertTrue(billing_rejection({"message": "The job was not started because your workspace is locked due to a billing issue."}))
        self.assertFalse(billing_rejection({"message": "The job was not started because your workspace is locked due to a billing issue. This is unrelated."}))
        self.assertFalse(billing_rejection({"message": "The job was not started; the workspace is not locked due to a billing issue."}))
        self.assertFalse(billing_rejection({"message": "A billing issue appeared after the job started."}))
        self.assertFalse(billing_rejection({"message": "The job was not started because the runner was unavailable."}))
        self.assertFalse(billing_rejection({"message": ["billing issue"]}))

    def test_counts_failed_jobs_and_incomplete_jobs_without_remote_text(self):
        def fetch(path):
            if "/actions/runs/" in path:
                return [{"jobs": [{"id": 1, "status": "completed", "conclusion": "failure"},
                                   {"id": 2, "status": "completed", "conclusion": "failure"},
                                   {"id": 3, "status": "in_progress", "conclusion": None}]}]
            if "/1/" in path:
                return [[{"message": "The job was not started because your workspace is locked due to a billing issue."}]]
            return [[{"message": "private details"}]]
        self.assertEqual(summarize("owner/project", "12", fetch),
                         {"jobsObserved": 3, "failedJobs": 2, "billingBlocked": 1, "otherFailures": 1,
                          "annotationsUnavailable": 0, "incompleteJobs": 1})

    def test_unavailable_annotations_are_not_misclassified(self):
        def fetch(path):
            if "/actions/runs/" in path:
                return [{"jobs": [{"id": 1, "status": "completed", "conclusion": "failure"}]}]
            raise subprocess.TimeoutExpired("gh", 30)
        self.assertEqual(summarize("owner/project", "12", fetch)["annotationsUnavailable"], 1)
        self.assertEqual(summarize("owner/project", "12", fetch)["billingBlocked"], 0)

    def test_malformed_annotations_are_unavailable(self):
        for pages in ([], [None], [[None]], [[{}]], [[{"message": None}]], [[{"message": ["private"]}]]):
            def fetch(path):
                if "/actions/runs/" in path:
                    return [{"jobs": [{"id": 1, "status": "completed", "conclusion": "failure"}]}]
                return pages
            result = summarize("owner/project", "12", fetch)
            self.assertEqual(result["annotationsUnavailable"], 1)
            self.assertEqual(result["otherFailures"], 0)
            self.assertEqual(result["billingBlocked"], 0)

    def test_jobs_pages_must_be_present(self):
        with self.assertRaises(ValueError):
            summarize("owner/project", "12", lambda _: [])
        result = summarize("owner/project", "12", lambda _: [{"jobs": []}])
        self.assertEqual(result["jobsObserved"], 0)
        self.assertEqual(result["failedJobs"], 0)
        self.assertEqual(result["incompleteJobs"], 0)

    def test_empty_annotation_page_is_valid(self):
        def fetch(path):
            return [{"jobs": [{"id": 1, "status": "completed", "conclusion": "failure"}]}] if "/actions/runs/" in path else [[]]
        self.assertEqual(summarize("owner/project", "12", fetch)["otherFailures"], 1)

    def test_paginated_annotations_and_failure_kinds(self):
        def fetch(path):
            if "/actions/runs/" in path:
                return [{"jobs": [{"id": 1, "status": "completed", "conclusion": "action_required"},
                                   {"id": 2, "status": "completed", "conclusion": "timed_out"}]}]
            if "/1/" in path:
                return [[], [{"message": "The job was not started because your workspace is locked due to a billing issue."}]]
            return [[]]
        result = summarize("owner/project", "12", fetch)
        self.assertEqual(result["billingBlocked"], 1)
        self.assertEqual(result["otherFailures"], 1)

    def test_cli_does_not_print_remote_text_or_errors(self):
        def run(argv, **kwargs):
            if "/actions/runs/" in argv[-1]:
                payload = [{"jobs": [{"id": 1, "status": "completed", "conclusion": "failure"}]}]
                return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(payload), stderr="private stderr")
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps([[{"message": "private annotation"}]]), stderr="private stderr")
        out, err = io.StringIO(), io.StringIO()
        with patch("ci_summary.subprocess.run", side_effect=run), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(main(["12", "--repo", "owner/project"]), 0)
        self.assertEqual(json.loads(out.getvalue())["otherFailures"], 1)
        self.assertNotIn("private", out.getvalue() + err.getvalue())

        out, err = io.StringIO(), io.StringIO()
        failure = subprocess.CalledProcessError(1, "gh", output="private stdout", stderr="private stderr")
        with patch("ci_summary.subprocess.run", side_effect=failure), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(main(["12", "--repo", "owner/project"]), 2)
        self.assertNotIn("private", out.getvalue() + err.getvalue())

    def test_decode_errors_are_sanitized_in_jobs_and_annotations(self):
        def decode_failure():
            return UnicodeDecodeError("utf-8", b"\xffprivate", 0, 1, "private detail")

        out, err = io.StringIO(), io.StringIO()
        with patch("ci_summary.subprocess.run", side_effect=decode_failure()), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(main(["12", "--repo", "owner/project"]), 2)
        self.assertNotIn("private", out.getvalue() + err.getvalue())
        self.assertNotIn("Traceback", out.getvalue() + err.getvalue())

        def run(argv, **kwargs):
            if "/actions/runs/" in argv[-1]:
                payload = [{"jobs": [{"id": 1, "status": "completed", "conclusion": "failure"}]}]
                return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(payload), stderr="")
            raise decode_failure()

        out, err = io.StringIO(), io.StringIO()
        with patch("ci_summary.subprocess.run", side_effect=run), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(main(["12", "--repo", "owner/project"]), 2)
        self.assertEqual(json.loads(out.getvalue())["annotationsUnavailable"], 1)
        self.assertNotIn("private", out.getvalue() + err.getvalue())
        self.assertNotIn("Traceback", out.getvalue() + err.getvalue())

    def test_rejects_invalid_identifiers_before_calling_gh(self):
        for repo, run in [("owner/other/extra", "1"), ("../..", "1"), ("owner/project", "1;bad"), ("owner/project", "0")]:
            with self.assertRaises(ValueError):
                summarize(repo, run, lambda _: self.fail("unexpected request"))


if __name__ == "__main__":
    unittest.main()
