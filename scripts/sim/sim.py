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
    failure_classified: bool = False
    cleanup_uncertain: bool = False
    cleanup_errors: tuple = ()
    reaped: bool = True


def transport_failure(result):
    status = result.returncode
    return bool(result.timed_out or (type(status) is int and
                (-status if status < 0 else status - 128) in signal.valid_signals()))


def _command_failure_label(command):
    if command[:2] != ['xcrun', 'simctl']:
        return 'infra:host'
    step = command[2] if len(command) > 2 else None
    operations = ('create', 'boot', 'bootstatus', 'install', 'launch', 'terminate', 'io',
                  'shutdown', 'delete', 'list', 'privacy', 'spawn', 'get_app_container')
    return 'infra:' + step if step in operations else 'infra:helper'


def seconds(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError('A positive finite timeout is required')
    return value


def bounded(command, timeout, *, env=None):
    """Bound execution and owned cleanup without replacing the primary failure."""
    timeout = seconds(timeout)
    process, pending, handlers = None, [], {}
    result, primary, original_mask = None, None, None
    faults, reaped = [], True

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

    def attempt(stage, action):
        nonlocal primary
        try:
            return action()
        except Exception as error:
            faults.append((stage, error))
            if isinstance(error, Interrupted) and primary is None:
                primary = error
        except BaseException as error:
            # Defer control exceptions only until remaining cleanup/restoration.
            faults.append((stage, error))
            if primary is None:
                primary = error

    def kill():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        if threading.current_thread() is threading.main_thread():
            original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
            handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT)}
            initial_faults = len(faults)
            try:
                for signum, handler in handlers.items():
                    if handler != signal.SIG_IGN:
                        signal.signal(signum, defer)
            except BaseException as error:
                primary = error
                raise
            finally:
                attempt('spawn-mask', lambda: signal.pthread_sigmask(signal.SIG_SETMASK, original_mask))
            if primary is not None:
                raise primary
            if len(faults) != initial_faults:
                raise faults[initial_faults][1]
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True, env=env)
        except OSError as error:
            result = Result(list(command), 127, stderr=str(error).encode())
        if process is not None:
            reaped = False
            deadline = time.monotonic() + timeout
            while result is None:
                deliver_pending()
                remaining = deadline - time.monotonic()
                try:
                    stdout, stderr = process.communicate(timeout=max(0, min(remaining, .1)))
                    result = Result(list(command), process.returncode, stdout, stderr)
                except subprocess.TimeoutExpired as error:
                    if time.monotonic() < deadline:
                        continue
                    # Record the timeout before any fallible teardown operation.
                    result = Result(list(command), 124, error.output or b'', error.stderr or b'', timed_out=True)
                    attempt('killpg', kill)
                    drained = attempt('drain', lambda: process.communicate(timeout=2))
                    if drained is not None:
                        result.stdout, result.stderr = drained
    except BaseException as error:
        if primary is None:
            primary = error
    finally:
        try:
            try:
                if process is not None:
                    if process.returncode is None:
                        attempt('killpg', kill)
                    for stream in (process.stdout, process.stderr):
                        if stream is not None:
                            attempt('close', stream.close)
                    waited = attempt('reap', lambda: process.wait(timeout=2))
                    reaped = type(waited) is int
                # A worker may dispatch a pending Python handler between restorations.
                # Retry the complete pair finitely, preserving that exception's identity.
                if handlers:
                    for _ in range(2):
                        count = len(faults)
                        try:
                            attempt('restore-mask-block', lambda: signal.pthread_sigmask(signal.SIG_BLOCK, set(handlers)))
                            for signum, handler in handlers.items():
                                attempt('restore-handler', lambda: signal.signal(signum, handler))
                        except BaseException as error:
                            faults.append(('restore-handlers', error))
                            if primary is None:
                                primary = error
                        if len(faults) == count:
                            break
            finally:
                if original_mask is not None:
                    for _ in range(2):
                        try:
                            signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
                            break
                        except BaseException as error:
                            faults.append(('restore-mask', error))
                            if primary is None and (not isinstance(error, Exception) or isinstance(error, Interrupted)):
                                primary = error
        except BaseException as error:
            faults.append(('teardown', error))
            if primary is None:
                primary = error
        if primary is None:
            try:
                deliver_pending()
            except BaseException as error:
                primary = error

    uncertain = bool(faults) or not reaped
    if uncertain:
        detail = ', '.join(stage + ':' + type(error).__name__ for stage, error in faults)
        attempt('report', lambda: summary('infra:host-cleanup',
                'uncertain; child reaped=' + str(reaped).lower() + ('; ' + detail if detail else '')))
    details = tuple(stage + ':' + type(error).__name__ for stage, error in faults)
    if result is not None:
        result.cleanup_uncertain, result.cleanup_errors, result.reaped = uncertain, details, reaped
        if uncertain and result.returncode == 0:
            result.returncode = 125
    if primary is not None:
        try:
            primary.cleanup_uncertain, primary.cleanup_errors, primary.reaped = uncertain, details, reaped
        except BaseException:
            pass  # Metadata cannot replace the original exception identity.
        raise primary
    if (result is not None and result.timed_out and
            os.environ.get('CKSIM_RECORD_TIMEOUT_OPERATIONS') == '1' and
            command[:2] == ['xcrun', 'simctl'] and len(command) > 2 and
            command[2] in ('create', 'boot', 'bootstatus', 'install', 'launch', 'terminate',
                           'io', 'shutdown', 'delete', 'list', 'privacy', 'spawn', 'get_app_container')):
        try:
            summary('measurement:simctl-timeout', command[2])
        except Interrupted:
            raise  # Cancellation must retain its normal behavior.
        except Exception:
            pass  # Diagnostic failure must not replace the native outcome.
    return result


def summary(label, retry):
    """Write only stable classifications, never commands or environment values."""
    label = re.sub(r'[^A-Za-z0-9_.:-]', '_', label)
    line = f'- `{label}`: {retry}\n'
    try:
        try: descriptor = sys.stderr.fileno()
        except (AttributeError, OSError, ValueError): descriptor = None
        if descriptor is None: print(line.rstrip(), file=sys.stderr)
        else: os.write(descriptor, line.encode('utf-8', errors='backslashreplace'))
    except (OSError, ValueError):
        pass
    target = os.environ.get('GITHUB_STEP_SUMMARY')
    if target:
        try:
            with open(target, 'a') as stream:
                stream.write(line)
        except OSError:
            pass


def report_failure(label, retry='never retried'):
    summary(label, retry)
    marker = os.environ.get('SIM_FAILURE_MARKER')
    if marker:
        try: Path(marker).touch(mode=0o600)
        except OSError: pass


def _report_result(result, label, retry):
    result.failure_classified = True
    report_failure(label, retry)


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


class Session:
    def __init__(self, path, runner=bounded, recovery_timeout=30, *, create=True, simulator=None,
                 inventory_timeout=None):
        self.path, self.runner = Path(path), runner
        self._host_cleanup_failure = None
        self._attached = not create
        self._expected_simulator = simulator_uuid(simulator).lower() if simulator else None
        self.recovery_timeout = seconds(recovery_timeout)
        self.inventory_timeout = seconds(inventory_timeout) if inventory_timeout is not None else None
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
    def attach(cls, path, simulator, **kwargs):
        """Join the parent's existing budget; never initialize a child budget."""
        if not simulator:
            raise ValueError('An expected simulator is required to attach')
        return cls(path, create=False, simulator=simulator, **kwargs)

    @classmethod
    def resume(cls, path, simulator=None, runner=bounded, inventory_timeout=60, **kwargs):
        """Transfer lifecycle ownership between sequential workflow steps.

        The state must already exist. Verify the supplied identity before any
        native call, then permit this owner to record a fresh-device recovery.
        Console children use attach() and cannot change ownership records.
        """
        session = cls(path, create=False, simulator=simulator, runner=runner,
                      inventory_timeout=inventory_timeout, **kwargs)
        session._attached = False
        session._expected_simulator = None
        return session

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
            self._validate_current(latest)
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
            self._validate_current(self.state)
            if not self._attached and self._ownership(self.state) != self._saved_ownership:
                raise ValueError('Simulator ownership changed; refusing a stale checkpoint')
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
            if not self._attached and self._ownership(latest) != self._saved_ownership:
                raise ValueError('Simulator ownership changed; refusing a stale checkpoint read')
            return latest['checkpoint']

    def reserve_retry(self):
        """Spend the invocation's sole pre-app retry before attempting recovery."""
        if self._attached or self._host_cleanup_failure is not None:
            return False
        with self._locked():
            latest = self._read_state()
            if latest is None:
                raise ValueError('Simulator session disappeared')
            self._validate_current(latest)
            if self._ownership(latest) != self._saved_ownership:
                raise ValueError('Simulator ownership changed; refusing a stale retry')
            self.state = latest
            if self.state['retry_used'] or self.state['checkpoint']:
                self._remember_ownership()
                return False
            self.state['retry_used'] = True
            self._write_state()
            return True

    def _uncertain_host(self, command, outcome):
        if self._host_cleanup_failure is None:
            self._host_cleanup_failure = outcome
        prior = self._host_cleanup_failure
        if not getattr(outcome, 'cleanup_uncertain', False):
            outcome.cleanup_errors = getattr(prior, 'cleanup_errors', ())
            outcome.reaped = getattr(prior, 'reaped', False)
        outcome.cleanup_uncertain = True
        if isinstance(outcome, Result) and outcome.returncode == 0:
            outcome.returncode = 125
        try:
            self.checkpoint()  # Conservative no-replay barrier, not app evidence.
            outcome.cleanup_barrier_saved = True
        except Interrupted:
            raise
        except Exception:
            # Structural state and persistence faults leave the durable barrier unknown.
            if isinstance(self.state, dict):
                self.state['checkpoint'] = True
            outcome.cleanup_barrier_saved = False
            try:
                summary('infra:checkpoint', 'not eligible; host cleanup barrier persistence unknown')
            except (OSError, ValueError):
                pass
        step = command[2] if command[:2] == ['xcrun', 'simctl'] else 'host'
        try:
            _report_result(outcome, 'infra:' + step, 'not eligible; owned host cleanup uncertain')
        except (OSError, ValueError):
            pass  # Reporter I/O cannot replace the command's primary failure.

    def execute(self, command, timeout):
        timeout = seconds(timeout)
        started = time.monotonic()
        result, error = None, None
        try:
            try:
                result = self.runner(list(command), timeout)
            except BaseException as error:
                if getattr(error, 'cleanup_uncertain', False):
                    try:
                        self._uncertain_host(command, error)
                    except BaseException:
                        pass  # Never replace the original command/cancellation error.
                raise
            if getattr(result, 'cleanup_uncertain', False):
                self._uncertain_host(command, result)
            return result
        except BaseException as failure:
            error = type(failure).__name__
            raise
        finally:
            row = dict(step=_command_failure_label(command).removeprefix('infra:'),
                       timeoutSeconds=timeout, elapsedSeconds=round(time.monotonic() - started, 6),
                       exitCode=result.returncode if result is not None else None,
                       timedOut=result.timed_out if result is not None else False)
            if error is not None:
                row['error'] = error
            try:
                with self.path.with_name('commands.status.jsonl').open('a') as stream:
                    stream.write(json.dumps(row) + '\n')
            except OSError:
                # Timing is observational: losing it must not discard a create
                # acknowledgement or interrupt the remaining owned teardown.
                try: summary('infra:evidence-write', 'setup duration unavailable; native outcome preserved')
                except OSError: pass

    def create(self, arguments, timeout):
        name = arguments[0] + ('' if arguments[0].endswith(' ') else '-') + str(uuid.uuid4())
        record = dict(name=name, id=None, uncertain=True)
        self.state['owned'].append(record)
        self.save()  # Persist the full unique name before contacting CoreSimulator.
        result = self.execute(['xcrun', 'simctl', 'create', name, *arguments[1:]], timeout)
        if result.cleanup_uncertain:
            return result  # The reserved name stays uncertain; no new attempt.
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
        result = self.execute(['xcrun', 'simctl', 'list', 'devices', '-j'], self.inventory_timeout or timeout)
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

    def cleanup(self, timeout=30, final=True, *, on_error=None):
        """Try every owned device, retaining unresolved ownership for later cleanup."""
        timeout = seconds(timeout)
        if self._attached or not self.state['owned']:
            return Result([], 0)
        original = self.current
        success, last = True, None
        errors = []

        def failed(label, error):
            errors.append(error)
            if on_error is not None:
                try:
                    on_error(error)
                except BaseException:
                    pass  # Observation cannot interrupt owned teardown.
            try:
                error.failure_classified = True  # Exact in-memory outcome, never receipt data.
            except (AttributeError, TypeError):
                pass
            try:
                report_failure(label, 'not eligible; owned cleanup continued')
            except (OSError, ValueError):
                pass

        def attempt(action, label='infra:evidence-write'):
            try:
                return action()
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                failed(label, error)

        log_path = self.path.with_name('cleanup.log')
        for record in list(self.state['owned']):
            try:
                device, known = self.recover(record, min(timeout, self.recovery_timeout))
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                # A successful exact-name lookup can bind the ID before its
                # state write fails. Keep that native ownership proof for teardown.
                failed('infra:evidence-write' if record.get('id') else 'infra:cleanup-inventory', error)
                try:
                    device = simulator_uuid(record['id']) if record.get('id') else None
                except ValueError:
                    device = None
                known = bool(device)
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
                    attempt(self.save)
                continue
            shutdown = attempt(lambda: self.execute(['xcrun', 'simctl', 'shutdown', device], timeout), 'infra:shutdown')
            delete = attempt(lambda: self.execute(['xcrun', 'simctl', 'delete', device], timeout), 'infra:delete')
            stream = attempt(lambda: log_path.open('ab'))
            if stream is not None:
                try:
                    for result in (shutdown, delete):
                        if result is not None:
                            attempt(lambda: stream.write(result.stdout + result.stderr))
                finally:
                    attempt(stream.close)
            deleted = delete is not None and delete.returncode == 0
            last = dict(simulatorID=device, shutdownExitCode=shutdown.returncode if shutdown else None,
                        deleteExitCode=delete.returncode if delete else None, deleted=deleted)
            if shutdown is None or shutdown.returncode:
                summary('infra:shutdown', 'not eligible; delete attempted')
            if not deleted:
                summary('infra:delete', 'not eligible; ownership retained')
                success = False
            else:
                self.state['owned'].remove(record)
                if self.current == device:
                    self.state['current'] = None
                attempt(self.save)
        if last is None:
            last = dict(simulatorID=original, shutdownExitCode=None,
                        deleteExitCode=None, deleted=success)
        last['deleted'] = success and not self.state['owned']
        attempt(lambda: self.path.with_name('cleanup.json').write_text(json.dumps(last, indent=2) + '\n'))
        if errors:
            raise errors[0]
        return Result([], 0 if success else 1)

    def replacement(self):
        cleanup = self.cleanup(timeout=self.recovery_timeout, final=False)
        if self._host_cleanup_failure is not None:
            return self._host_cleanup_failure
        if cleanup.returncode:
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
        with self._locked():
            latest = self._read_state()
            if latest is None:
                raise ValueError('Simulator session disappeared')
            self._validate_current(latest)
            if not self._attached and self._ownership(latest) != self._saved_ownership:
                raise ValueError('Simulator ownership changed; refusing a stale operation')
            self.state = latest
            self._remember_ownership()
        if len(command) < 3:
            raise ValueError('Missing simulator operation')
        step = command[2]
        if self._attached and step in ('create', 'delete'):
            raise ValueError('Borrowed sessions cannot change simulator ownership')
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

        def failure_state():
            # Failure-time snapshot; final cleanup is reported separately.
            # Never expose simulator identifiers or command/environment values.
            try:
                def flag(name):
                    value = self.state.get(name)
                    return 'true' if value is True else 'false' if value is False else 'unknown'
                owned = self.state.get('owned')
                count = str(len(owned)) if isinstance(owned, list) else 'unknown'
                summary('simulator-state', 'at failure; checkpoint=' + flag('checkpoint') +
                        '; retry_used=' + flag('retry_used') + '; owned_count=' + count)
            except Interrupted:
                raise  # Cancellation must not continue into recovery.
            except Exception:
                pass  # Observability must never replace the original result.

        if result.cleanup_uncertain:
            return result
        if step == 'launch' and result.stdout:
            self.checkpoint()  # Even partial app/PID evidence forbids startup replay.
        if result.returncode:
            failure_state()
            # A capture supervisor already reported a specific terminal failure.
            if result.failure_classified:
                return result
            if step == 'launch' and transport_failure(result):
                _report_result(result, 'infra:launch', 'transport failed; never retried')
                return result
            if step == 'launch' and self.is_checkpointed():
                _report_result(result, 'product:launch', 'never retried after checkpoint evidence')
                return result
            runtime_timeout = (command == ['xcrun', 'simctl', 'list', 'runtimes', '-j'] and result.timed_out)
            # An owned query recovery needs its recorded create configuration.
            runtime_timeout = runtime_timeout and (not self.state['owned'] or bool(self.state['create']))
            eligible = step == 'create' or preparation or runtime_timeout
            if step == 'launch':
                position = command.index(self.current)
                bundle = command[position + 1] if position + 1 < len(command) else ''
                eligible = bool(bundle) and preapp_rejection(result, bundle)
            if not eligible or not self.reserve_retry():
                _report_result(result, 'infra:' + step, 'exhausted' if self.state['retry_used'] else 'not eligible')
                return result
            if self.is_checkpointed():
                _report_result(result, 'infra:' + step, 'never retried after checkpoint evidence')
                return result
            summary('infra:' + step, 'scheduled (one pre-app retry)')
            if step == 'create':
                cleanup = self.cleanup(timeout=self.recovery_timeout, final=False)
                if self._host_cleanup_failure is not None:
                    self._uncertain_host(command, result)
                    return result
                if cleanup.returncode:
                    _report_result(result, 'infra:create', 'exhausted; cleanup failed')
                    return result
                result = self.create(command[3:], timeout)
            elif preparation or (runtime_timeout and self.state['create']):
                original = result
                result = self.replacement()
                if result.cleanup_uncertain:
                    self._uncertain_host(command, original)
                    return original
                if result.returncode == 0:
                    if step != 'list':
                        command[3] = self.current
                    result = self.execute(command, timeout)
            else:
                result = self.execute(command, timeout)
            if result.cleanup_uncertain:
                return result
            if result.returncode:
                failure_state()
                _report_result(result, 'infra:' + step, 'exhausted')
            else:
                summary('infra:' + step, 'recovered')

        if result.returncode == 0:
            if preparation:
                prepared_command = list(command)
                prepared_command[3] = '{simulator}'
                self.state['prepared'].append(dict(command=prepared_command, timeout=timeout))
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
            session = Session(args.state) if args.state else None
            result = session.call(args.command, args.timeout) if session else bounded(args.command, args.timeout)
            accepted = not result.timed_out and result.returncode == args.accepted_status
            if (not session and result.returncode and not accepted and
                    (args.command[:2] == ['xcrun', 'simctl'] or transport_failure(result))):
                _report_result(result, _command_failure_label(args.command), 'not eligible')
            sys.stdout.buffer.write(result.stdout)
            sys.stderr.buffer.write(result.stderr)
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
        if not args.state.exists():
            return 0
        session = Session(args.state)
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
            try:
                session.cleanup()
            except Exception:
                try:
                    summary('infra:cleanup', 'not eligible; cancellation cleanup uncertain')
                except (OSError, ValueError):
                    pass
        return 128 + error.signum
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Simulator helper: ' + str(error), file=sys.stderr)
        summary('infra:helper', 'not eligible')
        return 125 if args.action == 'call' and args.accepted_status is not None else 1


if __name__ == '__main__':
    sys.exit(main())
