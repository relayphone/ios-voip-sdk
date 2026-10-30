#!/usr/bin/env python3
"""Two real Swift engine modes on exactly one new owned simulator, without injection."""
import argparse
from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

from build_swift_livekit_contract import ROOT, digest, save, source
from summarize import one, require, selected_runtime
from run_scenario import HostTiming
from swift_livekit_conformance import BUNDLE, CASES, CLASSIFICATION, validate, validate_build, published_container

sys.path.insert(0, str(ROOT / 'scripts/sim'))
import sim as simulator_infra

SCENARIO_TIMEOUT_SECONDS = 90
STARTUP_TIMEOUT_SECONDS = 180
SUPERVISOR_FINALIZATION_SECONDS = 40
PRIVACY_TIMEOUT_SECONDS = 180
REPORTER = ContextVar('swift_livekit_failure_reporter', default=None)


class FailureReporter:
    """Native entry labels; low-level host controls never write the job summary."""
    def __init__(self, out, enabled):
        self.enabled, self.errors = enabled, []
        self.marker = Path(os.environ.get('SIM_FAILURE_MARKER') or str(out) + '.failure-classified')

    def known(self, error):
        return any(previous is error for previous in self.errors)

    def marker_identity(self):
        try:
            value = self.marker.stat()
            return value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns
        except OSError: return None

    def mark(self, error):
        if not self.known(error): self.errors.append(error)
        if self.enabled:
            try: self.marker.touch()
            except OSError: simulator_infra.summary('infra:evidence-write', 'classification marker unavailable')

    def report(self, label, error):
        if self.known(error): return
        if cancelled(error) and label != 'infra:launch': label = 'infra:runner-cancelled'
        if self.enabled:
            try: simulator_infra.summary(label, 'never retried' if label.startswith('product:') else 'not eligible')
            except OSError: simulator_infra.summary('infra:evidence-write', 'job summary unavailable')
        self.mark(error)

    @contextmanager
    def context(self):
        previous = {key: os.environ.get(key) for key in ('GITHUB_STEP_SUMMARY', 'SIM_FAILURE_MARKER')}
        token = REPORTER.set(self)
        try:
            if self.enabled:
                os.environ['SIM_FAILURE_MARKER'] = str(self.marker)
            else:
                for key in previous: os.environ.pop(key, None)
            yield
        finally:
            REPORTER.reset(token)
            for key, value in previous.items():
                if value is None: os.environ.pop(key, None)
                else: os.environ[key] = value


def cancelled(error):
    return (isinstance(error, (KeyboardInterrupt, simulator_infra.Interrupted)) or
            isinstance(error, SystemExit) and error.code in (130, 143))


@contextmanager
def failure_boundary(label):
    try: yield
    except BaseException as error:
        reporter = REPORTER.get()
        if reporter is not None: reporter.report(label, error)
        raise


class NativeCommandError(OSError):
    """Distinguish executor failure from an operation evidence write failure."""


def evidence(action, errors=None):
    try:
        with failure_boundary('infra:evidence-write'): return action()
    except OSError as error:
        if errors is None: raise
        errors.append(error)


def record_command(out, label, stdout, stderr, status, errors):
    for suffix, data in (('.stdout', b'' if label == 'launch-environment' else stdout), ('.stderr', stderr)):
        evidence(lambda: (out / (label + suffix)).write_bytes(data), errors)
    evidence(lambda: save(out / (label + '.status.json'), status), errors)


def command(out, label, arguments, timeout=60, check=True, env=None, *, evidence_errors=None):
    arguments = [str(value) for value in arguments]
    transport = {'runtimes': 'runtime-inventory', 'devices-after': 'post-delete-inventory'}.get(label, arguments[2])
    started = time.monotonic()
    try:
        try: result = simulator_infra.bounded(arguments, timeout, env=env)
        except OSError as error: raise NativeCommandError(str(error)) from error
        if result.timed_out:
            raise subprocess.TimeoutExpired(arguments, timeout, output=result.stdout, stderr=result.stderr)
    except (subprocess.TimeoutExpired, NativeCommandError) as error:
        if check and evidence_errors is not None: evidence_errors.append(error)
        if check and REPORTER.get() is not None: REPORTER.get().report('infra:' + transport, error)
        record_command(out, label, getattr(error, 'stdout', None) or b'', getattr(error, 'stderr', None) or b'',
                       dict(exitCode=None, error=str(error), timeoutSeconds=timeout,
                            elapsedSeconds=round(time.monotonic() - started, 6)),
                       [] if check and evidence_errors is None else evidence_errors)
        raise
    status_error = None
    if check:
        try:
            with failure_boundary('infra:' + transport):
                require(result.returncode == 0, label + ' failed: ' + str(result.returncode))
        except BaseException as error:
            status_error = error
            if evidence_errors is not None: evidence_errors.append(error)
    # The current launchd value is passed to app launches only in memory.
    record_command(out, label, result.stdout, result.stderr,
                   dict(exitCode=result.returncode, timeoutSeconds=timeout,
                        elapsedSeconds=round(time.monotonic() - started, 6)),
                   [] if status_error is not None and evidence_errors is None else evidence_errors)
    if status_error is not None: raise status_error
    return result


class OwnedSession(simulator_infra.Session):
    def __init__(self, *arguments, evidence_scope, on_cleanup_error, **options):
        self.evidence_scope, self.on_cleanup_error = evidence_scope, on_cleanup_error
        super().__init__(*arguments, **options)

    # Replacement cleanup must retain this runner's original 60-second bound.
    def cleanup(self, timeout=60, final=True):
        with self.evidence_scope():
            try: return super().cleanup(timeout=timeout, final=final, on_error=self.on_cleanup_error)
            except Exception as error:
                reporter = REPORTER.get()
                if reporter is not None:
                    if getattr(error, 'failure_classified', False): reporter.mark(error)
                    elif isinstance(error, OSError): reporter.report('infra:evidence-write', error)
                raise


class SimulatorSetup:
    """Keep native operation evidence across the helper's one setup retry."""
    def __init__(self, out):
        self.out, self.archive_sequence = out, 0
        self.owned_devices, self.redaction_values = set(), []
        self.evidence_errors = None
        state = out / 'simulator-state'
        state.mkdir()
        self.state_path = state / 'owner.json'
        self.session = self.owned_session()

    def owned_session(self):
        return OwnedSession(self.state_path, runner=self.execute, recovery_timeout=60,
                            evidence_scope=self.teardown_evidence, on_cleanup_error=self.cleanup_error)

    def cleanup_error(self, error):
        self.evidence_errors.append(error)

    @contextmanager
    def teardown_evidence(self):
        if self.evidence_errors is not None:
            yield
            return
        self.evidence_errors = errors = []
        try:
            try: yield
            except BaseException as error:
                if not errors: raise
                raise errors[0] from error
            if errors: raise errors[0]
        finally:
            self.evidence_errors = None

    @property
    def current(self):
        return self.session.current

    def archive(self, label):
        previous = [self.out / (label + suffix) for suffix in ('.stdout', '.stderr', '.status.json')]
        previous = [path for path in previous if path.exists()]
        if previous:
            with failure_boundary('infra:evidence-write'):
                self.archive_sequence += 1
                target = self.out / 'infrastructure-attempts' / f'{self.archive_sequence:03d}-{label}'
                target.mkdir(parents=True)
                for path in previous:
                    path.rename(target / path.name)

    def recorded(self, label, arguments, timeout=60, env=None):
        evidence(lambda: self.archive(label), self.evidence_errors)
        return command(self.out, label, arguments, timeout, check=False, env=env,
                       evidence_errors=self.evidence_errors)

    def execute(self, arguments, timeout):
        step = arguments[2]
        label = {'privacy': 'microphone', 'list': 'creation-recovery'}.get(step, step)
        if step in ('shutdown', 'delete'):
            self.owned_devices.add(str(uuid.UUID(arguments[3])).upper())
        try:
            result = self.recorded(label, arguments, timeout)
        except subprocess.TimeoutExpired as error:
            return simulator_infra.Result(arguments, 124, error.stdout or b'', error.stderr or b'', timed_out=True)
        except NativeCommandError as error:
            return simulator_infra.Result(arguments, 127, stderr=str(error).encode())
        if step == 'create' and result.returncode == 0:
            try: self.owned_devices.add(str(uuid.UUID(result.stdout.decode().strip())).upper())
            except (ValueError, UnicodeDecodeError): pass  # Session rejects malformed ownership.
        return result

    def call(self, arguments, timeout):
        with failure_boundary('infra:' + arguments[2]):
            try: result = self.session.call([str(value) for value in arguments], timeout)
            except OSError as error:
                # Native executor errors become Results; raw errors here are evidence I/O.
                if REPORTER.get() is not None: REPORTER.get().report('infra:evidence-write', error)
                raise
            try: require(result.returncode == 0, arguments[2] + ' failed: ' + str(result.returncode))
            except BaseException as error:
                # Session already emitted the terminal retry result, not just a warning.
                if REPORTER.get() is not None: REPORTER.get().mark(error)
                raise
            return result

    def remember(self, raw):
        value = os.fsdecode(raw).removesuffix('\n') if isinstance(raw, bytes) else raw
        self.redaction_values.append(value)
        return value

    def environment(self):
        with failure_boundary('infra:launch-environment'):
            return self.read_environment()

    def read_environment(self):
        configured = os.environ.get('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES')
        if configured is None:
            try:
                result = self.recorded('launch-environment', ['xcrun', 'simctl', 'spawn', self.current, 'launchctl',
                    'getenv', 'DYLD_INSERT_LIBRARIES'], timeout=180,
                    env={**os.environ, 'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': ''})
            except subprocess.TimeoutExpired as error:
                self.remember(error.stdout or b'')
                raise
            self.remember(result.stdout)
            require(result.returncode in (0, 1) and not result.stderr and
                    (result.returncode == 0 or not result.stdout), 'cannot read inherited launch environment')
            inherited = result.stdout.decode().removesuffix('\n')
        else:
            inherited = self.remember(configured)
        require(not any(Path(value).name in ('CKSimRuntime.dylib', 'CKSimLoader.dylib') for value in inherited.split(':')),
                'external SDK runtime injection refused')
        require(not any(key.startswith('SIMCTL_CHILD_CKSIM_') and value for key, value in os.environ.items()),
                'inherited runtime child override refused')
        with failure_boundary('infra:evidence-write'):
            save(self.out / 'inherited-dyld.json', dict(present=bool(inherited), sha256=hashlib.sha256(inherited.encode()).hexdigest()))
        return inherited

    def checkpoint(self):
        # A compatible child may have updated the same ownership/retry record.
        self.session = self.owned_session()
        self.session.checkpoint()

    def cleanup(self, simulator):
        def metadata():
            aggregate = self.state_path.with_name('cleanup.json')
            if aggregate.exists():
                value = json.loads(aggregate.read_text())
                codes = {label: json.loads((self.out / (label + '.status.json')).read_text()).get('exitCode')
                         if (self.out / (label + '.status.json')).exists() else None for label in ('shutdown', 'delete')}
                save(self.out / 'cleanup.json', dict(simulatorID=simulator or value['simulatorID'],
                    shutdownExitCode=codes['shutdown'], deleteExitCode=codes['delete'],
                    deleted=value['deleted'] and codes['delete'] == 0))

        with self.teardown_evidence():
            def attempt(action, label='infra:evidence-write'):
                try:
                    with failure_boundary(label): return action()
                except BaseException as error: self.evidence_errors.append(error)

            refreshed = attempt(self.owned_session)
            if refreshed is not None: self.session = refreshed
            result = attempt(lambda: self.session.cleanup(timeout=60), 'infra:cleanup')
            attempt(metadata)
            # This independent inventory remains mandatory after any helper,
            # recording or metadata failure; errors are raised after all checks.
            try:
                with failure_boundary('infra:post-delete-inventory'):
                    remaining = command(self.out, 'devices-after', ['xcrun', 'simctl', 'list', 'devices', '-j'],
                                        evidence_errors=self.evidence_errors)
                    rows = json.loads(remaining.stdout)['devices']
                    require(not any(str(row.get('udid', '')).upper() in self.owned_devices
                        for values in rows.values() for row in values), 'owned simulator cleanup/absence failed')
                evidence(lambda: (self.out / 'devices-after.json').write_bytes(remaining.stdout), self.evidence_errors)
            except BaseException as error: self.evidence_errors.append(error)
            if result is not None:
                try: require(result.returncode == 0, 'owned simulator cleanup/absence failed')
                except BaseException as error:
                    if REPORTER.get() is not None: REPORTER.get().mark(error)
                    self.evidence_errors.append(error)



def live(path):
    if not path.exists(): return []
    return [json.loads(line.split(b'PROBE ', 1)[1]) for line in path.read_bytes().splitlines(keepends=True)
            if line.endswith(b'\n') and b'PROBE ' in line]


def wait(process, condition, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = condition()
        if value: return value
        require(process.poll() is None, 'supervisor exited before fixture checkpoint')
        time.sleep(.025)
    raise RuntimeError('fixture checkpoint deadline')


def fault(out, build, simulator, runtime, session):
    require(session.get('controlTransport') == 'directory-watch-v1', 'unsupported runtime control transport')
    # The runtime watches this atomic rename; no simulator wake RPC is needed.
    request = {key: session[key] for key in ('runID', 'pid', 'bundleID')}
    request.update(id=str(uuid.uuid4()).upper(), operation='faults',
                   faults=dict(staleAudio=True, reportCallbackDelayMS=0, invalidateDuringHandoff=False))
    save(out / 'fault-request.json', request)
    temporary = runtime / 'requests' / (request['id'] + '.tmp')
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600); json.dump(request, stream)
    temporary.rename(temporary.with_suffix('.json'))
    return runtime / 'responses' / (request['id'] + '.json')


def capture_case(build, out, simulator, inherited, mode, expected_container=None):
    run_id = str(uuid.uuid4()); trace, receipt = out / (mode + '.log'), out / (mode + '.receipt.json')
    runtime = None
    env = {key: value for key, value in os.environ.items() if not key.startswith('SIMCTL_CHILD_')}
    env.update(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=inherited, SIMCTL_CHILD_CKSIM_RUN_ID=run_id,
               SIMCTL_CHILD_SDK_SWIFT_LIVEKIT_CASE=mode)
    argv = [sys.executable, ROOT / 'discovery/run_scenario.py', '--console-launcher-stop', '--inherit-launcher-group', '--startup-timeout', str(STARTUP_TIMEOUT_SECONDS), '--timeout', str(SCENARIO_TIMEOUT_SECONDS),
            '--output', trace, '--receipt', receipt, '--run-id', run_id, '--simulator-id', simulator,
            '--scenario', mode, '--bundle-id', BUNDLE, '--terminate-command', 'xcrun', 'simctl', 'terminate', simulator, BUNDLE,
            '--launch-command', 'xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', simulator, BUNDLE]
    with HostTiming(trace, 'driver', BUNDLE) as timing, (out / (mode + '.supervisor.log')).open('xb') as log:
        def observed():
            rows = live(trace)
            try:
                for row in rows: timing.observe_row(row, 'poll')
            except Exception:
                pass  # Diagnostics cannot replace these strictly parsed product rows.
            return rows
        timing.record('supervisor.spawn.start')
        process = subprocess.Popen([str(value) for value in argv], env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        timing.record('supervisor.spawn.end', pid=process.pid)
        cleanup_required = False
        try:
            launch_watchdog = STARTUP_TIMEOUT_SECONDS + SCENARIO_TIMEOUT_SECONDS + SUPERVISOR_FINALIZATION_SECONDS
            launch = timing.checkpoint('launch', lambda: wait(process, lambda: next((row for row in observed() if row['event'] == 'launch'), None), launch_watchdog), launch_watchdog)
            entry = one(observed(), 'app.entry')
            require(all(entry.get(key) == launch.get(key) for key in ('runID', 'pid', 'bundleID', 'simulatorID')),
                    'fresh entry/launch identity differs')
            container = published_container(launch, simulator, run_id, entry.get('pid'), mode,
                                            digest(build / 'SDKSwiftLiveKit.app/SDKSwiftLiveKit'))
            require(expected_container is None or str(container) == expected_container,
                    'fresh launch changed installation container')
            try:
                require(container.resolve(strict=True) == container and container.is_dir(),
                        'published container is missing or symlinked')
            except OSError:
                require(False, 'published container is missing or symlinked')
            root = container / 'Documents/.callkit-simulator'
            session = timing.checkpoint('runtime.session', lambda: wait(process, lambda: json.loads((root / 'session.json').read_text())
                if (root / 'session.json').exists() and json.loads((root / 'session.json').read_text()).get('runID') == run_id else None, 15), 15)
            require(session.get('runID') == run_id and session.get('pid') == launch['pid'] and session.get('bundleID') == BUNDLE and
                    session.get('controlTransport') == 'directory-watch-v1' and
                    session.get('profile') == 'ios-27.0', 'fresh runtime session differs')
            runtime = root / run_id
            save(out / (mode + '.session.json'), session)
            if mode == 'stale-audio':
                timing.checkpoint('readyForFault', lambda: wait(process, lambda: any(row['event'] == 'livekit.readyForFault' for row in observed()), 15), 15)
                response = fault(out, build, simulator, runtime, session)
                timing.checkpoint('fault.response', lambda: wait(process, response.exists, 10), 10)
                shutil.copyfile(response, out / 'fault-response.json')
            require(process.wait(timeout=SCENARIO_TIMEOUT_SECONDS + SUPERVISOR_FINALIZATION_SECONDS) == 0, 'supervisor refused native capture')
        finally:
            timing.record('cleanup.start')
            handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
            try:
                if process.poll() is None:
                    cleanup_required = True
                    diagnostic = dict(supervisorPID=process.pid, forcedGroupKill=False)
                    try:
                        command(out, mode + '-failed-stop', ['xcrun', 'simctl', 'terminate', simulator, BUNDLE],
                                timeout=10, check=False)
                    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                        diagnostic['appStopError'] = str(error)
                    try:
                        process.wait(timeout=25)
                    except subprocess.TimeoutExpired:
                        # The opt-in helper verifies its launcher inherits this
                        # private group. Never signal a group after owner reap.
                        try:
                            if process.poll() is None:
                                require(os.getpgid(process.pid) == process.pid == os.getsid(process.pid),
                                        'supervisor private process-group ownership is unknown')
                                try:
                                    os.killpg(process.pid, signal.SIGKILL)
                                    diagnostic['forcedGroupKill'] = True
                                except ProcessLookupError:
                                    pass
                        finally:
                            process.wait(timeout=5)
                    save(out / (mode + '-failed-cleanup.json'), diagnostic)
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    group_absent = True
                else:
                    group_absent = False
                require(group_absent, 'supervisor/console group remains or cleanup is unknown')
                if receipt.exists():
                    value = json.loads(receipt.read_text()); value['supervisorGroupAbsentAfterStop'] = True
                    save(receipt, value)
                journal = runtime / 'events.jsonl' if runtime is not None else None
                if journal is not None and journal.exists():
                    shutil.copyfile(journal, out / (mode + '.runtime.jsonl'))
                    if receipt.exists():
                        value = json.loads(receipt.read_text()); value['journalSHA256'] = digest(out / (mode + '.runtime.jsonl'))
                        save(receipt, value)
            finally:
                for sig, handler in handlers.items(): signal.signal(sig, handler)
                timing.record('cleanup.end', returncode=getattr(process, 'returncode', None))
        require(not cleanup_required, 'failure cleanup cannot qualify a native journey')
    return dict(runID=run_id, pid=launch['pid'], supervisorPID=process.pid, dataContainer=str(container))



def redact(out, inherited):
    for path in out.rglob('*'):
        if not path.is_file() or path.suffix not in ('.log', '.stdout', '.stderr'): continue
        raw = data = path.read_bytes()
        for value in filter(None, inherited.split(':')): data = data.replace(value.encode(errors='surrogateescape'), b'<inherited-external-library>')
        if data == raw: continue
        path.write_bytes(data)
        receipt = path.with_suffix('.receipt.json')
        if receipt.exists():
            row = json.loads(receipt.read_text())
            row.update(unredactedTraceSHA256=row['traceSHA256'], traceSHA256=digest(path), externalLibraryPathsRedacted=True)
            save(receipt, row)


def capture(build, out, *, classify=False):
    with FailureReporter(out, classify).context():
        return capture_owned(build, out)


def capture_owned(build, out):
    with failure_boundary('product:swift-livekit-build'): validate_build(build)
    with failure_boundary('infra:evidence-write'): out.mkdir()
    simulator = None; inherited = ''; name = 'sdk-swift-livekit-' + str(uuid.uuid4())
    with failure_boundary('infra:evidence-write'): setup = SimulatorSetup(out)
    cases = {}; primary = None
    # One shared pre-app budget covers create, boot, install and privacy grant.
    try:
        with failure_boundary('infra:runtime-inventory'):
            runtimes = json.loads(command(out, 'runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j']).stdout)
        with failure_boundary('infra:runtime-selection'):
            runtime = selected_runtime(runtimes, os.environ.get('SDK_SWIFT_LIVEKIT_RUNTIME'))
            require(int(runtime['version'].split('.')[0]) >= 27, 'an iOS 27+ simulator runtime is required')
        with failure_boundary('infra:evidence-write'):
            save(out / 'runtime.json', {key: runtime[key] for key in ('identifier', 'version', 'buildversion')})
        setup.call(['xcrun', 'simctl', 'create', name,
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime['identifier']], 30)
        setup.call(['xcrun', 'simctl', 'boot', setup.current], 60)
        setup.call(['xcrun', 'simctl', 'bootstatus', setup.current, '-b'], 300)
        inherited = setup.environment()
        environment_simulator = setup.current
        setup.call(['xcrun', 'simctl', 'install', setup.current, build / 'SDKSwiftLiveKit.app'], 180)
        if setup.current != environment_simulator:
            inherited = setup.environment(); environment_simulator = setup.current
        setup.call(['xcrun', 'simctl', 'privacy', setup.current, 'grant', 'microphone', BUNDLE], PRIVACY_TIMEOUT_SECONDS)
        if setup.current != environment_simulator:
            inherited = setup.environment()
        simulator = str(uuid.UUID(setup.current)).upper()
        container = None
        # Preparation recovery ends before the unchanged direct capture starts.
        with failure_boundary('infra:evidence-write'): setup.checkpoint()
        for mode in CASES:
            previous_state = os.environ.get('SIM_STATE')
            os.environ['SIM_STATE'] = str(setup.state_path)
            reporter = REPORTER.get(); marker_before = reporter.marker_identity()
            try:
                cases[mode] = capture_case(build, out, simulator, inherited, mode, container)
            except BaseException as error:
                if cancelled(error): reporter.report('infra:runner-cancelled', error)
                elif isinstance(error, OSError) and not isinstance(error, NativeCommandError):
                    reporter.report('infra:evidence-write', error)
                elif reporter.marker_identity() not in (None, marker_before):
                    reporter.mark(error)  # Preserve classification from this child, not an earlier invocation.
                elif isinstance(error, (subprocess.TimeoutExpired, NativeCommandError)):
                    reporter.report('infra:launch', error)
                else: reporter.report('product:swift-livekit-' + mode, error)
                raise
            finally:
                if previous_state is None: os.environ.pop('SIM_STATE', None)
                else: os.environ['SIM_STATE'] = previous_state
            with failure_boundary('product:swift-livekit-' + mode): container = cases[mode]['dataContainer']
    except BaseException as error:
        primary = error
        raise
    finally:
        cleanup_error = None
        handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            with failure_boundary('infra:cleanup'):
                simulator = str(uuid.UUID(setup.current)).upper() if setup.current else simulator
                setup.cleanup(simulator)
        except BaseException as error:
            cleanup_error = error
        try:
            with failure_boundary('infra:evidence-write'): redact(out, ':'.join(setup.redaction_values))
        except BaseException as error:
            if cleanup_error is None: cleanup_error = error
        finally:
            for sig, handler in handlers.items(): signal.signal(sig, handler)
        if primary is None and cleanup_error is not None: raise cleanup_error
    with failure_boundary('product:swift-livekit-conformance'):
        require(set(cases) == set(CASES), 'missing native mode')
    with failure_boundary('infra:evidence-write'):
        save(out / 'manifest.json', dict(schemaVersion=1, source=source(), simulatorID=simulator, cases=cases,
            classification=CLASSIFICATION, ownsSimulator=True, runtimeInjectionRequested=False,
            buildInfoSHA256=digest(build / 'build-info.json'),
            files={str(path.relative_to(out)): digest(path) for path in out.rglob('*') if path.is_file()}))
    with failure_boundary('product:swift-livekit-conformance'): result = validate(build, out)
    with failure_boundary('infra:evidence-write'):
        save(out / 'summary.json', result); print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path); parser.add_argument('out', type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    capture(args.build.resolve(), args.out.resolve(), classify=True)
