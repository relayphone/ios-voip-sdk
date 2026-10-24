#!/usr/bin/env python3
"""Own one unbooted simulator for the complete native and GUI CI journey."""
import argparse
import json
import os
from pathlib import Path
import sys
import uuid

from run import latest_runtime, remove_simulators, run


def simulator_uuid(value):
    value = value.strip()
    if str(uuid.UUID(value)).lower() != value.lower():
        raise ValueError('Expected a simulator UUID')
    return value


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
        raise ValueError('An exact simulator runtime is required')
    device, failure, attempted = None, None, False
    # Reserve ownership without overwriting another run's record or a symlink.
    record = os.fdopen(os.open(id_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w')
    try:
        runtime = latest_runtime(json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '-j',
                                                timeout=60))['runtimes'], runtime)
        name = 'M4 CI ' + str(uuid.uuid4())
        record.write('name:' + name + '\n')
        record.flush()
        os.fsync(record.fileno())
        attempted = True
        device = simulator_uuid(run('xcrun', 'simctl', 'create', name,
                                    'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
                                    runtime, timeout=60))
        record.seek(0)
        record.write(device + '\n')
        record.truncate()
        record.flush()
        os.fsync(record.fileno())
        if env_file:
            with env_file.open('a') as environment:
                environment.write('CKSIM_TEST_SIMULATOR=' + device + '\n')
    except BaseException as error:
        failure = error
    try:
        record.close()
    except BaseException as error:
        if failure is None:
            failure = error
    if failure is not None:
        # Run outside the exception handler so native cleanup reports failures.
        try:
            if device:
                remove_simulators([device])
                id_file.unlink()
            elif attempted:
                cleanup(id_file)
            else:
                id_file.unlink()
        except Exception as error:
            print('Simulator cleanup failed: ' + str(error), file=sys.stderr)
        raise failure
    return device


def cleanup(id_file):
    try:
        value = id_file.read_text().strip()
    except FileNotFoundError:
        return
    device = recover_name(value[5:]) if value.startswith('name:') else simulator_uuid(value)
    remove_simulators([device])
    id_file.unlink()


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
