#!/usr/bin/env python3
"""Require fresh, process-bound app evidence for lifecycle race regressions."""
import json
from pathlib import Path
import sys
from conformance import bound_capture
from summarize import require

rows, engine = bound_capture(Path(sys.argv[1]), 'generations')
expected = {
    'completion continuation cancelled after revival',
    'completion continuation cannot mutate reused UUID',
    'delegate callback cancelled after revival',
    'muted invalidation produces no stale unmute',
    'queued unmute producer cancelled after revival',
    'failed answer cannot end reused UUID',
    'expired answer cannot end reused UUID',
}
checks = [r for r in rows if r['event'] == 'generation.check']
require(len(checks) == len(expected) and {r['name'] for r in checks} == expected, 'missing lifecycle boundary')
require(all(r.get('success') is True for r in checks), 'lifecycle regression')
require(not any(r['event'] == 'transaction.delivered' and r['origin'] == 'postEndUnmute' for r in engine), 'stale unmute produced')
print(json.dumps(dict(success=True, checks=sorted(expected)), indent=2))
