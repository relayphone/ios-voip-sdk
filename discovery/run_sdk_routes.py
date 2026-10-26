#!/usr/bin/env python3
"""Run the native route contract on one owned iPhone Duo; no fold claim."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/sim'))
from sim import Interrupted, Result, Session, bounded
from paths import completed_container
from run_scenario import run as supervise
from run_swift_livekit import redact
from sdk_m1_contracts_conformance import BUNDLE, digest, validate, validate_build
from summarize import require

DEVICE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo'
CASE = 'audio-routes'
NAME = 'sdk-m1-contract-' + CASE


@contextmanager
def launch_environment(run_id, inherited):
    previous = dict(os.environ)
    try:
        for key in list(os.environ):
            if key.startswith('SIMCTL_CHILD_SDK_') or key.startswith('SIMCTL_CHILD_CKSIM_'):
                del os.environ[key]
        os.environ.update(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=inherited,
                          SIMCTL_CHILD_CKSIM_RUN_ID=run_id,
                          SIMCTL_CHILD_SDK_M1_CONTRACT_CASE=CASE)
        yield
    finally:
        os.environ.clear()
        os.environ.update(previous)


def select_runtime(inventory):
    rows = [row for row in inventory['runtimes'] if row.get('platform') == 'iOS' and
            row.get('isAvailable') and tuple(map(int, row['version'].split('.'))) >= (27, 1)]
    require(rows, 'iPhone Duo requires an available iOS 27.1+ runtime; no substitute device or OS')
    return max(rows, key=lambda row: tuple(map(int, row['version'].split('.'))))


def capture(build, out, session_factory=Session, supervisor=supervise, locate=completed_container):
    validate_build(build)
    # CI sets this explicitly. A local caller must supply its inherited launch
    # value; this runner never changes launchd or silently discards its libraries.
    require('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES' in os.environ,
            'provide SIMCTL_CHILD_DYLD_INSERT_LIBRARIES explicitly for this isolated runner')
    inherited = os.environ['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES']
    require(not any(Path(p).name in ('CKSimRuntime.dylib', 'CKSimLoader.dylib')
                    for p in inherited.split(':') if p), 'external SDK runtime injection refused')
    out.mkdir()
    run_id = str(uuid.uuid4())
    trace, receipt = out / (NAME + '.log'), out / (NAME + '.receipt.json')
    session = None

    def execute(command, timeout):
        if command[:3] != ['xcrun', 'simctl', 'launch']:
            return bounded(command, timeout)
        require(timeout == 90 and command == ['xcrun', 'simctl', 'launch', '--console',
                '--terminate-running-process', session.current, BUNDLE], 'unexpected route launch')
        with launch_environment(run_id, inherited):
            terminate = [sys.executable, str(ROOT / 'scripts/sim/sim.py'), 'call',
                         str(out / 'simulator-state.json'), '5',
                         'xcrun', 'simctl', 'terminate', session.current, BUNDLE]
            status = supervisor(command, terminate, trace, receipt, timeout,
                dict(runID=run_id, simulatorID=session.current, scenario=NAME, bundleID=BUNDLE),
                console_launcher_stop=True)
        return Result(command, status)

    session = session_factory(out / 'simulator-state.json', runner=execute, recovery_timeout=60)
    primary = None
    try:
        def call(arguments, timeout):
            result = session.call(['xcrun', 'simctl', *arguments], timeout)
            require(result.returncode == 0, 'simulator helper failed: ' + arguments[0])
            return result
        runtimes = json.loads(call(['list', 'runtimes', '-j'], 180).stdout)
        runtime = select_runtime(runtimes)
        devices = json.loads(call(['list', 'devicetypes', '-j'], 60).stdout)
        require(any(row.get('identifier') == DEVICE for row in devices['devicetypes']),
                'the iPhone Duo simulator device type is unavailable')
        call(['create', 'sdk-routes-duo-' + run_id, DEVICE, runtime['identifier']], 30)
        call(['boot', session.current], 60)
        call(['bootstatus', session.current, '-b'], 300)
        call(['install', session.current, str(build / 'SDKM1Contracts.app')], 180)
        # The shared helper owns preparation recovery. The existing supervisor
        # owns the sole console launch, native PID binding and 90-second budget.
        session.checkpoint()
        simulator = session.current
        call(['launch', '--console', '--terminate-running-process', simulator, BUNDLE], 90)
        container = locate(receipt, trace, simulator, run_id, BUNDLE)
        journal = out / (NAME + '.runtime.jsonl')
        shutil.copyfile(container / 'Documents/.callkit-simulator' / run_id / 'events.jsonl', journal)
        row = json.loads(receipt.read_text())
        row['journalSHA256'] = digest(journal)
        receipt.write_text(json.dumps(row, indent=2) + '\n')
        result = validate(build, out, cases=(CASE,))
        require(tuple(map(int, result['simulatorOS'].split('.'))) >= (27, 1),
                'the native route contract did not execute on iOS 27.1+')
        result['deviceType'] = DEVICE
        result['runtime'] = {key: runtime[key] for key in ('identifier', 'version', 'buildversion')}
    except BaseException as error:
        primary = error
        raise
    finally:
        errors = []
        try:
            require(session.cleanup(timeout=60).returncode == 0, 'owned route simulator cleanup failed')
        except BaseException as error:
            errors.append(error)
        try:
            redact(out, inherited)
        except BaseException as error:
            errors.append(error)
        if errors:
            if primary is None:
                raise errors[0]
            for error in errors:
                print('Route cleanup also failed: ' + type(error).__name__, file=sys.stderr)
    (out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return result



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    def interrupted(signum, _frame):
        raise Interrupted(signum)
    signal.signal(signal.SIGTERM, interrupted)
    print(json.dumps(capture(args.build.resolve(), args.out.absolute()), indent=2))


if __name__ == '__main__':
    main()
