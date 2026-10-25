"""Observe one native launch through canonical receipts without replaying it."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
import uuid


def canonical(path):
    if path.resolve(strict=False) != path:
        raise ValueError('Inspector evidence path is noncanonical')
    return path


def locate_probe(simulator, nonce, bundle, devices_root=None):
    for value in (simulator, nonce):
        if not isinstance(value, str) or str(uuid.UUID(value)).lower() != value.lower():
            raise ValueError('Expected an exact simulator and launch nonce')
    simulator = str(uuid.UUID(simulator)).upper()
    devices = Path(devices_root).absolute() if devices_root is not None else Path.home() / 'Library/Developer/CoreSimulator/Devices'
    applications = canonical(devices / simulator / 'data/Containers/Data/Application')
    if not applications.exists():
        return None
    matches = []
    for container in applications.iterdir():
        try:
            if str(uuid.UUID(container.name)).lower() != container.name.lower():
                continue
        except ValueError:
            continue
        canonical(container)
        path = canonical(container / 'Documents/cksim-inspector-results.json')
        if not path.exists():
            continue
        if not path.is_file():
            raise ValueError('Inspector receipt is not a regular file')
        try:
            value = json.loads(path.read_text())
        except (FileNotFoundError, ValueError, UnicodeError):
            continue
        if not isinstance(value, dict) or value.get('nonce') != nonce:
            continue
        if value.get('inspectorBundleID') != bundle or value.get('inspectorDataContainer') != str(container):
            raise ValueError('Fresh Inspector receipt has foreign bundle or container identity')
        matches.append(path)
    if len(matches) > 1:
        raise ValueError('Ambiguous fresh Inspector receipts')
    return matches[0] if matches else None


def reap_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        # A watchdog-killed zombie may refuse another signal. Reap its leader
        # and prove group absence rather than abandoning the child handle.
        pass
    deadline = time.monotonic() + 2
    process.wait(timeout=2)
    while True:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            pass  # Absence is not established yet.
        if time.monotonic() >= deadline:
            raise RuntimeError('Inspector host launcher group remains after reap')
        time.sleep(.01)


@contextmanager
def deferred_interrupts():
    pending, handlers = [], {}
    def check(before_delivery=None):
        if pending and before_delivery is not None:
            before_delivery()
        while pending:
            signum, frame = pending.pop(0)
            handler = handlers[signum]
            if callable(handler):
                handler(signum, frame)
            elif handler == signal.SIG_DFL:
                raise SystemExit(128 + signum)
    if threading.current_thread() is threading.main_thread():
        handlers = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        if handlers:
            original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set(handlers))
            try:
                for signum, handler in handlers.items():
                    if handler != signal.SIG_IGN:
                        signal.signal(signum, lambda signum, frame: pending.append((signum, frame)))
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
        yield check
    finally:
        primary = sys.exc_info()[1]
        if handlers:
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set(handlers))
            try:
                restoration_error = None
                while True:
                    try:
                        try:
                            signal.signal(signal.SIGTERM, handlers[signal.SIGTERM])
                        finally:
                            signal.signal(signal.SIGINT, handlers[signal.SIGINT])
                        break
                    except BaseException as error:
                        restoration_error = restoration_error or error
                if restoration_error is not None and primary is None:
                    raise restoration_error
            finally:
                mask_error = None
                while True:
                    try:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                        break
                    except BaseException as error:
                        mask_error = mask_error or error
                if mask_error is not None and primary is None:
                    raise mask_error
        if primary is None:
            check()



def supervise_launch(command, *, env, log, observe, bridge_alive, host_timeout,
                     consumer_timeout=None, redactions=(), bundle=None):
    with deferred_interrupts() as interrupt_check:
        return _supervise_launch(command, env=env, log=log, observe=observe, bridge_alive=bridge_alive,
                                 host_timeout=host_timeout, consumer_timeout=consumer_timeout,
                                 redactions=redactions, bundle=bundle, interrupt_check=interrupt_check)


def _supervise_launch(command, *, env, log, observe, bridge_alive, host_timeout,
                      consumer_timeout, redactions, bundle, interrupt_check):
    """Accept an online, caller-validated native ACK only while RPC is pending.

    `observe` must validate identity, freshness and original projection evidence
    on every call. It is called again after the owned host group is absent.
    """
    log = Path(log)
    started = time.monotonic()
    host_deadline = started + host_timeout
    consumer_deadline = started + consumer_timeout if consumer_timeout is not None else None
    ready_deadline = None
    process, ready, reaped = None, None, False
    watchdog, settled = None, False
    ownership_lock = threading.RLock()
    outcome = dict(qualifiedNativeAcknowledgement=False, timedOut=False)
    def expire_host():
        with ownership_lock:
            if not settled:
                outcome['timedOut'] = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except OSError:
                    outcome['watchdogKillFailed'] = True
    def stop_watchdog():
        nonlocal settled
        with ownership_lock:
            settled = True
            if watchdog is not None:
                watchdog.cancel()
        if watchdog is not None and watchdog.ident is not None:
            watchdog.join(timeout=2)
            if watchdog.is_alive():
                raise RuntimeError('Inspector host watchdog did not stop')
    def reap_owned():
        nonlocal reaped
        if process is not None and not reaped:
            try:
                stop_watchdog()
            finally:
                reap_group(process)
                reaped = True
                outcome['reapedWallTimeMS'] = int(time.time() * 1000)
    try:
        with log.open('wb') as stream:
            process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            outcome['hostPID'] = process.pid
            watchdog = threading.Timer(max(0, host_deadline - time.monotonic()), expire_host)
            watchdog.daemon = True
            watchdog.start()
            while True:
                interrupt_check(reap_owned)
                if not bridge_alive():
                    raise RuntimeError('Inspector bridge stopped during native startup')
                if ready_deadline is None and time.monotonic() >= host_deadline:
                    outcome['timedOut'] = True
                    raise RuntimeError('Inspector native launch timed out')
                with ownership_lock:
                    status = process.poll()
                    if status is not None:
                        settled = True
                        watchdog.cancel()
                if status is not None and status != 0:
                    raise RuntimeError('Inspector native launch failed')
                if status == 0 and ready_deadline is None:
                    ready_deadline = time.monotonic() + 10
                    reap_owned()
                deadline = host_deadline if status is None else ready_deadline
                if consumer_deadline is not None:
                    deadline = min(deadline, consumer_deadline)
                value = observe()
                if time.monotonic() >= deadline:
                    outcome['timedOut'] = True
                    raise RuntimeError('Inspector native launch or readiness timed out')
                if value is not None and value.get('online') is True and not value.get('error'):
                    with ownership_lock:
                        status = process.poll()
                        if status is not None:
                            settled = True
                            watchdog.cancel()
                    if outcome['timedOut']:
                        raise RuntimeError('Inspector native launch timed out')
                    if status is not None and status != 0:
                        raise RuntimeError('Inspector host launch failed before native acknowledgement')
                    ready = value
                    outcome['qualifiedNativeAcknowledgement'] = status is None
                    break
                time.sleep(.05)
            reap_owned()
            reaped_wall = outcome['reapedWallTimeMS']
            if process.returncode not in (0, -signal.SIGKILL) or not bridge_alive():
                raise RuntimeError('Inspector host launch failed before qualified acknowledgement')
            if bundle is not None:
                headers = re.findall(rb'(?m)^([A-Za-z0-9_.-]+\.[A-Za-z0-9_.-]+): (\d+)\r?$', log.read_bytes())
                expected = [(bundle.encode(), str(ready['inspectorPID']).encode())]
                if ((headers and headers != expected) or process.returncode == 0 and headers != expected):
                    raise RuntimeError('Inspector native and host PID acknowledgements conflict')
            keys = ('inspectorPID', 'startedWallTimeMS', 'session')
            post_deadline = min(deadline, time.monotonic() + 25 - (time.time() * 1000 - ready['startedWallTimeMS']) / 1000)
            if consumer_deadline is not None:
                post_deadline = min(post_deadline, consumer_deadline)
            while True:
                interrupt_check(reap_owned)
                if not bridge_alive():
                    raise RuntimeError('Inspector bridge stopped after host reap')
                stable = observe(resume_after=reaped_wall)
                if stable is not None:
                    if (any(stable.get(key) != ready.get(key) for key in keys) or stable['cursor'] < ready['cursor']):
                        raise RuntimeError('Inspector native acknowledgement changed after host reap')
                    if stable.get('online') is True and not stable.get('error') and stable.get('wallTimeMS', -1) >= reaped_wall:
                        break
                if time.monotonic() >= post_deadline:
                    raise RuntimeError('Inspector post-reap native publication budget expired')
                time.sleep(.05)
            if time.monotonic() >= post_deadline:
                raise RuntimeError('Inspector consumer background budget expired')
            return stable, consumer_deadline
    finally:
        primary = sys.exc_info()[1]
        cleanup_error = None
        if process is not None and not reaped:
            try:
                reap_owned()
            except Exception as error:
                cleanup_error = error
        if process is not None:
            outcome['hostExitCode'] = process.returncode
        try:
            if log.exists():
                data = log.read_bytes()
                for secret in redactions:
                    if secret:
                        data = data.replace(secret.encode(), b'<redacted>')
                log.write_bytes(data)
            log.with_suffix('.json').write_text(json.dumps(outcome, sort_keys=True) + '\n')
        except OSError as error:
            cleanup_error = cleanup_error or error
        if primary is None and cleanup_error is not None:
            raise cleanup_error


def cleanup_operations(primary, operations):
    """Attempt all runner cleanup stages without replacing a body failure."""
    failures = []
    for operation in operations:
        try:
            operation()
        except Exception as error:
            failures.append(error)
    if primary is None and failures:
        raise failures[0]
