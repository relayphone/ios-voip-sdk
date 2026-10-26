#!/usr/bin/env python3
"""Run runtime host checks with bounded child processes and retained logs."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
GATES = [
    ('inspector', ['-m', 'unittest', 'discover', '-s', 'Tests/Inspector', '-p', 'test_*.py']),
    ('runtime-events', ['-m', 'unittest', 'discover', '-s', 'Tests/RuntimeEvents', '-p', 'test_*.py']),
    ('sim-helper', ['-m', 'unittest', 'discover', '-s', 'scripts/sim', '-p', 'test_*.py']),
    ('cli', ['discovery/check_cli_controls.py']),
    ('sdk-system', ['discovery/check_sdk_system.py']),
    ('sdk-m1', ['discovery/check_sdk_m1.py']),
    ('sdk-contracts', ['discovery/check_sdk_m1_contracts.py']),
    ('sdk-container', ['discovery/check_sdk_m1_container_capture.py']),
    ('sdk-m0', ['discovery/check_sdk_m0.py']),
    ('swift-livekit', ['discovery/check_swift_livekit.py']),
    ('swift-startup', ['Tests/SwiftLiveKit/run_startup.py']),
]


def source_digest():
    diff = subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=ROOT, timeout=20)
    return hashlib.sha256(diff).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--multicall', action='store_true')
    parser.add_argument('--timeout', type=float, default=240)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 600:
        parser.error('--timeout must be positive, finite and at most 600 seconds')
    args.out.mkdir(parents=True, exist_ok=False)
    commands = [(name, [sys.executable, *parts]) for name, parts in GATES]
    commands += [('sdk-core', ['bash', 'Tests/VoIPSDK/run.sh']),
                 ('sdk-report', ['bash', 'Tests/VoIPSDK/run_report_contracts.sh'])]
    if args.multicall:
        commands.append(('lck-policy', [sys.executable, 'Tests/RuntimeEvents/run_lck_multi_policy.py']))
    before = source_digest()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, timeout=10).strip()
    results = []
    for name, command in commands:
        log = args.out / (name + '.log')
        started = time.monotonic()
        # The watchdog is a parent process: tests inherit no ITIMER_REAL alarm.
        with log.open('wb') as stream:
            result = subprocess.run([str(ROOT / 'scripts/ci/bounded'), str(args.timeout), *command],
                                    cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=args.timeout + 20)
        success = result.returncode == 0
        try:
            output = log.read_text().strip()
            final = json.loads(output[output.rfind('\n{') + 1:])
            if isinstance(final, dict) and 'success' in final:
                success = success and final['success'] is True
        except (ValueError, IndexError):
            pass
        results.append(dict(name=name, command=command, returncode=result.returncode,
                            success=success, seconds=round(time.monotonic() - started, 3), log=str(log)))
        if not success:
            break
    unchanged = source_digest() == before
    success = unchanged and len(results) == len(commands) and all(row['success'] for row in results)
    summary = args.out / 'summary.json'
    summary.write_text(json.dumps(dict(success=success, head=head, sourceUnchanged=unchanged,
                                      sourceDiffSHA256=before, gates=results), indent=2) + '\n')
    print(json.dumps(dict(success=success, summary=str(summary))))
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
