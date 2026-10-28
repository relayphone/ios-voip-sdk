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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/sim"))
from sim import bounded



class HostTiming:
    """Bounded observational clocks, flushed only after capture/cleanup finishes."""
    FIELDS = frozenset(('pid', 'appWallTimeMS', 'appElapsedMS', 'timeoutSeconds',
                        'deadlineMonotonicNS', 'returncode', 'byteCount'))

    def __init__(self, output, source, bundle=None):
        self.path = Path(str(output) + '.host-timing.jsonl')
        self.source, self.events, self.seen = source, [], set()
        self.header = re.compile(rb'(?m)^' + re.escape(bundle.encode()) + rb': (\d+)\r?$') if bundle else None

    def record(self, event, **fields):
        try:
            if len(self.events) >= 128: return
            row = dict(schemaVersion=1, source=self.source, event=event,
                       monotonicNS=time.monotonic_ns(), wallTimeNS=time.time_ns(), hostPID=os.getpid())
            row.update({key: value for key, value in fields.items() if key in self.FIELDS and
                        type(value) in (int, float) and math.isfinite(value)})
            self.events.append(row)
        except Exception:
            pass  # Diagnostic clock failure cannot change capture or cleanup.

    def first(self, event, **fields):
        if event not in self.seen:
            self.seen.add(event)
            self.record(event, **fields)

    def observe_row(self, row, stage):
        if isinstance(row, dict) and row.get('event') in ('app.entry', 'launch', 'livekit.readyForFault'):
            self.first(stage + '.' + row['event'], pid=row.get('pid'),
                       appWallTimeMS=row.get('wallTimeMS'), appElapsedMS=row.get('t_ms'))

    def observe_line(self, line, stage):
        try:
            if self.header:
                match = self.header.search(line)
                if match: self.first(stage + '.pid', pid=int(match[1]))
            if b'PROBE ' in line:
                self.observe_row(json.loads(line.split(b'PROBE ', 1)[1].decode('utf-8')), stage)
        except Exception:
            pass  # These observations never qualify app identity or receipt success.

    def checkpoint(self, label, action, timeout):
        self.record(label + '.checkpoint.start', timeoutSeconds=timeout)
        try:
            result = action()
        except BaseException as error:
            self.record(label + ('.checkpoint.timeout' if isinstance(error, RuntimeError) and
                        str(error) == 'fixture checkpoint deadline' else '.checkpoint.failure'))
            raise
        self.record(label + '.checkpoint.observed')
        return result

    def flush(self):
        descriptor = None
        try:
            data = b''.join((json.dumps(row, separators=(',', ':'), allow_nan=False) + '\n').encode()
                            for row in tuple(self.events))
            descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
            os.write(descriptor, data)
        except Exception:
            pass  # Missing diagnostic evidence is not a different product outcome.
        finally:
            if descriptor is not None:
                try: os.close(descriptor)
                except OSError: pass

    def __enter__(self):
        self.record('start')
        return self

    def __exit__(self, *_):
        self.flush()


def bind_launcher_pid(result, matches):
    if len(matches) != 1:
        result.pop("launcherAppPID", None)
        return f"require one launcher app PID acknowledgement; got {len(matches)}"
    result["launcherAppPID"] = int(matches[0])
    if result["launcherAppPID"] <= 0 or result["launcherAppPID"] != result.get("appPID"):
        return "launcher/probe app PID mismatch"
    return None


def report_timeout(label):
    # Classification is observational; it must never replace the capture result.
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/sim'))
        from sim import report_failure
        report_failure(label, 'never retried')
        return True
    except Exception:
        return False


def run(launch, terminate, output, receipt, timeout, identity=None, console_launcher_stop=False,
        inherit_launcher_group=False, expected_app_exit=False, startup_timeout=None):
    if startup_timeout is not None and (type(startup_timeout) not in (int, float) or
                                        not math.isfinite(startup_timeout) or startup_timeout <= 0):
        raise ValueError('startup timeout must be positive and finite')
    started = time.monotonic()
    timing = HostTiming(output, 'supervisor', (identity or {}).get('bundleID'))
    initial_budget = startup_timeout if startup_timeout is not None else timeout
    timing.record('start', timeoutSeconds=initial_budget, deadlineMonotonicNS=int((started + initial_budget) * 1e9))
    result = {"completed": False, "success": False, "schemaVersion": 2, **(identity or {})}
    process = None
    stopped = False
    messages = queue.Queue()
    reader = None
    reader_stop = threading.Event()
    master = slave = None
    bundle = result.get("bundleID")
    launcher_header = re.compile(rb"(?m)^" + re.escape(bundle.encode()) + rb": (\d+)\r?$") if bundle else None

    def unpack(value):
        if isinstance(value, tuple):
            return value
        return value, time.monotonic()

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
                timing.record('launch.spawn.start')
                process = subprocess.Popen(launch, stdout=slave if console_launcher_stop else subprocess.PIPE,
                                           stderr=subprocess.PIPE if console_launcher_stop else subprocess.STDOUT,
                                           start_new_session=not inherit_launcher_group)
            finally:
                if slave is not None:
                    os.close(slave)
                    slave = None
            timing.record('launch.spawn.end', pid=process.pid)
            result["launcherPID"] = process.pid
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
                                    timing.observe_line(pending[fd], 'read')
                                    messages.put((pending[fd], time.monotonic()))
                                    pending[fd] = b""
                                active.remove(fd)
                                continue
                            timing.first('read.first.bytes', byteCount=len(chunk))
                            pending[fd] += chunk
                            while b"\n" in pending[fd]:
                                line, pending[fd] = pending[fd].split(b"\n", 1)
                                timing.observe_line(line, 'read')
                                messages.put((line + b"\n", time.monotonic()))
                    for tail in pending.values():
                        if tail:
                            timing.observe_line(tail, 'read')
                            messages.put((tail, time.monotonic()))
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
            deadline = started + initial_budget
            entry_observed = False
            entry_timestamp = None

            def timed_out(phase):
                timing.record(phase + '.deadline')
                if startup_timeout is not None:
                    result['timeoutReason'] = phase
                    result['failureClass'] = 'infra:startup' if phase == 'startup' else 'infra:capture'
                raise RuntimeError("deadline before " + ('app entry' if phase == 'startup' else 'terminal done event'))

            while not result["completed"]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out('startup' if startup_timeout is not None and not entry_observed else 'capture')
                try:
                    line = messages.get(timeout=min(remaining, 0.2))
                except queue.Empty:
                    continue
                line, observed = unpack(line)
                if startup_timeout is not None and observed >= deadline:
                    timed_out('startup' if not entry_observed else 'capture')
                if isinstance(line, OSError):
                    raise line
                if line is None:
                    result["stdoutEOFSeconds"] = round(time.monotonic() - started, 3)
                    if expected_app_exit: break
                    raise RuntimeError("launcher exited before terminal done event")
                timing.observe_line(line, 'consume')
                log.write(line)
                log.flush()
                if b"PROBE " in line:
                    try:
                        row = json.loads(line.split(b"PROBE ", 1)[1])
                    except (ValueError, UnicodeDecodeError):
                        continue  # The conformance parser rejects malformed evidence.
                    if isinstance(row, dict) and row.get("event") == "app.entry" and startup_timeout is not None:
                        if any(not result.get(key) or row.get(key) != result[key]
                               for key in ('runID', 'simulatorID', 'bundleID')) or type(row.get('pid')) is not int or row['pid'] <= 0:
                            raise RuntimeError("invalid app.entry identity")
                        if not entry_observed:
                            entry_timestamp = row.get('t_ms')
                            if type(entry_timestamp) not in (int, float) or not math.isfinite(entry_timestamp):
                                raise RuntimeError("invalid app.entry timestamp")
                            entry_observed = True
                            deadline = observed + timeout
                            result['captureStart'] = 'observed-app-entry'
                            timing.record('capture.start', timeoutSeconds=timeout,
                                          deadlineMonotonicNS=int(deadline * 1e9))
                    if isinstance(row, dict) and row.get("event") == "done":
                        if startup_timeout is not None:
                            if not entry_observed:
                                raise RuntimeError("terminal done event before app entry")
                            native_done = row.get('t_ms')
                            if type(native_done) not in (int, float) or not math.isfinite(native_done) or native_done < entry_timestamp:
                                raise RuntimeError("invalid terminal timestamp")
                            if native_done - entry_timestamp >= timeout * 1000:
                                timed_out('capture')
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
                        line, _ = unpack(line)
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
                    os.kill(process.pid, signal.SIGTERM)
                    result["terminationSignalDelivered"] = True
                else:
                    stop = bounded(terminate, 20)
                    result["terminateExitCode"] = stop.returncode
                    if stop.returncode or stop.timed_out or stop.cleanup_uncertain or not stop.reaped:
                        raise RuntimeError("failed to terminate completed run-owned app")
                    stopped = True
                try:
                    result["launchExitCode"] = process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    if console_launcher_stop:
                        raise RuntimeError("console launcher did not exit after stop signal")
                    raise
                if result["launchExitCode"] not in (0, -signal.SIGTERM, 128 + signal.SIGTERM):
                    raise RuntimeError(f"unexpected launcher exit: {result['launchExitCode']}")
                drain_deadline = time.monotonic() + 5 if console_launcher_stop else None
                while True:
                    remaining = drain_deadline - time.monotonic() if drain_deadline is not None else 5
                    if remaining <= 0:
                        raise RuntimeError("launcher output did not close after stop")
                    try:
                        line = reply_terminal.pop() if reply_terminal else messages.get(timeout=remaining)
                    except queue.Empty:
                        raise RuntimeError("launcher output did not close after stop")
                    line, _ = unpack(line)
                    if isinstance(line, OSError):
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
                            raise RuntimeError("run-owned app PID still exists after console stop")
                        time.sleep(.02)
                    stopped = True
                result["success"] = True
    except (OSError, RuntimeError, subprocess.TimeoutExpired, queue.Empty) as error:
        result["error"] = str(error)
        if result.get('failureClass'):
            result['failureReported'] = report_timeout(result['failureClass'])
    finally:
        timing.record('cleanup.start')
        try:
            if process is not None:
                # Preserve the observed launcher state before cleanup can signal it.
                result["launchExitCodeBeforeCleanup"] = process.poll()
                # The launcher can exit while the app it launched remains alive.
                if not stopped:
                    try:
                        stop = bounded(terminate, 10)
                        if stop.timed_out or stop.cleanup_uncertain or not stop.reaped:
                            result["cleanupError"] = "terminate transport timed out or cleanup is uncertain"
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
                    tail, _ = unpack(tail)
                    if isinstance(tail, bytes):
                        tail = tail[:remaining]
                        timing.first('diagnostic_tail.first.bytes', byteCount=len(tail))
                        timing.observe_line(tail, 'diagnostic_tail')
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
            result["traceSHA256"] = hashlib.sha256(data).hexdigest()
            if bundle:
                identity_error = bind_launcher_pid(result, launcher_header.findall(data))
                if identity_error:
                    result["success"] = False
                    if "error" in result:
                        if result["error"] != identity_error:
                            result["identityError"] = identity_error
                    else:
                        result["error"] = identity_error
        timing.record('cleanup.end', returncode=process.returncode if process is not None else None)
        try:
            receipt.write_text(json.dumps(result, indent=2) + "\n")
        finally:
            timing.flush()
    return 0 if result["success"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=200)
    parser.add_argument("--startup-timeout", type=float, help="separate launch-to-observed-entry bound; --timeout begins at entry")
    parser.add_argument("--run-id")
    parser.add_argument("--simulator-id")
    parser.add_argument("--scenario")
    parser.add_argument("--bundle-id")
    parser.add_argument("--console-launcher-stop", action="store_true",
                        help="use a raw host PTY; after done, signal this launcher PID and require its sole app PID acknowledgement and absence")
    parser.add_argument("--inherit-launcher-group", action="store_true",
                        help="inherit this supervisor's verified private session/group; console mode only")
    parser.add_argument("--terminate-command", nargs="+", required=True)
    parser.add_argument("--launch-command", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    if not args.launch_command or not math.isfinite(args.timeout) or args.timeout <= 0 or args.receipt.exists():
        parser.error("require a launch command, positive timeout, and fresh receipt path")
    if args.startup_timeout is not None and (not math.isfinite(args.startup_timeout) or args.startup_timeout <= 0):
        parser.error("startup timeout must be positive and finite")
    if args.console_launcher_stop and not args.bundle_id:
        parser.error("--console-launcher-stop requires --bundle-id")
    if args.inherit_launcher_group and not args.console_launcher_stop:
        parser.error("--inherit-launcher-group requires --console-launcher-stop")
    return run(args.launch_command, args.terminate_command, args.output, args.receipt, args.timeout,
               dict(runID=args.run_id, simulatorID=args.simulator_id, scenario=args.scenario, bundleID=args.bundle_id),
               console_launcher_stop=args.console_launcher_stop, inherit_launcher_group=args.inherit_launcher_group,
               startup_timeout=args.startup_timeout)


if __name__ == "__main__":
    raise SystemExit(main())
