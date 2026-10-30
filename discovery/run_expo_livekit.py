#!/usr/bin/env python3
"""Run the pinned Expo local-demand fixture on one helper-owned simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

from expo_livekit_conformance import APP_FILES, BUNDLE, CASES, validate, validate_build
from sdk_m0_conformance import ROOT, digest, source_identity
from run_swift_livekit import SimulatorSetup, live, redact, save, wait

sys.path.insert(0, str(ROOT / 'scripts/sim'))
from sim import Interrupted, Result

STARTUP_TIMEOUT_SECONDS = 180


class ExpoSupervisorTimeout(RuntimeError):
    """A matching supervisor receipt already reported this infrastructure failure."""


def reported_timeout(receipt, simulator, run_id, name, supervisor_pid):
    try:
        row = json.loads(receipt.read_text())
        expected = dict(schemaVersion=2, success=False, completed=False, runID=run_id,
                        simulatorID=simulator, bundleID=BUNDLE, scenario=name, supervisorPID=supervisor_pid,
                        inheritLauncherGroup=True, failureReported=True)
        if type(row) is not dict or any(type(row.get(key)) is not type(value) or row[key] != value
                                       for key, value in expected.items()): return None
        reason = row.get('timeoutReason')
        labels = {'startup': 'infra:startup', 'capture': 'infra:capture'}
        if type(reason) is str and reason in labels and row.get('failureClass') == labels[reason]:
            return labels[reason]
    except (OSError, ValueError):
        pass
    return None


class ExpoSetup(SimulatorSetup):
    """The shared lifecycle session delegates only console execution."""
    launch = None

    def execute(self, arguments, timeout):
        if arguments[:3] == ['xcrun', 'simctl', 'launch']:
            if self.launch is None: raise RuntimeError('unexpected Expo launch')
            return self.launch(arguments, timeout)
        return super().execute(arguments, timeout)


def bound_paths(trace, simulator, run_id, case, devices_root=None):
    rows = live(trace)
    if len(rows) < 2: return None
    entry, launch = rows[:2]
    pid = entry.get('pid')
    expected = dict(runID=run_id, simulatorID=simulator, bundleID=BUNDLE, pid=pid)
    if (type(pid) is not int or pid <= 0 or entry.get('event') != 'app.entry' or
            launch.get('event') != 'launch' or launch.get('mode') != 'sdk-m2' or launch.get('case') != case or
            any(type(row.get(key)) is not type(value) or row[key] != value
                for row in (entry, launch) for key, value in expected.items())):
        raise RuntimeError('fresh Expo launch identity differs')
    headers = re.findall(rb'(?m)^' + re.escape(BUNDLE.encode()) + rb': (\d+)\r?$', trace.read_bytes())
    # The completed receipt/oracle requires the sole native acknowledgement.
    # Live console output may not flush that header until the app stops.
    if headers and headers != [str(pid).encode()]:
        raise RuntimeError('native launcher PID acknowledgement differs')
    devices = Path(devices_root).absolute() if devices_root is not None else (
        Path.home() / 'Library/Developer/CoreSimulator/Devices')
    paths = []
    for key, kind in (('dataContainer', 'Data'), ('bundlePath', 'Bundle')):
        raw = launch.get(key)
        if not isinstance(raw, str) or not raw: raise RuntimeError('published Expo path is missing')
        path = Path(raw)
        parent = path.parent if kind == 'Data' else path.parent.parent
        expected_parent = devices / simulator / 'data/Containers' / kind / 'Application'
        if (not path.is_absolute() or str(path) != raw or '..' in path.parts or
                parent != expected_parent or
                not path.is_dir() or path.resolve(strict=True) != path):
            raise RuntimeError('published Expo path is not canonical for the owned simulator')
        name = path.name if kind == 'Data' else path.parent.name
        if str(uuid.UUID(name)).casefold() != name.casefold():
            raise RuntimeError('published Expo container UUID is not canonical')
        paths.append(path)
    return pid, *paths


def require_group_absent(pid):
    try: os.killpg(pid, 0)
    except ProcessLookupError: return
    raise RuntimeError('owned supervisor/console group remains or cleanup is unknown')


def stop_remaining_group(pid):
    # Popen(start_new_session=True) established this private group before exec.
    # The console may outlive its leader; leader exit does not relinquish it.
    try: require_group_absent(pid); return False
    except RuntimeError: pass
    try: os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError: pass
    deadline = time.monotonic() + 5
    while True:
        try: require_group_absent(pid); return True
        except RuntimeError:
            if time.monotonic() >= deadline: raise
            time.sleep(.025)


def atomic_json(path, value):
    """Publish complete mailbox/fixture documents with a private atomic rename."""
    temporary = path.with_name(path.name + '.' + str(uuid.uuid4()) + '.tmp')
    try:
        with temporary.open('x') as stream:
            os.chmod(temporary, 0o600)
            json.dump(value, stream); stream.write('\n')
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def canonical(path, directory=False):
    if ((not path.is_dir() if directory else not path.is_file()) or path.resolve(strict=True) != path):
        raise RuntimeError('bound Expo control path is missing or noncanonical')
    return path


def stale_audio(process, trace, data, out, run_id, pid):
    """Configure the native mailbox before releasing the fixture's push barrier."""
    if type(pid) is not int or pid <= 0 or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', run_id):
        raise RuntimeError('invalid Expo fault process/run identity')
    name = 'expo-livekit-stale-audio'
    root = data / 'Documents/.callkit-simulator'
    expected = dict(schemaVersion=1, runID=run_id, pid=pid, bundleID=BUNDLE, profile='ios-27.0',
                    controlTransport='directory-watch-v1')
    def current_session():
        path = root / 'session.json'
        if not path.exists(): return None
        session = json.loads(canonical(path).read_text())
        # The healthy launch used the same installation/run. Wait for this
        # process's native bootstrap to replace its predecessor's session.
        if type(session) is dict and (session.get('runID') != run_id or session.get('pid') != pid): return None
        if (type(session) is not dict or set(session) != set(expected) or
                any(type(session[key]) is not type(value) or session[key] != value for key, value in expected.items())):
            raise RuntimeError('fresh Expo runtime control session differs')
        return session
    session = wait(process, current_session, 10)
    runtime = canonical(root / run_id, directory=True)
    requests = canonical(runtime / 'requests', directory=True)
    responses = canonical(runtime / 'responses', directory=True)
    temporary_directory = canonical(data / 'tmp', directory=True)
    ready_path = temporary_directory / ('sdk-m2-control-' + run_id + '.json')
    if ready_path.exists() or ready_path.is_symlink(): raise RuntimeError('Expo fault readiness already exists')
    rows = live(trace)
    if (len(rows) < 2 or type(rows[0].get('wallTimeMS')) is not int or rows[0]['wallTimeMS'] <= 0 or
            any(row.get('event') in ('m2.controlReady', 'm2.pushInjected') for row in rows)):
        raise RuntimeError('Expo fault control did not precede the fixture push')
    save(out / (name + '.session.json'), session)
    request = dict(id=str(uuid.uuid4()).upper(), runID=run_id, pid=pid, bundleID=BUNDLE, operation='faults',
                   faults=dict(staleAudio=True, reportCallbackDelayMS=0, invalidateDuringHandoff=False))
    response_path = responses / (request['id'] + '.json')
    if response_path.exists() or response_path.is_symlink(): raise RuntimeError('Expo fault nonce already exists')
    save(out / (name + '.request.json'), request)
    atomic_json(requests / (request['id'] + '.json'), request)
    def acknowledged():
        if not response_path.exists(): return None
        response = json.loads(canonical(response_path).read_text())
        result = response.get('result') if type(response) is dict else None
        identity = dict(id=request['id'], runID=run_id, pid=pid, bundleID=BUNDLE, success=True)
        if (type(response) is not dict or set(response) != {*identity, 'result'} or
                any(type(response.get(key)) is not type(value) or response[key] != value for key, value in identity.items()) or
                type(result) is not dict or result.get('configured') is not True or
                type(result.get('incomingErrorCode', 0)) is not int or result.get('incomingErrorCode', 0) != 0):
            raise RuntimeError('Expo fault ACK differs')
        return response
    response = wait(process, acknowledged, 10)
    acknowledged_at = time.time_ns() // 1_000_000
    if acknowledged_at < rows[0]['wallTimeMS'] or any(
            row.get('event') in ('m2.controlReady', 'm2.pushInjected') for row in live(trace)):
        raise RuntimeError('Expo matching fault ACK must precede readiness and push')
    save(out / (name + '.response.json'), response)
    ready = dict(runID=run_id, case='stale-audio', pid=pid, staleAudio=True,
                 requestID=request['id'], acknowledgedWallTimeMS=acknowledged_at)
    atomic_json(out / (name + '.ready.json'), ready)
    atomic_json(ready_path, ready)


def scenario(setup, build, out, case, run_id, inherited, arguments, timeout):
    if case not in CASES or timeout != 120 or arguments != ['xcrun', 'simctl', 'launch', '--console',
            '--terminate-running-process', setup.current, BUNDLE]:
        raise RuntimeError('unexpected Expo console launch')
    name = 'expo-livekit-' + case
    trace, receipt = out / (name + '.log'), out / (name + '.receipt.json')
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('SIMCTL_CHILD_SDK_', 'SIMCTL_CHILD_CKSIM_'))}
    env.update(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=inherited, SIMCTL_CHILD_CKSIM_RUN_ID=run_id,
               SIMCTL_CHILD_SDK_M2_RUN_ID=run_id, SIMCTL_CHILD_SDK_M2_CASE=case,
               SIM_FAILURE_MARKER=os.environ.get('SIM_FAILURE_MARKER') or str(setup.state_path) + '.failure')
    terminate = [sys.executable, str(ROOT / 'scripts/sim/sim.py'), 'call', str(setup.state_path), '5',
                 'xcrun', 'simctl', 'terminate', setup.current, BUNDLE]
    argv = [sys.executable, ROOT / 'discovery/run_scenario.py', '--console-launcher-stop', '--inherit-launcher-group',
            '--startup-timeout', str(STARTUP_TIMEOUT_SECONDS), '--timeout', str(timeout),
            '--output', trace, '--receipt', receipt, '--run-id', run_id,
            '--simulator-id', setup.current, '--scenario', name, '--bundle-id', BUNDLE,
            '--terminate-command', *terminate, '--launch-command', *arguments]
    primary = None
    with (out / (name + '.supervisor.log')).open('xb') as log:
        process = subprocess.Popen(list(map(str, argv)), env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        # A timeout receipt may classify a supervisor wait, never a validation
        # error from its binding predicate or the subsequent product checks.
        stage = 'binding-wait'
        def binding_paths():
            nonlocal stage
            try: return bound_paths(trace, setup.current, run_id, case)
            except BaseException:
                stage = 'binding-validation'
                raise
        try:
            # The supervisor alone starts capture at identity-bound app.entry and
            # rejects late entries/terminal events. This outer watchdog also
            # allows its existing 40-second stop/receipt margin, even when no
            # paths appear; it cannot qualify a late native capture as success.
            pid, data, installed = wait(process, binding_paths, STARTUP_TIMEOUT_SECONDS + timeout + 40)
            stage = 'validation'
            hashes = {key: digest(installed / Path(key).relative_to('example.app')) for key in APP_FILES}
            expected = validate_build(build)['files']
            if hashes != {key: expected[key] for key in APP_FILES}:
                raise RuntimeError('installed consumer bytes differ from bound build')
            if case == 'stale-audio': stale_audio(process, trace, data, out, run_id, pid)
            stage = 'supervisor-exit'
            if process.wait(timeout=160): raise RuntimeError('Expo supervisor refused native capture')
        except BaseException as error:
            label = (reported_timeout(receipt, setup.current, run_id, name, process.pid)
                     if stage in ('binding-wait', 'supervisor-exit') and isinstance(error, Exception)
                     and not isinstance(error, Interrupted) else None)
            if label:
                primary = ExpoSupervisorTimeout('Expo supervisor refused native capture: ' + label)
                raise primary from error
            primary = error
            raise
        finally:
            handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
            errors = []
            try:
                if process.poll() is None:
                    try: setup.call(['xcrun', 'simctl', 'terminate', setup.current, BUNDLE], 10)
                    except BaseException as error: errors.append(error)
                    try: process.wait(timeout=25)
                    except subprocess.TimeoutExpired:
                        try:
                            if process.poll() is None:
                                if os.getpgid(process.pid) != process.pid or os.getsid(process.pid) != process.pid:
                                    raise RuntimeError('supervisor private process-group ownership is unknown')
                                try: os.killpg(process.pid, signal.SIGKILL)
                                except ProcessLookupError: pass
                        finally: process.wait(timeout=5)
                if stop_remaining_group(process.pid): process.wait(timeout=5)
            except BaseException as error:
                errors.append(error)
            finally:
                for sig, handler in handlers.items(): signal.signal(sig, handler)
            if errors:
                if primary is None: raise errors[0]
                print('Expo supervisor cleanup also failed: ' + type(errors[0]).__name__, file=sys.stderr)
    journal = data / 'Documents/.callkit-simulator' / run_id / 'events.jsonl'
    if not journal.is_file() or journal.resolve(strict=True) != journal:
        raise RuntimeError('bound Expo runtime journal is missing or noncanonical')
    shutil.copyfile(journal, out / (name + '.runtime.jsonl'))
    row = json.loads(receipt.read_text())
    if row.get('appPID') != pid or row.get('supervisorPID') != process.pid:
        raise RuntimeError('completed Expo capture changed process identity')
    row['journalSHA256'] = digest(out / (name + '.runtime.jsonl'))
    save(receipt, row)
    return process.pid, hashes


def run(build, out, setup_factory=ExpoSetup):
    if 'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES' not in os.environ:
        raise RuntimeError('provide SIMCTL_CHILD_DYLD_INSERT_LIBRARIES explicitly for this isolated runner')
    before = source_identity()
    validate_build(build)
    if any(key.startswith('SIMCTL_CHILD_CKSIM_') and value for key, value in os.environ.items()):
        raise RuntimeError('plain acceptance refuses inherited runtime overrides')
    out.mkdir(parents=True, exist_ok=False)
    setup = setup_factory(out)
    inherited, simulator, primary = '', None, None
    run_id = str(uuid.uuid4()).upper()
    try:
        rows = json.loads(setup.call(['xcrun', 'simctl', 'list', 'runtimes', '-j'], 180).stdout)['runtimes']
        available = [row for row in rows if row.get('identifier') == 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
                     and row.get('isAvailable') and row.get('platform') == 'iOS' and row.get('version') == '27.0']
        if len(available) != 1: raise RuntimeError('the exact iOS 27.0 simulator runtime is required')
        runtime = {key: available[0][key] for key in ('identifier', 'version', 'buildversion')}
        setup.call(['xcrun', 'simctl', 'create', 'expo-livekit-' + run_id,
                    'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime['identifier']], 30)
        setup.call(['xcrun', 'simctl', 'boot', setup.current], 60)
        setup.call(['xcrun', 'simctl', 'bootstatus', setup.current, '-b'], 300)
        setup.call(['xcrun', 'simctl', 'install', setup.current, str(build / 'example.app')], 180)
        setup.call(['xcrun', 'simctl', 'privacy', setup.current, 'grant', 'microphone', BUNDLE], 180)
        inherited = setup.environment()
        simulator = setup.current
        setup.checkpoint()
        supervisors, installed = {}, None
        for case in CASES:
            observed = []
            def capture(arguments, timeout):
                try:
                    observed.append(scenario(setup, build, out, case, run_id, inherited, arguments, timeout))
                except ExpoSupervisorTimeout:
                    # Session must preserve the supervisor's reported infra label.
                    return Result(arguments, 1, failure_classified=True)
                return Result(arguments, 0)
            setup.launch = capture
            setup.call(['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', simulator, BUNDLE], 120)
            if len(observed) != 1: raise RuntimeError('require exactly one helper-supervised Expo launch')
            supervisors[case], hashes = observed[0]
            if installed is not None and installed != hashes: raise RuntimeError('installed consumer changed between cases')
            installed = hashes
    except BaseException as error:
        primary = error
        raise
    finally:
        handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
        errors = []
        try:
            try:
                setup.cleanup(simulator)
                if (out / 'cleanup.json').exists():
                    cleanup = json.loads((out / 'cleanup.json').read_text())
                    cleanup['absent'] = True  # Shared setup verified independent post-delete inventory.
                    save(out / 'cleanup.json', cleanup)
                elif simulator is not None or setup.owned_devices:
                    raise RuntimeError('owned Expo simulator cleanup metadata is missing')
            except BaseException as error: errors.append(error)
            for value in (*getattr(setup, 'redaction_values', ()), inherited):
                try: redact(out, value)
                except BaseException as error: errors.append(error)
        finally:
            for sig, handler in handlers.items(): signal.signal(sig, handler)
        if errors:
            if primary is None: raise errors[0]
            print('Expo simulator cleanup also failed: ' + type(errors[0]).__name__, file=sys.stderr)
    if source_identity() != before: raise RuntimeError('source changed during native capture')
    save(out / 'capture.json', dict(schemaVersion=1, source=before, runID=run_id, simulatorID=simulator,
         runtime=runtime, installed=installed, buildSHA256=digest(build / 'build.json'), supervisorPIDs=supervisors,
         supervisorGroupsAbsent=dict.fromkeys(supervisors, True), inheritedExternalDYLD=dict(
             present=bool(inherited), sha256=hashlib.sha256(inherited.encode()).hexdigest())))
    result = validate(build, out)
    print(json.dumps(result, indent=2))
    return result


def interrupted(signum, _frame):
    raise Interrupted(signum)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run(args.build.resolve(), args.output.absolute())
