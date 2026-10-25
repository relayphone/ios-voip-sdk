"""Bounded, observational evidence after a legacy scenario has already failed."""
import argparse
import json
from pathlib import Path

from sim import bounded, simulator_uuid

NAMES = {'SDKM1Contracts', 'simctl', 'CoreSimulatorService', 'Simulator'}


def capture(out, simulator, runner=bounded):
    out, simulator = Path(out), simulator_uuid(simulator)
    stages = (
        ('processes', ['ps', '-axo', 'pid=,comm='], 5),
        ('screenshot', ['xcrun', 'simctl', 'io', simulator, 'screenshot', str(out/'legacy-startup.png')], 20),
        ('logs', ['xcrun', 'simctl', 'spawn', simulator, 'log', 'show', '--last', '5m',
                  '--style', 'compact', '--predicate',
                  'process == "SDKM1Contracts" OR subsystem == "dev.iosvoipsdk.m1contracts"'], 20))
    evidence = {}
    for name, command, timeout in stages:
        try:
            result = runner(command, timeout)
            row = dict(exitCode=result.returncode, timedOut=result.timed_out)
            evidence[name] = row
            if name == 'processes':
                row['processes'] = []
                for line in result.stdout.decode(errors='replace').splitlines():
                    fields = line.strip().split(None, 1)
                    if len(fields) == 2 and fields[0].isdigit() and Path(fields[1]).name in NAMES:
                        row['processes'].append(dict(pid=int(fields[0]), name=Path(fields[1]).name))
            elif name == 'logs':
                (out/'legacy-startup.log').write_bytes(result.stdout + result.stderr)
        except Exception as error:
            evidence[name] = dict(error=type(error).__name__)
    try:
        (out/'legacy-startup-diagnostics.json').write_text(json.dumps(evidence, indent=2)+'\n')
    except OSError:
        pass
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--simulator', required=True)
    args = parser.parse_args()
    capture(args.out, args.simulator)


if __name__ == '__main__':
    main()
