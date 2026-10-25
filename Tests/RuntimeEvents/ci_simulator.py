#!/usr/bin/env python3
"""Own one unbooted simulator for the complete native and GUI CI journey."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from run import latest_runtime, remove_simulators, run

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/sim'))
import sim as sim_helper
from ownership import publish


def simulator_uuid(value):
    value = value.strip()
    if str(uuid.UUID(value)).lower() != value.lower():
        raise ValueError('Expected a simulator UUID')
    return value



def state_path(id_file):
    return Path(str(id_file) + '.state.json')


def transport(errors, before_create=None):
    """Keep the invocation seam used by fixtures and preserve native outcomes."""
    def invoke(command, timeout):
        if before_create and command[:3] == ['xcrun', 'simctl', 'create']:
            before_create('name:' + command[3])
        try:
            output = run(*command, timeout=timeout)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            errors.append(error)
            result = getattr(error, 'result', None)
            if result is None:
                timed_out = isinstance(error, subprocess.TimeoutExpired)
                status = 124 if timed_out else 127 if isinstance(error, OSError) else 128
                result = sim_helper.Result(command, status, stderr=str(error).encode(), timed_out=timed_out)
            result.transport_error = error
            return result
        return sim_helper.Result(command, 0, stdout=output.encode())
    return invoke


def require_success(result, errors=()):
    if result.returncode:
        error = getattr(result, 'transport_error', None)
        if error is not None:
            raise error
        if errors:
            raise errors[0]
        raise RuntimeError(result.stderr.decode(errors='replace').strip() or 'Simulator operation failed')


def classify(step):
    try:
        sim_helper.report_failure('infra:' + step, 'not eligible')
    except (OSError, ValueError):
        pass  # Reporting must not replace the original infrastructure failure.


def recover_name(name):
    if not name.startswith('M4 CI ') or simulator_uuid(name[6:]) != name[6:]:
        raise ValueError('Expected a full unique M4 CI simulator name')
    inventory = json.loads(run('xcrun', 'simctl', 'list', 'devices', '-j', timeout=60))['devices']
    matches = [device for devices in inventory.values() for device in devices
               if device.get('name') == name]
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one simulator named ' + name)
    return simulator_uuid(matches[0]['udid'])


def create(runtime, id_file, env_file=None):
    if not runtime:
        classify('runtime-selection')
        raise ValueError('An exact simulator runtime is required')
    ledger = state_path(id_file)
    try:
        if ledger.exists() or ledger.is_symlink():
            raise FileExistsError('Simulator ownership session already exists: ' + str(ledger))
        # Reserve ownership without overwriting another run's record or a symlink.
        record = os.fdopen(os.open(id_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w')
    except BaseException:
        classify('state')
        raise
    device, failure, session = None, None, None
    errors = []
    step, lifecycle_failure = 'inventory', False
    try:
        def mirror(value):
            record.seek(0)
            record.write(value + '\n')
            record.truncate()
            record.flush()
            os.fsync(record.fileno())
        step = 'state'
        session = sim_helper.Session(ledger, runner=transport(errors, mirror), inventory_timeout=60)
        step = 'inventory'
        result = session.call(['xcrun', 'simctl', 'list', 'runtimes', '-j'], 60)
        lifecycle_failure = bool(result.returncode)
        require_success(result)
        runtimes = json.loads(result.stdout)['runtimes']
        step = 'runtime-selection'
        runtime = latest_runtime(runtimes, runtime)
        step = 'create'
        result = session.call(['xcrun', 'simctl', 'create', 'M4 CI ',
                               'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime], 60)
        lifecycle_failure = bool(result.returncode)
        require_success(result)
        device = session.current
        step = 'export'
        publish(device, ledger, id_file, env_file)
    except BaseException as error:
        failure = error
    if failure is None:
        step = 'state'
    try:
        record.close()
    except BaseException as error:
        if failure is None:
            failure = error
    if failure is not None:
        if not lifecycle_failure:
            classify(step)
        # Run outside the exception handler so native cleanup reports failures.
        try:
            if session is not None:
                cleanup_errors = []
                session.runner = transport(cleanup_errors)
                require_success(session.cleanup(timeout=30), cleanup_errors)
            if session is None or not session.state['owned']:
                id_file.unlink()
        except Exception as error:
            print('Simulator cleanup failed: ' + str(error), file=sys.stderr)
        raise failure
    return device


def cleanup(id_file):
    result = None
    try:
        ledger = state_path(id_file)
        if ledger.exists() or ledger.is_symlink():
            errors = []
            session = sim_helper.Session.resume(ledger, runner=transport(errors), inventory_timeout=60)
            if session.current:
                try:
                    publish(session.current, ledger, id_file)
                except OSError as error:
                    print('Simulator mirror refresh failed: ' + str(error), file=sys.stderr)
            result = session.cleanup(timeout=30)
            require_success(result, errors)
            id_file.unlink(missing_ok=True)
            return
        try:
            value = id_file.read_text().strip()
        except FileNotFoundError:
            return
        device = recover_name(value[5:]) if value.startswith('name:') else simulator_uuid(value)
        remove_simulators([device])
        id_file.unlink()
    except BaseException:
        if result is None or not result.returncode:
            classify('cleanup')
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    creator = commands.add_parser('create')
    creator.add_argument('--runtime', required=True)
    creator.add_argument('--id-file', type=Path, required=True)
    creator.add_argument('--env-file', type=Path)
    cleaner = commands.add_parser('cleanup')
    cleaner.add_argument('--id-file', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'create':
        create(args.runtime, args.id_file, args.env_file)
    else:
        cleanup(args.id_file)


if __name__ == '__main__':
    main()
