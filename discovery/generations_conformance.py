#!/usr/bin/env python3
"""Check runtime lifecycle policy; this suite has no measured device oracle."""
import json
from pathlib import Path
import sys
from conformance import bound_capture
from summarize import EvidenceError, require

EXPECTED = {
    'completion continuation cancelled after revival',
    'completion continuation cannot mutate reused UUID',
    'delegate callback cancelled after revival',
    'muted invalidation produces no stale unmute',
    'queued unmute producer cancelled after revival',
    'failed answer cannot end reused UUID',
    'expired answer cannot end reused UUID',
}


def validate(directory):
    rows, engine = bound_capture(directory, 'generations')
    checks = [r for r in rows if r['event'] == 'generation.check']
    require(len(checks) == len(EXPECTED) and {r['name'] for r in checks} == EXPECTED, 'missing lifecycle boundary')
    require(all(r.get('success') is True for r in checks), 'lifecycle regression')
    require(not any(r['event'] == 'transaction.delivered' and r['origin'] == 'postEndUnmute' for r in engine), 'stale unmute produced')
    return dict(success=True, checks=sorted(EXPECTED),
                reference='runtime policy; no device measurement')


def main():
    try:
        result = validate(Path(sys.argv[1]))
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
