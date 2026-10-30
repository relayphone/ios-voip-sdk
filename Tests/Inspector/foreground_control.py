"""Private challenged ACTIVE transport; does not replace projection assertions."""
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid

from inspector_startup import canonical, supervise_launch


SESSION_KEYS = ('schemaVersion', 'runID', 'pid', 'bundleID', 'profile')
IDENTITY_KEYS = ('schemaVersion', 'nonce', 'pid', 'bundleID', 'dataContainer', 'startedWallTimeMS', 'session')


def _integer(value, minimum=1):
    return type(value) is int and value >= minimum


def _uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)).lower() == value.lower()
    except ValueError:
        return False


def _same_identity(value, identity):
    return (all(value.get(key) == identity[key] and type(value.get(key)) is type(identity[key]) for key in IDENTITY_KEYS) and
            all(type(value['session'].get(key)) is type(identity['session'][key]) for key in SESSION_KEYS))


def _read(path):
    canonical(path)
    try:
        if not stat.S_ISREG(path.stat().st_mode):
            raise RuntimeError('Foreground evidence is not a regular file')
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    if len(data) > 16384:
        raise RuntimeError('Foreground evidence exceeds protocol size')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise RuntimeError('Foreground evidence is not an object')
    return value


def read_identity(container, *, bundle, pid, nonce, session):
    """Pin the actual native start, including an older Fixture's own identity."""
    container = canonical(Path(container))
    if not container.is_absolute():
        raise ValueError('Foreground data container must be absolute')
    value = _read(container / 'Documents/cksim-foreground-phase-identity.json')
    native_session = {key: session[key] for key in SESSION_KEYS}
    if (value is None or set(value) != set(IDENTITY_KEYS) or value.get('schemaVersion') != 1 or
            type(value['schemaVersion']) is not int or not _integer(value.get('pid')) or
            not _integer(value.get('startedWallTimeMS')) or
            not isinstance(nonce, str) or not 1 <= len(nonce.encode()) <= 128 or
            value.get('bundleID') != bundle or value.get('pid') != pid or value.get('nonce') != nonce or
            value.get('dataContainer') != str(container) or value.get('session') != native_session or
            any(type(value['session'].get(key)) is not type(native_session[key]) for key in SESSION_KEYS)):
        raise RuntimeError('Foreground native identity is unavailable or changed')
    if (type(pid) is not int or not _integer(native_session['pid']) or
            type(native_session['schemaVersion']) is not int or native_session['schemaVersion'] != 1 or
            any(not isinstance(native_session[key], str) or not native_session[key] for key in SESSION_KEYS[1:] if key != 'pid') or
            value['startedWallTimeMS'] > time.time() * 1000 + 1000):
        raise RuntimeError('Foreground native identity has invalid field types or timing')
    return value


def activate_existing(device, identity, phase, deadline, *, consumer_started_wall_ms, log,
                      bridge_alive=lambda: True):
    """One launch RPC, fresh ACTIVE challenge, owned reap, then fresh ACTIVE again.

    The supervisor receives a private normalized transport view: its
    startedWallTimeMS is the ORIGINAL Inspector consumer start, even when the
    foregrounded native identity is an older Fixture. Returned evidence always
    retains the actual native identity. The caller's absolute host deadline
    bounds transport waits; native process age is not a performance assertion.
    """
    if not _uuid(device) or not isinstance(phase, str) or re.fullmatch(r'[A-Za-z0-9_-]{1,64}', phase) is None:
        raise ValueError('Foreground device or phase is invalid')
    if not _integer(consumer_started_wall_ms):
        raise ValueError('Foreground consumer start is invalid')
    def budget():
        remaining = deadline - time.monotonic()
        if remaining <= 0 or time.time() * 1000 - consumer_started_wall_ms < -1000:
            raise RuntimeError('Foreground host budget expired or consumer start is in the future')
        return remaining
    def pinned():
        budget()
        current = read_identity(identity['dataContainer'], bundle=identity['bundleID'], pid=identity['pid'],
                                nonce=identity['nonce'], session=identity['session'])
        budget()
        if current != identity:
            raise RuntimeError('Foreground native identity changed')
    pinned()
    challenge = str(uuid.uuid4())
    documents = Path(identity['dataContainer']) / 'Documents'
    request = canonical(documents / 'cksim-foreground-phase-request.json')
    temporary = canonical(documents / ('.foreground-request-' + challenge + '.tmp'))
    try:
        with temporary.open('x') as stream:
            json.dump(dict(identity, phase=phase, challenge=challenge), stream)
        temporary.replace(request)
    finally:
        temporary.unlink(missing_ok=True)
    last = None
    def observe(resume_after=None):
        nonlocal last
        pinned()
        value = _read(documents / 'cksim-foreground-phase-ack.json')
        budget()
        # The native writer retains the previous challenge's ACK while inactive.
        if value is None or value.get('challenge') != challenge:
            return None
        if (not _same_identity(value, identity) or value.get('phase') != phase or
                value.get('applicationState') != 'active' or not _uuid(value.get('publicationID')) or
                any(not _integer(value.get(key), 0 if key == 'activeGeneration' else 1)
                    for key in ('wallTimeMS', 'uptimeNS', 'activeGeneration')) or
                not -1000 <= time.time() * 1000 - value['wallTimeMS'] <= 5000 or
                value['wallTimeMS'] < identity['startedWallTimeMS']):
            raise RuntimeError('Foreground ACTIVE acknowledgement is invalid, foreign, or stale')
        active_wall, active_uptime = value.get('lastDidBecomeActiveWallTimeMS'), value.get('lastDidBecomeActiveUptimeNS')
        if ((active_wall is None) != (active_uptime is None) or
                active_wall is not None and (not _integer(active_wall) or not _integer(active_uptime) or
                    active_wall > value['wallTimeMS'] or active_uptime > value['uptimeNS'])):
            raise RuntimeError('Foreground activation timing is invalid')
        if last is not None:
            if any(value[key] < last[key] for key in ('wallTimeMS', 'uptimeNS', 'activeGeneration')):
                raise RuntimeError('Foreground publication regressed')
            if resume_after is not None and (value['publicationID'] == last['publicationID'] or
                    value['wallTimeMS'] <= resume_after or value['uptimeNS'] <= last['uptimeNS']):
                return None
        last = value
        budget()
        return dict(inspectorPID=identity['pid'], startedWallTimeMS=consumer_started_wall_ms,
                    session=identity['session'], cursor=value['activeGeneration'], wallTimeMS=value['wallTimeMS'], online=True)
    supervise_launch(['xcrun', 'simctl', 'launch', device, identity['bundleID']], env=dict(os.environ),
                     log=log, observe=observe, bridge_alive=bridge_alive, host_timeout=budget(),
                     consumer_timeout=None, bundle=identity['bundleID'])
    budget()
    return last
