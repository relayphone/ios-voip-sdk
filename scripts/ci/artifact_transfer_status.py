"""Require a successful artifact upload and retain any transport recovery."""
import os
from pathlib import Path


def main():
    first, retry = os.environ.get('TRANSFER_FIRST'), os.environ.get('TRANSFER_RETRY')
    if (first, retry) == ('success', 'skipped'):
        status, detail = 0, 'completed; retry unused'
    elif (first, retry) == ('failure', 'success'):
        status, detail = 0, 'retry succeeded; one upload retry used'
    else:
        status, detail = 1, 'not completed; upload retry exhausted or interrupted'
    message = ('Artifact upload: ' if (first, retry) == ('success', 'skipped')
               else '`infra:artifact-upload`: ') + detail
    print(('::error::' if status else '::notice::') + message)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as summary:
            summary.write('- ' + message + '\n')
    return status


if __name__ == '__main__':
    raise SystemExit(main())
