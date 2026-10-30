#!/usr/bin/env python3
"""Locate a completed app's journal through bound host filesystem evidence."""
import argparse
import json
from pathlib import Path
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'discovery'))
from sdk_m0_conformance import bound_rows
from summarize import one, require


def canonical_file(path):
    return path.is_file() and path.resolve(strict=True) == path


def completed_container(receipt, trace, simulator, run_id, bundle, devices_root=None):
    """Require one canonical data container for a successfully stopped process.

    This discovers a path only. The caller still copies the original journal
    and runs its existing product assertions against that retained evidence.
    """
    require(isinstance(simulator, str) and str(uuid.UUID(simulator)).lower() == simulator.lower(),
            'invalid owned simulator UUID')
    require(isinstance(run_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', run_id),
            'invalid run identity')
    require(isinstance(bundle, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}', bundle),
            'invalid bundle identity')
    receipt, trace = Path(receipt).absolute(), Path(trace).absolute()
    require(not receipt.is_symlink() and not trace.is_symlink(), 'symlinked capture evidence')
    receipt, trace = receipt.resolve(strict=True), trace.resolve(strict=True)
    require(trace.suffix == '.log' and receipt == trace.with_suffix('.receipt.json'),
            'receipt and console trace must be the same capture')
    receipt_bytes, trace_bytes = receipt.read_bytes(), trace.read_bytes()
    rows, supervisor = bound_rows(trace.parent, trace.stem,
                                 dict(runID=run_id, simulatorID=simulator), bundle)
    require(receipt.read_bytes() == receipt_bytes and trace.read_bytes() == trace_bytes,
            'capture changed while binding the completed process')
    require(supervisor.get('terminationMethod') == 'console-launcher-signal',
            'completed container requires the bound console app-stop proof')
    pid = one(rows, 'launch')['pid']
    # The supervisor receipt binds this value after draining native stdout;
    # independently require the original sole native acknowledgement as well.
    headers = re.findall(rb'(?m)^' + re.escape(bundle.encode()) + rb': (\d+)\r?$', trace_bytes)
    require(headers == [str(pid).encode()] and supervisor['launcherAppPID'] == pid,
            'missing or conflicting native launcher PID acknowledgement')

    devices = (Path(devices_root).absolute() if devices_root is not None else
               Path.home() / 'Library/Developer/CoreSimulator/Devices')
    applications = devices / simulator / 'data/Containers/Data/Application'
    require(applications.is_dir() and applications.resolve(strict=True) == applications,
            'owned simulator data-container directory is missing or noncanonical')
    matches = []
    for container in applications.iterdir():
        try:
            if str(uuid.UUID(container.name)).lower() != container.name.lower():
                continue
            if not container.is_dir() or container.resolve(strict=True) != container:
                continue
            session_path = container / 'Documents/.callkit-simulator/session.json'
            if not canonical_file(session_path):
                continue
            session = json.loads(session_path.read_text())
            if not (isinstance(session, dict) and type(session.get('schemaVersion')) is int and
                    session['schemaVersion'] == 1 and session.get('runID') == run_id and
                    type(session.get('pid')) is int and session['pid'] == pid and
                    session.get('bundleID') == bundle and
                    session.get('controlTransport') == 'directory-watch-v1'):
                continue
            matches.append((container, session_path.parent / run_id / 'events.jsonl'))
        except (OSError, ValueError):
            # Unrelated installations may have incomplete or stale sessions.
            # A malformed candidate cannot satisfy this completed capture.
            continue
    require(len(matches) == 1, 'require exactly one canonical container for the completed app; got ' + str(len(matches)))
    container, journal = matches[0]
    require(canonical_file(journal), 'completed app journal is missing or noncanonical')
    return container


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('--trace', required=True, type=Path)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--bundle', required=True)
    args = parser.parse_args()
    try:
        print(completed_container(args.receipt, args.trace, args.simulator, args.run_id, args.bundle))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Completed app container: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
