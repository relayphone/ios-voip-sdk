import json
import argparse
from pathlib import Path
import time

def read_results(path, required, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            entries = json.loads(path.read_text())
            break
        except FileNotFoundError:
            if time.monotonic() >= deadline:
                raise TimeoutError(f'Missing results file: {path}')
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    if not isinstance(entries, list) or not entries:
        raise ValueError('Expected a nonempty results array')
    ids = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {'id', 'pass', 'values', 'threads'}:
            raise ValueError(f'Invalid result entry: {entry!r}')
        if (entry['pass'] is not True or not isinstance(entry['id'], str)
                or not isinstance(entry['values'], dict) or not isinstance(entry['threads'], list)):
            raise ValueError(f'Failed demonstration or invalid evidence: {entry!r}')
        ids.append(entry['id'])
    if len(ids) != len(set(ids)) or set(ids) != required:
        raise ValueError(f'Expected exactly {sorted(required)}; received {ids}')
    return entries

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('path', type=Path)
    parser.add_argument('--require', nargs='+', required=True)
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    entries = read_results(args.path, set(args.require), args.timeout)
    Path('out/expo2-results.json').write_text(json.dumps(entries, indent=2) + '\n')
    print(json.dumps(entries, indent=2))
