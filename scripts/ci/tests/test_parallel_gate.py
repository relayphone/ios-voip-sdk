import re
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import SDK_NATIVE_JOBS, gate, select


NATIVE = ('offline-controls', 'apple-host-controls', 'sdk-example', 'sdk-core',
          'simulator-journeys')


def results(native):
    return {'changes': {'result': 'success'}, **{job: {'result': native} for job in NATIVE}}


def job_blocks(text):
    body = text.split('\njobs:\n', 1)[1]
    names = re.split(r'(?m)^  ([A-Za-z_][\w-]*):\s*$', body)
    return dict(zip(names[1::2], names[2::2]))


class ParallelGateTests(unittest.TestCase):
    def test_native_shards_match_the_selector(self):
        self.assertEqual(SDK_NATIVE_JOBS, NATIVE)

    def test_full_selection_requires_every_shard(self):
        expected = select([], full=True)['sdk_plan']
        rows = results('success')
        gate(rows, expected)
        for job in NATIVE:
            for result in ('failure', 'cancelled', 'skipped'):
                with self.subTest(job=job, result=result):
                    rows[job]['result'] = result
                    with self.assertRaises(ValueError): gate(rows, expected)
                    rows[job]['result'] = 'success'

    def test_docs_only_accepts_only_unselected_skips(self):
        expected = select(['README.md'])['sdk_plan']
        rows = results('skipped')
        gate(rows, expected)
        rows['sdk-core']['result'] = 'success'
        with self.assertRaises(ValueError): gate(rows, expected)

    def test_missing_or_unexpected_producer_fails_closed(self):
        expected = select([], full=True)['sdk_plan']
        rows = results('success')
        del rows['sdk-core']
        with self.assertRaises(ValueError): gate(rows, expected)
        rows['sdk-core'] = {'result': 'success'}
        rows['unknown-native'] = {'result': 'success'}
        with self.assertRaises(ValueError): gate(rows, expected)

    def test_real_workflow_wires_selected_shards_into_the_stable_gate(self):
        root = Path(__file__).resolve().parents[3]
        jobs = job_blocks((root / '.github/workflows/sdk-m0.yml').read_text())
        for job in NATIVE:
            with self.subTest(job=job):
                self.assertIn("needs.changes.outputs.sdk == 'true'", jobs[job])
                self.assertIn(job, jobs['plain-simulator'])


if __name__ == '__main__': unittest.main()
