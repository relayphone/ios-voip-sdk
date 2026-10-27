#!/usr/bin/env python3
"""Native acceptance against a disposable simulator, preserving only ignored/CI output."""
import argparse
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = 'dev.callkitsim.eventfixture'
sys.path.insert(0, str(ROOT / 'scripts/sim'))
import sim as simulator_infra
from ownership import publish

execute_host = runpy.run_path(str(ROOT / 'scripts/ci/bounded'))['execute']


class CommandError(RuntimeError):
    """Preserve the native result while the lifecycle owner decides recovery."""
    def __init__(self, result, timeout):
        self.result = result
        executable = result.args[0] if result.args else 'Simulator preparation'
        message = (f'{executable} timed out after {timeout}s: {result.stdout!r}\n{result.stderr!r}'
                   if result.timed_out else
                   f'{executable} failed: {result.stdout.decode(errors="replace")}\n{result.stderr.decode(errors="replace")}')
        super().__init__(message)
        result.transport_error = self


def latest_runtime(runtimes, required=None):
    available = [r for r in runtimes if r.get('isAvailable') and r.get('platform') == 'iOS']
    if required:
        available = [r for r in available if r['identifier'] == required]
    if not available:
        raise RuntimeError('No available iOS simulator runtime' + (': ' + required if required else ''))
    return max(available, key=lambda r: tuple(int(part) for part in r['version'].split('.')))['identifier']


def run(*args, timeout=120, **kwargs):
    command = list(map(str, args))
    if command[:2] == ['xcrun', 'simctl']:
        started = time.monotonic() if command[2:3] == ['install'] else None
        result = None
        try:
            try: result = simulator_infra.bounded(command, timeout=timeout, **kwargs)
            except subprocess.TimeoutExpired as error:
                result = simulator_infra.Result(command, 124, error.stdout or b'', error.stderr or b'', timed_out=True)
        finally:
            if started is not None:
                simulator_infra.summary('measurement:fixture-install',
                    f'elapsed={time.monotonic() - started:.3f}s bound={timeout}s '
                    f'status={result.returncode if result else "unknown"} timed_out={result.timed_out if result else "unknown"}')
        if result.returncode:
            raise CommandError(result, timeout)
        return result.stdout.decode().strip()
    try:
        result = execute_host(list(map(str, args)), timeout, capture_output=True, **kwargs)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f'{args[0]} timed out after {timeout}s: {error.stdout!r}\n{error.stderr!r}') from error
    if result.cancelled:
        raise SystemExit(128 + result.cancelled)
    if result.timed_out:
        raise RuntimeError(f'{args[0]} timed out after {timeout}s: {result.stdout!r}\n{result.stderr!r}')
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stdout.decode(errors="replace")}\n{result.stderr.decode(errors="replace")}')
    return result.stdout.decode().strip()


def session_transport(command, timeout, **kwargs):
    try:
        return simulator_infra.Result(command, 0, run(*command, timeout=timeout, **kwargs).encode())
    except CommandError as error:
        return error.result


def lifecycle(session, *parts, timeout=120, before_install=None, executor=None, **kwargs):
    """Only an authoritative owner may replace a device before app launch."""
    command = list(map(str, ('xcrun', 'simctl', *parts)))
    if session is None:
        if before_install is not None and command[2] == 'install':
            before_install(command[3])
        if executor is None:
            return run(*command, timeout=timeout, **kwargs)
        result = executor(command, timeout, **kwargs)
        if result.returncode:
            raise getattr(result, 'transport_error', None) or CommandError(result, timeout)
        return result.stdout.decode().strip()
    previous_runner = session.runner
    errors = []
    def transport(argv, bound):
        if before_install is not None and argv[2] == 'install':
            before_install(argv[3])
        outcome = (executor or session_transport)(argv, bound, **kwargs)
        error = getattr(outcome, 'transport_error', None)
        if error is not None: errors.append(error)
        return outcome
    session.runner = transport
    result = None
    try:
        result = session.call(command, timeout)
    except simulator_infra.Interrupted:
        raise
    except Exception as error:
        # A secondary metadata/state failure during replacement must retain
        # the original typed transport result. Cancellation still propagates.
        if not errors: raise
        simulator_infra.report_failure('infra:' + parts[0], 'exhausted; owned recovery failed')
        simulator_infra.report_failure('infra:cleanup', 'original preparation failure retained; ownership remains recorded')
        raise errors[0] from error
    finally:
        session.runner = previous_runner
        failed = sys.exc_info()[0] is not None or result is not None and result.returncode != 0
        if session.current:
            try:
                publish(session.current, session.path, os.environ.get('CKSIM_SIMULATOR_ID_FILE'), os.environ.get('GITHUB_ENV'))
            except OSError:
                if not failed: raise
                simulator_infra.summary('infra:ownership-export', 'original preparation failure retained')
    if result.returncode:
        error = getattr(result, 'transport_error', None) or (errors[0] if errors else None)
        raise error if error is not None else CommandError(result, timeout)
    return result.stdout.decode().strip()


def remove_simulators(devices):
    errors = []
    for device in reversed(devices):
        for operation in ('shutdown', 'delete'):
            try:
                run('xcrun', 'simctl', operation, device, timeout=30)
            except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                errors.append(str(error))
    if errors:
        if sys.exc_info()[0] is None:
            raise RuntimeError('\n'.join(errors))
        print('\n'.join(errors), file=sys.stderr)


def wait(predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError('Native event acceptance timed out')


def record_environment(out, runtime, *, session=None):
    out.mkdir(parents=True, exist_ok=True)
    (out / 'environment.txt').write_text(run('xcodebuild', '-version') + '\n' + runtime + '\n')
    (out / 'runtimes.json').write_text(lifecycle(session, 'list', 'runtimes', '-j') + '\n')


def launch_fixture(device, app, *, install=True, session=None):
    """Start a fresh session; the host sends the first stimulus after readiness."""
    run_id = 'fixture-' + str(uuid.uuid4())
    if session is None and os.environ.get('SIM_STATE'):
        session = simulator_infra.Session.resume(os.environ['SIM_STATE'], device, runner=session_transport,
                                               inventory_timeout=60)
    if install:
        install_bound = simulator_infra.seconds(os.environ.get('CKSIM_FIXTURE_INSTALL_TIMEOUT', 180))
        if install_bound > 600:
            raise ValueError('Fixture install bound must not exceed 600 seconds')
        device, applications = install_fixture(device, app, session=session, timeout=install_bound)
    else:
        if session is not None:
            device = session.current
        applications = fixture_applications(device, session=session)
    if session is not None:
        # This slice retries preparation only. Persist the barrier before the
        # original launch, including unknown launch outcomes and process death.
        session.checkpoint()
    launched = run('xcrun', 'simctl', 'launch', '--terminate-running-process', device, BUNDLE,
                   env=dict(os.environ, SIMCTL_CHILD_CKSIM_RUN_ID=run_id))
    match = re.fullmatch(re.escape(BUNDLE) + r': ([1-9][0-9]*)', launched)
    if match is None:
        raise RuntimeError('Missing fixture launch PID acknowledgement')
    return discover_fixture_channel(applications, run_id, int(match[1])), run_id


def inventory_reader(session):
    """One 180s query plus one timeout-only re-attempt per install preparation."""
    retried = False
    def transport(command, timeout, **kwargs):
        nonlocal retried
        recovering = False
        while True:
            result = session_transport(command, timeout, **kwargs)
            if not result.returncode:
                if recovering:
                    simulator_infra.summary('infra:inventory', 'recovered within 180s inventory bound')
                return result
            reason = 'timeout after 180s' if result.timed_out else 'non-timeout failure; never retried'
            eligible = result.timed_out and not retried and result.reaped and not result.cleanup_uncertain
            if eligible and session is not None:
                eligible = not session.is_checkpointed()
                if not eligible:
                    reason += '; never retried after checkpoint evidence'
            if not eligible:
                if result.cleanup_uncertain or not result.reaped:
                    reason += '; owned host cleanup uncertain'
                elif result.timed_out and retried:
                    reason += '; inventory re-attempt exhausted'
                simulator_infra.report_failure('infra:inventory', reason)
                result.failure_classified = True
                return result
            # Spend before a second command; replacement callbacks share this closure.
            retried = True
            recovering = True
            simulator_infra.summary('infra:inventory', reason + '; scheduled one bounded re-attempt')
    def read_devices():
        return lifecycle(session, 'list', 'devices', '-j', timeout=180, executor=transport)
    return read_devices


def fixture_applications(device, *, session=None, cached=None, prepare=False, read_devices=None):
    """Collect metadata before install, then validate the final path locally."""
    device = simulator_infra.simulator_uuid(device)
    if cached is None:
        raw = ((read_devices or inventory_reader(session))() if prepare else
               lifecycle(session, 'list', 'devices', '-j', timeout=60))
        inventory = json.loads(raw)['devices']
        matches = [row for group in inventory.values() for row in group
                   if row.get('udid', '').lower() == device.lower()]
        if len(matches) != 1 or matches[0].get('state') != 'Booted':
            raise RuntimeError('Expected one booted fixture simulator')
        data = Path(matches[0]['dataPath'])
        applications = data / 'Containers/Data/Application'
    else:
        applications = Path(cached)
        if len(applications.parents) < 3 or applications.parts[-3:] != ('Containers', 'Data', 'Application'):
            raise RuntimeError('Invalid cached fixture application directory')
        data = applications.parents[2]
    if not data.is_absolute() or data.name != 'data' or data.parent.name.lower() != device.lower():
        raise RuntimeError('Fixture data path does not match its simulator')
    if not prepare and (not applications.is_dir() or applications.resolve(strict=True) != applications):
        raise RuntimeError('Fixture application directory is missing or noncanonical')
    return applications


def install_fixture(device, app, *, session, timeout, inventory=None):
    """Prepare each actual install, including shared-owner replacement replay."""
    inventory = fixture_applications if inventory is None else inventory
    prepared = {}
    read_devices = inventory_reader(session)
    def before_install(target):
        key = str(target).lower()
        if key not in prepared:
            prepared[key] = inventory(target, session=session, prepare=True, read_devices=read_devices)
    lifecycle(session, 'install', device, app.resolve(), timeout=timeout,
              before_install=before_install)
    if session is not None:
        device = session.current
    cached = prepared.get(str(device).lower())
    if cached is None:
        raise RuntimeError('Missing pre-install inventory for the final fixture simulator')
    return device, fixture_applications(device, session=session, cached=cached)


def discover_fixture_channel(applications, run_id, pid):
    """Bind the launched process through cached host paths, with no native RPC."""
    if not applications.is_dir() or applications.resolve(strict=True) != applications:
        raise RuntimeError('Fixture application directory is missing or noncanonical')
    def discovered():
        found = []
        for container in applications.iterdir():
            try:
                simulator_infra.simulator_uuid(container.name)
                if not container.is_dir() or container.resolve(strict=True) != container:
                    continue
                channel = container / 'Documents/.callkit-simulator'
                published = channel / 'session.json'
                journal = channel / run_id / 'events.jsonl'
                if any(not path.is_file() or path.resolve(strict=True) != path for path in (published, journal)):
                    continue
                row = json.loads(published.read_text())
                if (isinstance(row, dict) and type(row.get('schemaVersion')) is int and row['schemaVersion'] == 1
                        and row.get('runID') == run_id and row.get('bundleID') == BUNDLE
                        and type(row.get('pid')) is int and row['pid'] == pid):
                    found.append(channel)
            except (OSError, ValueError):
                continue
        if len(found) > 1:
            raise RuntimeError('Ambiguous fixture journal identity')
        return found[0] if found else None
    return wait(discovered)


def fixture_session(channel, run_id):
    """Wait separately so the caller retains the channel if startup fails."""
    def ready():
        try:
            session = json.loads((channel / 'session.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None
        return session if session.get('runID') == run_id else None
    return wait(ready)


def capture_diagnostics(out, device, *, bundle=BUNDLE, channel=None, failed=False):
    """Copy the original channel before deleting its simulator, even on failure."""
    try:
        out.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        print('Cannot create diagnostics directory: ' + str(error), file=sys.stderr)
        return
    errors = []
    def attempt(operation):
        try:
            operation()
        except Exception as error:
            errors.append(str(error))
    def journal():
        source = channel
        if source is None:
            raise RuntimeError('No validated fixture channel available for diagnostics')
        shutil.copytree(source, out / 'runtime-journal', dirs_exist_ok=True)
    attempt(journal)
    if failed:
        attempt(lambda: run('xcrun', 'simctl', 'io', device, 'screenshot', out / 'failure.png', timeout=20))
        def logs():
            output = run('xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '5m',
                         '--style', 'compact', '--predicate',
                         'process == "RuntimeEventFixture" OR process == "CKSimInspector"', timeout=20)
            (out / 'simulator.log').write_text(output + '\n')
        attempt(logs)
    if errors:
        try:
            (out / 'diagnostic-errors.txt').write_text('\n'.join(errors) + '\n')
        except OSError as error:
            print('Cannot save diagnostic errors: ' + str(error), file=sys.stderr)


def main(acceptance=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--simulator')
    parser.add_argument('--simulator-state', type=Path, default=os.environ.get('SIM_STATE'))
    parser.add_argument('--runtime', help='Require this exact available simulator runtime identifier')
    args = parser.parse_args()
    args.out.mkdir(parents=True)
    owner = (simulator_infra.Session.resume(args.simulator_state, args.simulator, runner=session_transport,
                                           inventory_timeout=60) if args.simulator_state else
             simulator_infra.Session(args.out / 'simulator-state.json', runner=session_transport)
             if not args.simulator else None)
    runtime = latest_runtime(json.loads(lifecycle(owner, 'list', 'runtimes', '-j'))['runtimes'], args.runtime)
    if owner: record_environment(args.out, runtime, session=owner)
    else: record_environment(args.out, runtime)
    print('Selected simulator runtime: ' + runtime, flush=True)
    device = owner.current if owner else args.simulator
    def sim(*parts, **kwargs):
        nonlocal device
        try: return lifecycle(owner, *parts, **kwargs)
        finally:
            if owner and owner.current: device = owner.current
    def command(*parts):
        result = json.loads(run(ROOT / 'Tools/cksim', '--simulator', device, '--bundle', BUNDLE,
                                '--runtime-dir', args.package.resolve(), '--app-container', str(root.parent.parent), *parts))
        assert result.get('success'), result
        return result
    root = None
    try:
        if not device:
            sim('create', 'Runtime M4 ' + str(uuid.uuid4())[:8],
                'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime)
        # A supplied simulator must also belong to this test run's operator.
        devices = json.loads(sim('list', 'devices', '-j'))['devices']
        state = next(d['state'] for group in devices.values() for d in group if d['udid'] == device)
        if state != 'Booted':
            sim('boot', device)
        sim('bootstatus', device, '-b', timeout=300)
        root, run_id = (launch_fixture(device, args.app, session=owner) if owner else
                        launch_fixture(device, args.app))
        if owner: device = owner.current
        session = fixture_session(root, run_id)
        assert session.get('controlTransport') == 'directory-watch-v1', 'fixture must support spawn-free mailbox controls'
        journal = root / session['runID'] / 'events.jsonl'
        def rows():
            return [json.loads(line) for line in journal.read_text().splitlines()]
        def calls():
            projected = {}
            for row in rows():
                if row['event'] == 'call.changed':
                    projected[row['uuid']] = row
            return [r for r in projected.values() if not r['ended']]
        def state(call, **values):
            return wait(lambda: next((c for c in calls() if c['uuid'] == call and all(c[k] == v for k,v in values.items())), None))
        # A launch timer races slow simctl transport against the ring timeout.
        # Inject only after the host can observe this exact runtime session.
        payload = args.out / 'push.json'
        payload.write_text(json.dumps(dict(operation='incoming')))
        command('push', '--payload-file', payload, '--must-report', 'false')
        first = wait(lambda: calls())[0]['uuid']
        command('answer', first)
        state(first, connected=True)
        wait(lambda: any(r['event'] == 'audio.activated' for r in rows()))
        command('mute', first, '--muted', 'true')
        state(first, muted=True)
        command('tones', first, '--digits', '12#')
        wait(lambda: any(r['event'] == 'action.settled' and not r['fulfilled'] for r in rows()))
        for operation in ('decline', 'hold-and-accept', 'end-and-accept'):
            previous = {c['uuid'] for c in calls()}
            payload.write_text(json.dumps(dict(operation='incoming')))
            command('push', '--payload-file', payload, '--must-report', 'false')
            incoming = wait(lambda: next((c['uuid'] for c in calls() if c['uuid'] not in previous), None))
            command(operation, incoming, *([] if operation == 'decline' else ['--active-call', first]))
            if operation != 'decline':
                state(incoming, connected=True)
                if operation == 'hold-and-accept':
                    state(first, held=True)
                first = incoming
            else:
                wait(lambda: all(c['uuid'] != incoming for c in calls()))
        for call in list(calls()):
            command('end', call['uuid'])
        wait(lambda: not calls())
        payload.write_text(json.dumps(dict(operation='outgoing')))
        command('push', '--payload-file', payload, '--must-report', 'false')
        wait(lambda: any(r['event'] == 'report.connected' for r in rows()))
        for call in list(calls()):
            command('end', call['uuid'])
        wait(lambda: not calls())
        if acceptance is not None:
            acceptance(channel=root, session=session, command=command, rows=rows, wait=wait, out=args.out)
        captured = run(ROOT / 'Tools/cksim', '--simulator', device, '--bundle', BUNDLE,
                       '--app-container', str(root.parent.parent), 'watch', '--json', '--duration', '0.3')
        watched = [json.loads(line) for line in captured.splitlines()]
        assert watched and watched == rows()[:len(watched)], 'watch differs from runtime journal'
        for index, row in enumerate(watched, 1):
            assert row['schemaVersion'] == 1 and row['sequence'] == index
            assert all(row[k] == session[k] for k in ('runID', 'bundleID', 'pid'))
            assert isinstance(row['wallTimeMS'], int)
            if row['event'].startswith('action.'):
                assert all(k in row for k in ('kind','origin','callUUID','transactionID','apiKind','deadlineMS','deadlineSeconds','latencyMS'))
                assert row['latencyMS'] >= 0
            if row['event'] == 'action.settled':
                assert 50 <= row['latencyMS'] < row['deadlineSeconds'] * 1000
        events = {r['event'] for r in watched}
        assert {'report.incoming','report.completed','report.updated','report.connecting','report.connected',
                'action.deadline','action.settled','call.changed','audio.activated','push.received','push.completed'} <= events
        (args.out / 'events.jsonl').write_text(captured + '\n')
        (args.out / 'environment.txt').write_text(run('xcodebuild', '-version') + '\n' + runtime + '\n')
        print(json.dumps(dict(success=True, events=len(watched), channelMatchesWatch=True)))
    finally:
        primary = sys.exc_info()[1]
        capture_diagnostics(args.out, device, channel=root, failed=sys.exc_info()[0] is not None)
        if owner is not None and not args.simulator_state and not args.simulator:
            try:
                result = owner.cleanup(timeout=30)
                if result.returncode: raise CommandError(result, 30)
            except BaseException:
                if primary is None: raise
                simulator_infra.summary('infra:cleanup', 'original product failure retained; ownership remains recorded')


if __name__ == '__main__':
    from filtered_acceptance import run_filtered_acceptance
    main(acceptance=run_filtered_acceptance)
