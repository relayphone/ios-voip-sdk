#!/usr/bin/env python3
"""Render current-attempt Actions job timings without exposing job payloads."""
from datetime import datetime, timezone
import html
import json
import sys


def seconds(start, end):
    try:
        a = datetime.fromisoformat(start.replace('Z', '+00:00'))
        b = datetime.fromisoformat(end.replace('Z', '+00:00'))
        value = int((b - a).total_seconds())
        return f'{value // 60}m {value % 60}s' if value >= 0 else '—'
    except (AttributeError, TypeError, ValueError, OverflowError):
        return '—'


def carried_forward(job):
    try:
        created = datetime.fromisoformat(job['created_at'].replace('Z', '+00:00'))
        started = datetime.fromisoformat(job['started_at'].replace('Z', '+00:00'))
        return started < created
    except (KeyError, AttributeError, TypeError, ValueError, OverflowError):
        return False


def render(pages, attempt=None, now=None):
    if not isinstance(pages, list):
        raise ValueError('Expected paginated job responses')
    elapsed = seconds((attempt or {}).get('run_started_at'),
                      (now or datetime.now(timezone.utc)).isoformat())
    lines = ['### SDK CI timing — current attempt', '',
             f'Workflow elapsed to this summary (including queue): {elapsed}.', '',
             'Completed jobs only. Created-to-started is a queue proxy and may include dependency or scheduler delays. '
             'Earlier-attempt jobs may be omitted or marked carried forward.', '',
             '| Job | Result | Created → started (queue proxy) | Execution |',
             '| --- | --- | ---: | ---: |']
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get('jobs', []), list):
            raise ValueError('Invalid jobs response')
        for job in page.get('jobs', []):
            if not isinstance(job, dict):
                raise ValueError('Invalid job')
            if job.get('status') != 'completed':
                continue
            name = html.escape(str(job.get('name', 'unknown')).replace('\n', ' ').replace('\r', ' ')).replace('|', '\\|')
            status = str(job.get('conclusion') or job.get('status') or 'unknown')
            status = html.escape(status.replace('\n', ' ')).replace('|', '\\|')
            if carried_forward(job):
                status = 'carried forward'
                queue = execution = '—'
            elif (job.get('conclusion') == 'skipped' or
                  job.get('conclusion') == 'cancelled' and not job.get('steps')):
                queue = execution = '—'
            else:
                queue = seconds(job.get('created_at'), job.get('started_at'))
                execution = seconds(job.get('started_at'), job.get('completed_at'))
            lines.append(f'| {name} | {status} | {queue} | {execution} |')
    return '\n'.join(lines) + '\n'


def main():
    try:
        attempt = None
        if len(sys.argv) == 2:
            try:
                with open(sys.argv[1]) as metadata:
                    attempt = json.load(metadata)
                if not isinstance(attempt, dict):
                    attempt = None
            except (OSError, ValueError):
                pass
        print(render(json.load(sys.stdin), attempt), end='')
        return 0
    except (OSError, ValueError, TypeError) as error:
        print('CI timing report unavailable: ' + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
