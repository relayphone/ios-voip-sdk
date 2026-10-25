#!/usr/bin/env python3
"""Bounded simulator lifecycle operations and persistent, run-owned cleanup.

Console evidence supervisors must keep launching their native child directly;
this module never changes their PID/group topology or product deadlines.
"""
import argparse
import copy
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid


@dataclass
class Result:
    args: list
    returncode: int
    stdout: bytes = b''
    stderr: bytes = b''
    timed_out: bool = False


def seconds(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError('A positive finite timeout is required')
    return value


def bounded(command, timeout):
    """Kill the complete owned host process group at the hard deadline."""
    timeout = seconds(timeout)
    process, pending, handlers, spawn_error = None, [], {}, None

    def defer(signum, frame):
        pending.append((signum, frame))

    def deliver_pending():
        while pending:
            signum, frame = pending.pop(0)
            handler = handlers[signum]
            if callable(handler):
                handler(signum, frame)
            elif handler == signal.SIG_DFL:
                raise Interrupted(signum)

    def kill():
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        # Defer asynchronous callbacks throughout native ownership, including
        # timeout handlers and cleanup. Deliver them only at controlled points
        # inside the lifetime guard, or after the native child has been reaped.
        try:
            if threading.current_thread() is threading.main_thread():
                original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
                try:
                    handlers = {signum: signal.getsignal(signum)
                                for signum in (signal.SIGTERM, signal.SIGINT)}
                    for signum, handler in handlers.items():
                        if handler != signal.SIG_IGN:
                            signal.signal(signum, defer)
                finally:
                    # Unblock before spawning: native children inherit only the
                    # caller's original mask, never this temporary parent mask.
                    signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
            try:
                process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
            except OSError as error:
                spawn_error = error
            if spawn_error is not None:
                return Result(list(command), 127, stderr=str(spawn_error).encode())
            deadline = time.monotonic() + timeout
            while True:
                deliver_pending()
                remaining = deadline - time.monotonic()
                try:
                    # Poll the same absolute deadline so cancellation does not
                    # wait for a long native budget or restart that budget.
                    stdout, stderr = process.communicate(timeout=max(0, min(remaining, .1)))
                    return Result(list(command), process.returncode, stdout, stderr)
                except subprocess.TimeoutExpired as error:
                    if time.monotonic() < deadline:
                        continue
                    kill()
                    try:
                        stdout, stderr = process.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        # An escaped descendant must not keep inherited pipe
                        # readers alive after the owned group has been killed.
                        stdout, stderr = error.output or b'', error.stderr or b''
                    return Result(list(command), 124, stdout, stderr, timed_out=True)
        finally:
            # This one guard encloses the entire child lifetime. Signal
            # callbacks still only queue while kill, pipe closure and reap run.
            if process is not None:
                if process.returncode is None:
                    kill()
                process.stdout.close()
                process.stderr.close()
                process.wait(timeout=2)
    finally:
        if handlers:
            restore_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set(handlers))
            try:
                # Worker-delivered signals can schedule Python callbacks even
                # with this thread masked. Complete restoration before raising.
                restoration_error = None
                while True:
                    try:
                        try:
                            signal.signal(signal.SIGTERM, handlers[signal.SIGTERM])
                        finally:
                            signal.signal(signal.SIGINT, handlers[signal.SIGINT])
                        break
                    except BaseException as error:
                        if restoration_error is None:
                            restoration_error = error
                if restoration_error is not None:
                    raise restoration_error
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, restore_mask)
        deliver_pending()


def summary(label, retry):
    """Write only stable classifications, never commands or environment values."""
    label = re.sub(r'[^A-Za-z0-9_.:-]', '_', label)
    line = f'- `{label}`: {retry}\n'
    print(line.rstrip(), file=sys.stderr)
    target = os.environ.get('GITHUB_STEP_SUMMARY')
    if target:
        with open(target, 'a') as stream:
            stream.write(line)


def failure_is_classified():
    """Whether this runner already reported its terminal failure to its parent."""
    marker = os.environ.get('SIM_FAILURE_MARKER')
    return bool(marker and Path(marker).is_file())


def clear_failure_marker():
    """Clear an earlier rejected attempt before its single authorized replay."""
    marker = os.environ.get('SIM_FAILURE_MARKER')
    if marker:
        Path(marker).unlink(missing_ok=True)


def report_failure(label, retry='never retried'):
    """Report a terminal outcome; the parent need not invent a second label."""
    summary(label, retry)
    marker = os.environ.get('SIM_FAILURE_MARKER')
    if marker:
        Path(marker).touch(mode=0o600)


def terminate_once(command, timeout, transport):
    """Keep the caller's bounded termination transport, with no replay."""
    seconds(timeout)
    return transport(command, capture_output=True, timeout=timeout)


def simulator_uuid(value):
    value = value.strip()
    if str(uuid.UUID(value)).lower() != value.lower():
        raise ValueError('Expected a simulator UUID')
    return value


def preapp_rejection(result, bundle):
    """A timeout or any stdout is an unknown app outcome, never replayable."""
    expected = (
        'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
        f'Simulator device failed to launch {bundle}.\nNo such process\n'
        'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
        f"\tApplication launch for '{bundle}' did not return a process handle nor launch error.\n"
        '\tNo such process\n').encode()
    return (result.returncode == 3 and not result.timed_out and
            result.stdout == b'' and result.stderr == expected)


def not_running_error(bundle):
    """The exact native termination refusal proving nothing remains to stop."""
    return (
        'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
        f'Simulator device failed to terminate {bundle}.\nfound nothing to terminate\n'
        'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
        f'\tThe request to terminate "{bundle}" failed. found nothing to terminate\n'
        '\tfound nothing to terminate\n')


def console_launch_rejection(value, trace_bytes, bundle, timeout):
    """Classify the exact pre-app rejection; this alone never permits replay.

    A retry owner must additionally prove its expected process/group identity,
    unchanged runtime evidence, group absence, and remaining aggregate budget.
    """
    if not isinstance(value, dict):
        return False
    eof = value.get('stdoutEOFSeconds')
    return (preapp_rejection(Result([], value.get('launchExitCode'), stderr=trace_bytes), bundle) and
            value.get('completed') is False and value.get('success') is False and
            value.get('error') == 'launcher exited before terminal done event' and
            value.get('identityError') == 'require one launcher app PID acknowledgement; got 0' and
            value.get('launchExitCodeBeforeCleanup') == value.get('launchExitCode') == 3 and
            type(eof) in (int, float) and math.isfinite(eof) and 0 <= eof < timeout and
            value.get('cleanupExitCode') == 3 and value.get('cleanupStdout') == '' and
            value.get('cleanupStderr') == not_running_error(bundle) and 'cleanupError' not in value and
            not any(key in value for key in ('appPID', 'launcherAppPID', 'appEntryObserved', 'lastProbeEvent')))


def console_preapp_rejection(value, trace_bytes, identity, owner_pid, timeout):
    """Keep the grouped supervisor's static proof separate from retry ownership.

    The caller still checks supervisor exit, journal/session snapshots, live
    process-group absence, attempt count, and its original aggregate deadline.
    """
    return (console_launch_rejection(value, trace_bytes, identity['bundleID'], timeout) and
            value.get('inheritLauncherGroup') is True and
            all(value.get(key) == owner_pid for key in
                ('supervisorPID', 'supervisorPGID', 'supervisorSID', 'launcherPGID')) and
            type(value.get('launcherPID')) is int and value['launcherPID'] > 0 and
            value['launcherPID'] != owner_pid and
            all(value.get(key) == identity[key] for key in ('runID', 'simulatorID', 'scenario', 'bundleID')))


class Session:
    def __init__(self, path, runner=bounded, recovery_timeout=30, *, create=True, simulator=None):
        self.path, self.runner = Path(path), runner
        self._attached = not create
        self._expected_simulator = simulator_uuid(simulator).lower() if simulator else None
        self.recovery_timeout = seconds(recovery_timeout)
        with self._locked():
            self.state = self._read_state()
            if self.state is None:
                if not create:
                    raise ValueError('Cannot attach to a missing simulator session')
                self.state = dict(current=None, owned=[], retry_used=False,
                                  checkpoint=False, create=None, prepared=[])
                self._write_state()
            self._validate_current(self.state)
            self._remember_ownership()

    @classmethod
    def attach(cls, path, simulator):
        """Join the parent's existing budget; never initialize a child budget."""
        if not simulator:
            raise ValueError('An expected simulator is required to attach')
        return cls(path, create=False, simulator=simulator)

    @contextmanager
    def _locked(self):
        # Lock a stable sibling, not the JSON inode replaced by _write_state.
        fd = os.open(str(self.path) + '.lock',
                     os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            # Contention is an unknown infrastructure outcome, never permission
            # to wait past a caller's product deadline or start another budget.
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def _read_state(self):
        if self.path.is_symlink():
            raise ValueError('Simulator state must not be a symlink')
        if self.path.exists():
            return json.loads(self.path.read_text())
        return None

    @property
    def current(self):
        value = self.state['current']
        return simulator_uuid(value) if value else None

    def save(self):
        with self._locked():
            latest = self._read_state()
            if latest is None:
                raise ValueError('Simulator session disappeared')
            flags = {key: self.state[key] or latest[key] for key in ('retry_used', 'checkpoint')}
            if self._attached:
                # An attached console child never writes cached device records.
                self.state = latest
            elif self._ownership(latest) != self._saved_ownership:
                raise ValueError('Simulator ownership changed; refusing a stale save')
            self.state.update(flags)
            self._write_state()

    @staticmethod
    def _ownership(state):
        return {key: copy.deepcopy(state[key]) for key in ('current', 'owned', 'create', 'prepared')}

    def _remember_ownership(self):
        self._saved_ownership = self._ownership(self.state)

    def _validate_current(self, state):
        current = state['current']
        if self._expected_simulator and (not current or
                simulator_uuid(current).lower() != self._expected_simulator):
            raise ValueError('Simulator session does not own the expected current simulator')

    def _write_state(self):
        if self.path.is_symlink():
            raise ValueError('Simulator state must not be a symlink')
        fd, temporary = tempfile.mkstemp(prefix=self.path.name + '.', dir=self.path.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(self.state, stream, indent=2)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            self._remember_ownership()
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def checkpoint(self):
        with self._locked():
            self.state = self._read_state()
            if self.state is None:
                raise ValueError('Simulator session disappeared')
            if self.state['checkpoint']:
                self._remember_ownership()
                return
            self.state['checkpoint'] = True
            self._write_state()

    def is_checkpointed(self):
        with self._locked():
            latest = self._read_state()
            if latest is None:
                raise ValueError('Simulator session disappeared')
            self._validate_current(latest)
            return latest['checkpoint']

    def reserve_retry(self):
        """Spend the invocation's sole pre-app retry before attempting recovery."""
        with self._locked():
            self.state = self._read_state()
            if self.state is None:
                raise ValueError('Simulator session disappeared')
            self._validate_current(self.state)
            if self.state['retry_used'] or self.state['checkpoint']:
                self._remember_ownership()
                return False
            self.state['retry_used'] = True
            self._write_state()
            return True

    def execute(self, command, timeout):
        return self.runner(list(command), seconds(timeout))

    def create(self, arguments, timeout):
        name = arguments[0] + '-' + str(uuid.uuid4())
        record = dict(name=name, id=None, uncertain=True)
        self.state['owned'].append(record)
        self.save()  # Persist the full unique name before contacting CoreSimulator.
        result = self.execute(['xcrun', 'simctl', 'create', name, *arguments[1:]], timeout)
        if result.returncode == 0:
            try:
                device = simulator_uuid(result.stdout.decode())
            except (ValueError, UnicodeDecodeError):
                return Result(result.args, 1, stderr=b'Invalid simulator UUID from create\n')
            record['id'] = self.state['current'] = device
            record['uncertain'] = False
            self.save()
        else:
            record['uncertain'] = result.timed_out or result.returncode < 0 or result.returncode >= 128
            self.save()
        return result

    def recover(self, record, timeout):
        if record['id']:
            return simulator_uuid(record['id']), True
        result = self.execute(['xcrun', 'simctl', 'list', 'devices', '-j'], timeout)
        if result.returncode:
            summary('infra:cleanup-inventory', 'not eligible')
            return None, False
        try:
            inventory = json.loads(result.stdout)['devices']
            matches = [device for devices in inventory.values() for device in devices
                       if device.get('name') == record['name']]
            if len(matches) > 1:
                raise ValueError('Ambiguous owned simulator name')
            device = simulator_uuid(matches[0]['udid']) if matches else None
        except (KeyError, TypeError, ValueError):
            summary('infra:cleanup-inventory', 'not eligible')
            return None, False
        if device:
            record['id'] = device
            record['uncertain'] = False
            self.save()
        return device, True

    def cleanup(self, timeout=30, final=True):
        """Try every owned device, retaining unresolved ownership for later cleanup."""
        timeout = seconds(timeout)
        if not self.state['owned']:
            return Result([], 0)
        original = self.current
        success, last = True, None
        log_path = self.path.with_name('cleanup.log')
        for record in list(self.state['owned']):
            device, known = self.recover(record, min(timeout, self.recovery_timeout))
            if not known:
                success = False
                continue
            if not device:
                # A daemon may finish a timed-out request after this inventory.
                # Retain its exact name so an always-step can reconcile it later.
                if record.get('uncertain', True):
                    if final:
                        summary('infra:cleanup-inventory', 'not eligible; create outcome unresolved, ownership retained')
                        success = False
                else:
                    self.state['owned'].remove(record)
                    self.save()
                continue
            shutdown = self.execute(['xcrun', 'simctl', 'shutdown', device], timeout)
            delete = self.execute(['xcrun', 'simctl', 'delete', device], timeout)
            with log_path.open('ab') as stream:
                for result in (shutdown, delete):
                    stream.write(result.stdout + result.stderr)
            last = dict(simulatorID=device, shutdownExitCode=shutdown.returncode,
                        deleteExitCode=delete.returncode, deleted=delete.returncode == 0)
            if shutdown.returncode:
                summary('infra:shutdown', 'not eligible; delete attempted')
            if delete.returncode:
                summary('infra:delete', 'not eligible; ownership retained')
                success = False
            else:
                self.state['owned'].remove(record)
                if self.current == device:
                    self.state['current'] = None
                self.save()
        if last is None:
            last = dict(simulatorID=original, shutdownExitCode=None,
                        deleteExitCode=None, deleted=success)
        last['deleted'] = success and not self.state['owned']
        self.path.with_name('cleanup.json').write_text(json.dumps(last, indent=2) + '\n')
        return Result([], 0 if success else 1)

    def replacement(self):
        if self.cleanup(timeout=self.recovery_timeout, final=False).returncode:
            return Result([], 1, stderr=b'Cannot replace simulator before owned cleanup\n')
        config = self.state['create']
        result = self.create(config['arguments'], config['timeout'])
        if result.returncode:
            return result
        for prepared in self.state['prepared']:
            command = list(prepared['command'])
            command[3] = self.current
            result = self.execute(command, prepared['timeout'])
            if result.returncode:
                summary('infra:' + command[2], 'exhausted during fresh simulator preparation')
                return result
        return Result([], 0)

    def call(self, command, timeout):
        timeout = seconds(timeout)
        command = list(command)
        if command[:2] != ['xcrun', 'simctl']:
            return self.execute(command, timeout)
        if len(command) < 3:
            raise ValueError('Missing simulator operation')
        step = command[2]
        if step not in ('create', 'boot', 'bootstatus', 'install', 'launch', 'terminate',
                        'io', 'shutdown', 'delete', 'list', 'privacy'):
            raise ValueError('Unsupported simulator operation: ' + step)
        if step == 'io' and (len(command) < 5 or command[4] != 'screenshot'):
            raise ValueError('Only screenshot simulator IO is supported')
        privacy_grant = (step == 'privacy' and len(command) == 7 and command[4] == 'grant' and
                         all(value and not value.startswith('-') for value in command[5:7]))
        preparation = step in ('boot', 'bootstatus', 'install') or privacy_grant
        if step == 'create':
            if len(command) != 6 or self.current:
                raise ValueError('Create requires a fresh session, name, device type and runtime')
            self.state['create'] = dict(arguments=command[3:], timeout=timeout)
            self.save()
            result = self.create(command[3:], timeout)
        else:
            if step != 'list':
                position = 3
                if step == 'launch':
                    flags = {'--console', '--console-pty', '--terminate-running-process', '--wait-for-debugger'}
                    while position < len(command) and command[position] in flags:
                        position += 1
                if not self.current or len(command) <= position or command[position] != self.current:
                    raise ValueError('Operation must target the current owned simulator')
                lengths = {'boot': 4, 'bootstatus': 5, 'install': 5, 'terminate': 5, 'shutdown': 4, 'delete': 4}
                if step in lengths and len(command) != lengths[step]:
                    raise ValueError('Unexpected simulator operation arguments')
                if step == 'bootstatus' and command[4] != '-b':
                    raise ValueError('Bootstatus requires its blocking flag')
            result = self.execute(command, timeout)

        if step == 'launch' and result.stdout:
            self.checkpoint()  # Even partial app/PID evidence forbids startup replay.
        if result.returncode:
            if step == 'launch' and self.is_checkpointed():
                summary('product:launch', 'never retried after checkpoint evidence')
                return result
            eligible = step == 'create' or preparation
            if step == 'launch':
                position = command.index(self.current)
                bundle = command[position + 1] if position + 1 < len(command) else ''
                eligible = bool(bundle) and preapp_rejection(result, bundle)
            if not eligible or not self.reserve_retry():
                summary('infra:' + step, 'exhausted' if self.state['retry_used'] else 'not eligible')
                return result
            if self.is_checkpointed():
                summary('infra:' + step, 'never retried after checkpoint evidence')
                return result
            summary('infra:' + step, 'scheduled (one pre-app retry)')
            if step == 'create':
                if self.cleanup(timeout=self.recovery_timeout, final=False).returncode:
                    summary('infra:create', 'exhausted; cleanup failed')
                    return result
                result = self.create(command[3:], timeout)
            elif preparation:
                result = self.replacement()
                if result.returncode == 0:
                    command[3] = self.current
                    result = self.execute(command, timeout)
            else:
                result = self.execute(command, timeout)
            summary('infra:' + step, 'exhausted' if result.returncode else 'recovered')

        if result.returncode == 0:
            if preparation:
                prepared_command = list(command)
                prepared_command[3] = '{simulator}'
                self.state['prepared'].append(dict(
                    command=prepared_command, timeout=timeout))
            elif step == 'launch':
                self.state['checkpoint'] = True
            elif step == 'delete':
                device = self.current
                self.state['owned'] = [record for record in self.state['owned'] if record['id'] != device]
                self.state['current'] = None
            self.save()
        return result


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    caller = commands.add_parser('call')
    caller.add_argument('--accepted-status', type=int, choices=(1,))
    caller.add_argument('state')
    caller.add_argument('timeout', type=seconds)
    caller.add_argument('command', nargs=argparse.REMAINDER)
    for action in ('current', 'checkpoint', 'cleanup'):
        child = commands.add_parser(action)
        child.add_argument('state', type=Path)
        if action == 'cleanup':
            child.add_argument('--timeout', type=seconds, default=30)
    product = commands.add_parser('product')
    product.add_argument('check')
    args = parser.parse_args(argv)
    session = None

    def interrupted(signum, _frame):
        raise Interrupted(signum)

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)
    try:
        if args.action == 'product':
            summary('product:' + args.check, 'never retried')
            return 0
        if args.action == 'call':
            if not args.command:
                raise ValueError('A command is required')
            if args.accepted_status is not None and args.state:
                raise ValueError('Accepted statuses are allowed only for stateless bounded calls')
            session = Session(args.state, recovery_timeout=os.environ.get('SIM_RECOVERY_TIMEOUT', 30)) if args.state else None
            result = session.call(args.command, args.timeout) if session else bounded(args.command, args.timeout)
            accepted = not result.timed_out and result.returncode == args.accepted_status
            if not session and result.returncode and not accepted and args.command[:2] == ['xcrun', 'simctl']:
                summary('infra:' + (args.command[2] if len(args.command) > 2 else 'helper'), 'not eligible')
            sys.stdout.buffer.write(result.stdout)
            sys.stderr.buffer.write(result.stderr)
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
        if not args.state.exists():
            return 0
        session = Session(args.state, recovery_timeout=os.environ.get('SIM_RECOVERY_TIMEOUT', 30))
        if args.action == 'current':
            print(session.current or '')
            return 0
        if args.action == 'checkpoint':
            session.checkpoint()
            return 0
        return session.cleanup(timeout=args.timeout).returncode
    except Interrupted as error:
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        if session:
            session.cleanup(timeout=args.timeout if args.action == 'cleanup' else session.recovery_timeout)
        return 128 + error.signum
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Simulator helper: ' + str(error), file=sys.stderr)
        summary('infra:helper', 'not eligible')
        return 125 if args.action == 'call' and args.accepted_status is not None else 1


if __name__ == '__main__':
    sys.exit(main())
