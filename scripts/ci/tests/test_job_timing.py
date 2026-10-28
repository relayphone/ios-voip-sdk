import sys
from datetime import datetime, timezone
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from job_timing import render


class JobTimingTests(unittest.TestCase):
    def test_reports_queue_proxy_and_execution_for_completed_job(self):
        data = [{'jobs': [{'name': 'SDK | example', 'status': 'completed', 'conclusion': 'success',
            'created_at': '2026-10-26T22:42:01Z', 'started_at': '2026-10-26T22:47:16Z',
            'completed_at': '2026-10-26T22:53:10Z'}]}]
        report = render(data)
        self.assertIn('SDK \\| example', report)
        self.assertIn('5m 15s', report)
        self.assertIn('5m 54s', report)
        self.assertIn('queue proxy', report)
        self.assertIn('current attempt', report)

    def test_incomplete_skipped_and_bad_timestamps_are_unknown(self):
        data = [{'jobs': [
            {'name': '<running>', 'status': 'in_progress', 'created_at': 'bad'},
            {'name': 'queued', 'status': 'queued', 'created_at': '2026-10-26T22:42:01Z',
             'started_at': '2026-10-26T22:42:01Z'},
            {'name': 'skipped', 'status': 'completed', 'conclusion': 'skipped',
             'created_at': '2026-10-26T22:42:01Z', 'started_at': '2026-10-26T22:42:01Z'},
            {'name': 'reverse', 'status': 'completed', 'created_at': '2026-10-26T22:44:01Z',
             'started_at': '2026-10-26T22:42:01Z', 'completed_at': '2026-10-26T22:43:01Z'}]}]
        report = render(data)
        self.assertNotIn('&lt;running&gt;', report)
        self.assertNotIn('| queued |', report)
        self.assertGreaterEqual(report.count('—'), 3)
        self.assertNotIn('-120', report)

    def test_rerun_clone_does_not_attribute_earlier_execution_to_this_attempt(self):
        data = [{'jobs': [{'name': 'retained', 'status': 'completed', 'conclusion': 'success',
            'created_at': '2026-10-26T17:35:03Z', 'started_at': '2026-10-26T16:42:47Z',
            'completed_at': '2026-10-26T16:52:44Z'}]}]
        report = render(data)
        self.assertIn('| retained | carried forward | — | — |', report)
        self.assertNotIn('9m 57s', report)

    def test_workflow_elapsed_uses_current_attempt_start_and_summary_time(self):
        attempt = {'run_started_at': '2026-10-26T22:40:00Z'}
        report = render([], attempt, datetime(2026, 10, 26, 23, 2, 15, tzinfo=timezone.utc))
        self.assertIn('Workflow elapsed to this summary (including queue): 22m 15s', report)
        self.assertIn('Workflow elapsed to this summary (including queue): —', render([], {}))

    def test_multiple_pages_and_absent_jobs_are_safe(self):
        report = render([{'jobs': [{'name': 'one', 'status': 'completed'}]}, {'jobs': [{'name': 'two', 'status': 'completed'}]}, {}])
        self.assertIn('one', report)
        self.assertIn('two', report)
        with self.assertRaises(ValueError): render({'jobs': []})


if __name__ == '__main__': unittest.main()
