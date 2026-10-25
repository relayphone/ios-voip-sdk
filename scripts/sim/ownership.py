"""Publish the current simulator while keeping the session as ownership authority."""
import os
from pathlib import Path

from sim import simulator_uuid


def publish(device, state_path, id_file=None, env_file=None):
    device = simulator_uuid(device)
    if id_file is not None:
        id_file = Path(id_file)
        descriptor = os.open(id_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as record:
            record.write(device + '\n')
            record.flush()
            os.fsync(record.fileno())
    if env_file is not None:
        values = [('CKSIM_TEST_SIMULATOR', device), ('SIM_STATE', str(Path(state_path).resolve()))]
        if id_file is not None:
            values.append(('CKSIM_SIMULATOR_ID_FILE', str(id_file.resolve())))
        with Path(env_file).open('a') as environment:
            environment.write(''.join(key + '=' + value + '\n' for key, value in values))
