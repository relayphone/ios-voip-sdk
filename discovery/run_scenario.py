#!/usr/bin/env python3
"""Run a probe to its terminal marker, then stop only the run-owned app."""

import argparse
import errno
import hashlib
import json
import math
import os
import re
import select
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time
import tty

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/sim'))
from sim import (Result, Session, clear_failure_marker, console_launch_rejection,
                 failure_is_classified, not_running_error, preapp_rejection,
                 report_failure, summary, terminate_once, transport_failure)


def _launcher_header(bundle):
    return re.compile(rb"(?m)^" + re.escape(bundle.encode()) + rb": (\d+)\r?$") if bundle else None


def _app_evidence(raw, launcher_header):
    return b"PROBE " in raw or bool(launcher_header and launcher_header.search(raw))


def _valid_entry(result, trace, bundle):
    """Require unambiguous protocol evidence before replacing entered EOF with transport."""
    try:
        rows = [json.loads(line.split(b'PROBE ', 1)[1]) for line in trace.splitlines() if b'PROBE ' in line]
    except (ValueError, UnicodeDecodeError):
        return False
    if not all(isinstance(row, dict) and isinstance(row.get('event'), str) and
               type(row.get('t_ms')) is int and row['t_ms'] >= 0 for row in rows):
        return False
    launches = [row for row in rows if row['event'] == 'launch']
    header = _launcher_header(bundle)
    pids = header.findall(trace) if header else []
    app_pid = result.get('appPID')
    identity = {key: result.get(key) for key in ('runID', 'simulatorID', 'bundleID')}
    identity['pid'] = app_pid
    if any(key in row and (bound is None or type(row[key]) is not type(bound) or row[key] != bound)
           for row in rows for key, bound in identity.items()):
        return False
    return (result.get('appEntryObserved') is True and 'identityError' not in result and
            type(app_pid) is int and app_pid > 0 and result.get('launcherAppPID') == app_pid and
            len(pids) == 1 and int(pids[0]) == app_pid and len(launches) == 1 and
            type(launches[0].get('pid')) is int and launches[0]['pid'] == app_pid and
            any(row.get('event') == 'app.entry' for row in rows))


def report_capture_failure(result, trace, timeout, launch_failure=False, termination_failure=False,
                           capture_failure=False):
    """Classify the retained outcome without changing its receipt or replaying it."""
    if not os.environ.get('SIM_FAILURE_MARKER'):
        return  # Offline refusal controls do not represent native job failures.
    bundle = result.get('bundleID')
    if bundle and console_launch_rejection(result, trace, bundle, timeout):
        report_failure('infra:launch', 'completed exact pre-app rejection')
        return
    entered = (_app_evidence(trace, _launcher_header(bundle)) or
               any(key in result for key in ('appPID', 'launcherAppPID', 'appEntryObserved', 'lastProbeEvent')))
    native_status = result.get('launchExitCodeBeforeCleanup')
    if native_status is None and result.get('launchExitCode') not in (
            -signal.SIGTERM, 128 + signal.SIGTERM, -signal.SIGKILL, 128 + signal.SIGKILL):
        # Cleanup can produce TERM/KILL after the pre-cleanup poll. Other native
        # signal exits remain transport evidence even when EOF won that race.
        native_status = result.get('launchExitCode')
    signal_eof = (result.get('error') == 'launcher exited before terminal done event' and
                  _valid_entry(result, trace, bundle))
    transport = (launch_failure or
        (transport_failure(Result([], native_status)) and (not entered or signal_eof)) or
        (not entered and result.get('error') == 'deadline before terminal done event'))
    if transport:
        report_failure('infra:launch', 'launch transport failed; never retried')
    rejected = (bundle and not entered and result['completed'] is False and
        preapp_rejection(Result([], result.get('launchExitCode'), stderr=trace), bundle))
    if rejected:
        report_failure('infra:launch', 'launch rejected without replay proof; never retried')
    absent = (bundle and result.get('cleanupExitCode') == 3 and result.get('cleanupStdout') == '' and
              result.get('cleanupStderr') == not_running_error(bundle) and 'cleanupError' not in result)
    termination_failure = (termination_failure or 'cleanupError' in result or
        ('terminateExitCode' in result and result['terminateExitCode'] != 0) or
        ('cleanupExitCode' in result and result['cleanupExitCode'] != 0 and not absent))
    if not (rejected or transport) and (capture_failure or not termination_failure or (entered and not result['completed'])):
        report_failure('product:' + (result.get('scenario') or 'capture'), 'never retried')
    if termination_failure:
        report_failure('infra:terminate', 'never retried')


def bind_launcher_pid(result, matches):
    if len(matches) != 1:
        result.pop("launcherAppPID", None)
        return f"require one launcher app PID acknowledgement; got {len(matches)}"
    result["launcherAppPID"] = int(matches[0])
    if result["launcherAppPID"] <= 0 or result["launcherAppPID"] != result.get("appPID"):
        return "launcher/probe app PID mismatch"
    return None


def run(launch, terminate, output, receipt, timeout, identity=None, console_launcher_stop=False,
        inherit_launcher_group=False, expected_app_exit=False, checkpoint=None, launched=None,
        capture_deadline=None):
    started = time.monotonic()
    result = {"completed": False, "success": False, "schemaVersion": 2, **(identity or {})}
    process = None
    stopped = False
    launch_failure = termination_failure = capture_failure = False
    messages = queue.Queue()
    reader = None
    reader_stop = threading.Event()
    master = slave = None
    data = b''
    checkpoint_recorded = False
    checkpoint_failure = False
    bundle = result.get("bundleID")
    launcher_header = _launcher_header(bundle)

    def observe_evidence(raw):
        nonlocal checkpoint_recorded, checkpoint_failure
        if checkpoint and not checkpoint_recorded and _app_evidence(raw, launcher_header):
            checkpoint_recorded = True
            try:
                checkpoint()
            except (OSError, ValueError, KeyError, TypeError) as error:
                checkpoint_failure = True
                raise RuntimeError("could not record shared app checkpoint") from error

    try:
        if expected_app_exit and not console_launcher_stop:
            raise RuntimeError("natural app exit requires the bound console launcher")
        if console_launcher_stop and not bundle:
            raise RuntimeError("console launcher stop requires a bound bundle ID")
        if inherit_launcher_group:
            if not console_launcher_stop:
                raise RuntimeError("inherited launcher group requires console launcher stop")
            supervisor = os.getpid()
            group, session = os.getpgid(0), os.getsid(0)
            if supervisor != group or supervisor != session:
                raise RuntimeError("inherited launcher group requires a private session/group leader")
            result.update(inheritLauncherGroup=True, supervisorPID=supervisor,
                          supervisorPGID=group, supervisorSID=session)
        with output.open("xb") as log:
            if console_launcher_stop:
                master, slave = os.openpty()
                tty.setraw(slave)  # Preserve bytes; only the launcher stdout uses this PTY.
                result["consoleTransport"] = "host-pty"
            try:
                try:
                    if capture_deadline is not None and time.monotonic() >= capture_deadline:
                        raise RuntimeError("deadline before terminal done event")
                    process = subprocess.Popen(launch, stdout=slave if console_launcher_stop else subprocess.PIPE,
                                               stderr=subprocess.PIPE if console_launcher_stop else subprocess.STDOUT,
                                               start_new_session=not inherit_launcher_group)
                except OSError:
                    launch_failure = True
                    raise
            finally:
                if slave is not None:
                    os.close(slave)
                    slave = None
            result["launcherPID"] = process.pid
            if launched:
                launched(process)
            if inherit_launcher_group:
                result["launcherPGID"] = os.getpgid(process.pid)
                if result["launcherPGID"] != result["supervisorPGID"]:
                    raise RuntimeError("console launcher did not inherit its owned group")
            read_fds = [master, process.stderr.fileno()] if console_launcher_stop else [process.stdout.fileno()]

            def read():
                pending = {fd: b"" for fd in read_fds}
                active = set(read_fds)
                try:
                    while active and not reader_stop.is_set():
                        ready, _, _ = select.select(list(active), [], [], .1)
                        for fd in ready:
                            try:
                                chunk = os.read(fd, 65536)
                            except OSError as error:
                                if fd != master or error.errno != errno.EIO:
                                    raise
                                chunk = b""  # A closed PTY can report EIO instead of EOF.
                            if not chunk:
                                if pending[fd]:
                                    messages.put(pending[fd])
                                    pending[fd] = b""
                                active.remove(fd)
                                continue
                            pending[fd] += chunk
                            while b"\n" in pending[fd]:
                                line, pending[fd] = pending[fd].split(b"\n", 1)
                                messages.put(line + b"\n")
                    for tail in pending.values():
                        if tail:
                            messages.put(tail)
                except OSError as error:
                    messages.put(error)
                finally:
                    if console_launcher_stop:
                        try:
                            os.close(master)
                        except OSError as error:
                            messages.put(error)
                    for stream in (process.stdout, process.stderr):
                        if stream is not None:
                            try:
                                stream.close()
                            except OSError as error:
                                messages.put(error)
                    messages.put(None)  # Both streams have closed, or the reader failed.

            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            deadline = capture_deadline if capture_deadline is not None else started + timeout
            while not result["completed"]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("deadline before terminal done event")
                try:
                    line = messages.get(timeout=min(remaining, 0.2))
                except queue.Empty:
                    continue
                if isinstance(line, OSError):
                    raise line
                if line is None:
                    result["stdoutEOFSeconds"] = round(time.monotonic() - started, 3)
                    if expected_app_exit: break
                    raise RuntimeError("launcher exited before terminal done event")
                log.write(line)
                log.flush()
                observe_evidence(line)
                if b"PROBE " in line:
                    try:
                        row = json.loads(line.split(b"PROBE ", 1)[1])
                    except (ValueError, UnicodeDecodeError):
                        continue  # The conformance parser rejects malformed evidence.
                    if isinstance(row, dict) and row.get("event") == "done":
                        if expected_app_exit: raise RuntimeError("expected app exit received terminal done event")
                        result["completed"] = True
                    if isinstance(row, dict):
                        result["lastProbeEvent"] = row.get("event")
                        result["lastProbeTimestampMS"] = row.get("t_ms")
                    if isinstance(row, dict) and row.get("event") == "app.entry":
                        result["appEntryObserved"] = True
                    if isinstance(row, dict) and row.get("event") == "launch" and type(row.get("pid")) is int:
                        result["appPID"] = row["pid"]

            if expected_app_exit:
                result["expectedAppExit"] = True
                result["terminationMethod"] = "natural-app-exit"
                result["launchExitCode"] = process.wait(timeout=2)
                # This is the launcher status, not an inferred simulator-app status.
                if result["launchExitCode"] not in (0, 78):
                    raise RuntimeError("unexpected natural-exit launcher status")
                identity_error = bind_launcher_pid(result, launcher_header.findall(output.read_bytes()))
                if identity_error: raise RuntimeError(identity_error)
                absence_deadline = time.monotonic() + 2
                while True:
                    try: os.kill(result["appPID"], 0)
                    except ProcessLookupError: break
                    if time.monotonic() >= absence_deadline:
                        raise RuntimeError("run-owned app remains alive before natural-exit cleanup")
                    time.sleep(.02)
                result["appAbsentBeforeCleanup"] = True
                result["appAbsenceMethod"] = "signal-zero"
                stopped = True
                result["success"] = True
            else:
                # SwiftUI intentionally stays alive after the scenario. A stop is
                # accepted only after done and a successful termination of our app.
                # simctl may flush its PID header only after termination; bind that
                # identity after draining the launcher, before accepting success.
                reply_terminal = []
                if console_launcher_stop:
                    result["terminationMethod"] = "console-launcher-signal"
                    # Let an in-flight launcher reply arrive, without requiring it
                    # before stop: some launchers emit their header only after exit.
                    reply_deadline = min(deadline, time.monotonic() + 2)
                    have_reply = bool(launcher_header.search(output.read_bytes()))
                    while not have_reply:
                        remaining = reply_deadline - time.monotonic()
                        if remaining <= 0:
                            break
                        try:
                            line = messages.get(timeout=remaining)
                        except queue.Empty:
                            break
                        if line is None or isinstance(line, OSError):
                            reply_terminal.append(line)
                            break
                        log.write(line)
                        log.flush()
                        have_reply = bool(launcher_header.search(line))
                    if process.poll() is not None:
                        raise RuntimeError("console launcher exited before owned stop signal")
                    # simctl launch --console[-pty] documents forwarding received
                    # signals to its app. Signal only this invocation's Popen PID.
                    result["terminationSignal"] = signal.SIGTERM
                    try:
                        os.kill(process.pid, signal.SIGTERM)
                    except OSError:
                        termination_failure = True
                        raise
                    result["terminationSignalDelivered"] = True
                else:
                    try:
                        stop = terminate_once(terminate, 20, subprocess.run)
                    except (OSError, subprocess.TimeoutExpired):
                        termination_failure = True
                        raise
                    result["terminateExitCode"] = stop.returncode
                    if stop.returncode:
                        termination_failure = True
                        raise RuntimeError("failed to terminate completed run-owned app")
                    stopped = True
                try:
                    result["launchExitCode"] = process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    termination_failure = True
                    if console_launcher_stop:
                        raise RuntimeError("console launcher did not exit after stop signal")
                    raise
                if result["launchExitCode"] not in (0, -signal.SIGTERM, 128 + signal.SIGTERM):
                    raise RuntimeError(f"unexpected launcher exit: {result['launchExitCode']}")
                drain_deadline = time.monotonic() + 5 if console_launcher_stop else None
                while True:
                    remaining = drain_deadline - time.monotonic() if drain_deadline is not None else 5
                    if remaining <= 0:
                        termination_failure = True
                        raise RuntimeError("launcher output did not close after stop")
                    try:
                        line = reply_terminal.pop() if reply_terminal else messages.get(timeout=remaining)
                    except queue.Empty:
                        termination_failure = True
                        raise RuntimeError("launcher output did not close after stop")
                    if isinstance(line, OSError):
                        termination_failure = True
                        raise line
                    if line is None:
                        break
                    log.write(line)
                if console_launcher_stop:
                    log.flush()
                    identity_error = bind_launcher_pid(result, launcher_header.findall(output.read_bytes()))
                    if identity_error:
                        raise RuntimeError(identity_error)
                    result["appAbsenceMethod"] = "signal-zero"
                    result["appAbsentAfterStop"] = False
                    absence_deadline = time.monotonic() + 2
                    while True:
                        try:
                            os.kill(result["appPID"], 0)
                        except ProcessLookupError:
                            result["appAbsentAfterStop"] = True
                            break
                        if time.monotonic() >= absence_deadline:
                            termination_failure = True
                            raise RuntimeError("run-owned app PID still exists after console stop")
                        time.sleep(.02)
                    stopped = True
                result["success"] = True
    except (OSError, RuntimeError, subprocess.TimeoutExpired, queue.Empty) as error:
        result["error"] = str(error)
        if not launch_failure and not termination_failure:
            capture_failure = True
    finally:
        try:
            if process is not None:
                # Preserve the observed launcher state before cleanup can signal it.
                result["launchExitCodeBeforeCleanup"] = process.poll()
                # The launcher can exit while the app it launched remains alive.
                if not stopped:
                    try:
                        stop = terminate_once(terminate, 10, subprocess.run)
                        result["cleanupExitCode"] = stop.returncode
                        for field in ("stdout", "stderr"):
                            raw = getattr(stop, field, None)
                            result["cleanup" + field.capitalize()] = raw.decode(errors="backslashreplace") if isinstance(raw, bytes) else None
                    except (OSError, subprocess.TimeoutExpired) as error:
                        result["cleanupError"] = str(error)
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired) as error:
            result["cleanupError"] = str(error)
            result["success"] = False
        finally:
            if process is not None:
                result["launchExitCode"] = process.returncode
        reader_started = reader is not None and reader.ident is not None
        if reader_started:
            # Let closed streams reach EOF within the existing reader budget so
            # shutdown-flushed bytes are queued before requesting a reader stop.
            reader.join(timeout=1)
            if reader.is_alive():
                result["success"] = False
                result["cleanupError"] = "console reader did not stop"
        reader_stop.set()
        if reader_started and not result["success"]:
            # Diagnostic tail only: late protocol rows cannot change the outcome.
            # Bound retained bytes without waiting for output or touching its FDs.
            remaining = 65536
            with output.open("ab") as log:
                while remaining:
                    try:
                        tail = messages.get_nowait()
                    except queue.Empty:
                        break
                    if isinstance(tail, bytes):
                        tail = tail[:remaining]
                        log.write(tail)
                        remaining -= len(tail)
        # A started reader owns its descriptor until exit, including a failed join.
        # Never close/reuse that descriptor underneath a still-running reader.
        if master is not None and not reader_started:
            os.close(master)
        if slave is not None:
            os.close(slave)
        if not reader_started and process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        result["elapsedSeconds"] = round(time.monotonic() - started, 3)
        if output.exists():
            data = output.read_bytes()
            try:
                observe_evidence(data)
            except RuntimeError as error:
                result["success"] = False
                result.setdefault("error", str(error))
            result["traceSHA256"] = hashlib.sha256(data).hexdigest()
            if bundle:
                identity_error = bind_launcher_pid(result, launcher_header.findall(data))
                if identity_error:
                    result["success"] = False
                    capture_failure = True
                    if "error" in result:
                        if result["error"] != identity_error:
                            result["identityError"] = identity_error
                    else:
                        result["error"] = identity_error
        receipt.write_text(json.dumps(result, indent=2) + "\n")
    if not result['success']:
        if checkpoint_failure:
            if os.environ.get('SIM_FAILURE_MARKER'):
                report_failure('infra:helper', 'checkpoint state unavailable; never retried')
        else:
            report_capture_failure(result, data, timeout,
                                   launch_failure, termination_failure, capture_failure)
    return 0 if result["success"] else 1


def run_with_session(launch, terminate, output, receipt, timeout, identity,
                     console_launcher_stop=False, inherit_launcher_group=False, session=None):
    """Keep direct native capture, sharing only the parent's pre-app budget."""
    if session is None:
        return run(launch, terminate, output, receipt, timeout, identity,
                   console_launcher_stop=console_launcher_stop,
                   inherit_launcher_group=inherit_launcher_group)
    deadline = time.monotonic() + timeout
    prior_failure = failure_is_classified()
    owners = []
    status = run(launch, terminate, output, receipt, timeout, identity,
                 console_launcher_stop=console_launcher_stop, inherit_launcher_group=inherit_launcher_group,
                 checkpoint=session.checkpoint, launched=owners.append, capture_deadline=deadline)
    if not status or prior_failure or inherit_launcher_group or not console_launcher_stop:
        return status
    try:
        # Restrict generic recovery to the run-owned direct simctl launch. Push
        # launchers and inherited SDK supervisors retain their stricter owner.
        position = 3
        flags = {'--console', '--terminate-running-process'}
        while position < len(launch) and launch[position] in flags:
            position += 1
        bundle = identity.get('bundleID')
        direct = (launch[:3] == ['xcrun', 'simctl', 'launch'] and '--console' in launch[3:position] and
                  launch[position:position + 2] == [session.current, bundle] and
                  terminate == ['xcrun', 'simctl', 'terminate', session.current, bundle])
        if not direct or not all(identity.get(key) for key in ('runID', 'simulatorID', 'scenario', 'bundleID')):
            return status
        receipt_bytes, trace_bytes = receipt.read_bytes(), output.read_bytes()
        value = json.loads(receipt_bytes)
        process = owners[0] if len(owners) == 1 else None
        eligible = (process is not None and process.poll() == 3 and
                    value.get('launcherPID') == process.pid and type(value.get('launcherPID')) is int and
                    process.pid > 0 and process.pid != os.getpid() and
                    console_launch_rejection(value, trace_bytes, bundle, timeout) and
                    all(value.get(key) == identity[key] for key in ('runID', 'simulatorID', 'scenario', 'bundleID')))
        if not eligible or time.monotonic() >= deadline:
            return status
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            return status
        if not session.reserve_retry():
            if os.environ.get('SIM_FAILURE_MARKER'):
                report_failure('infra:launch', 'exhausted (shared pre-app retry unavailable)')
            return status
        # Reservation is permanent, including archive failure or late evidence.
        archived = Path(str(output) + '.preapp-attempt-1')
        archived.mkdir()
        for path in (output, receipt):
            path.rename(archived / path.name)
        fresh = ((archived / output.name).read_bytes() == trace_bytes and
                 (archived / receipt.name).read_bytes() == receipt_bytes and
                 not output.exists() and not receipt.exists() and
                 session.current == identity['simulatorID'] and not session.is_checkpointed())
        remaining = deadline - time.monotonic()
        if not fresh or remaining <= 0:
            return status
        summary('infra:launch', 'scheduled (one shared pre-app retry)')
        clear_failure_marker()
        remaining = deadline - time.monotonic()
        if remaining <= 0 or session.is_checkpointed():
            report_failure('infra:launch', 'exhausted before shared pre-app replay')
            return status
        status = run(launch, terminate, output, receipt, remaining, identity,
                     console_launcher_stop=console_launcher_stop, inherit_launcher_group=inherit_launcher_group,
                     checkpoint=session.checkpoint,
                     capture_deadline=deadline)
        summary('infra:launch', 'exhausted' if status else 'recovered (one shared pre-app retry)')
        return status
    except (OSError, ValueError, TypeError, KeyError):
        # The first attempt remains authoritative when any recovery proof or
        # archive operation is unknown. Never convert that uncertainty to replay.
        if os.environ.get('SIM_FAILURE_MARKER') and not failure_is_classified():
            report_failure('infra:helper', 'shared recovery unavailable; never retried')
        return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=200)
    parser.add_argument("--run-id")
    parser.add_argument("--simulator-id")
    parser.add_argument("--scenario")
    parser.add_argument("--bundle-id")
    parser.add_argument("--sim-state", type=Path, default=os.environ.get('SIM_STATE'),
                        help="attach to the parent runner's existing simulator session")
    parser.add_argument("--console-launcher-stop", action="store_true",
                        help="use a raw host PTY; after done, signal this launcher PID and require its sole app PID acknowledgement and absence")
    parser.add_argument("--inherit-launcher-group", action="store_true",
                        help="inherit this supervisor's verified private session/group; console mode only")
    parser.add_argument("--terminate-command", nargs="+", required=True)
    parser.add_argument("--launch-command", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    if not args.launch_command or not math.isfinite(args.timeout) or args.timeout <= 0 or args.receipt.exists():
        parser.error("require a launch command, positive timeout, and fresh receipt path")
    if args.console_launcher_stop and not args.bundle_id:
        parser.error("--console-launcher-stop requires --bundle-id")
    if args.inherit_launcher_group and not args.console_launcher_stop:
        parser.error("--inherit-launcher-group requires --console-launcher-stop")
    try:
        session = Session.attach(args.sim_state, args.simulator_id) if args.sim_state else None
    except (OSError, ValueError, KeyError, TypeError):
        if os.environ.get('SIM_FAILURE_MARKER'):
            report_failure('infra:helper', 'cannot attach to the owned simulator session; never retried')
        print('Cannot attach to the owned simulator session', file=sys.stderr)
        return 1
    return run_with_session(args.launch_command, args.terminate_command, args.output, args.receipt, args.timeout,
               dict(runID=args.run_id, simulatorID=args.simulator_id, scenario=args.scenario, bundleID=args.bundle_id),
               console_launcher_stop=args.console_launcher_stop, inherit_launcher_group=args.inherit_launcher_group,
               session=session)


if __name__ == "__main__":
    raise SystemExit(main())
