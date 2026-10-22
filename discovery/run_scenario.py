#!/usr/bin/env python3
"""Run a probe to its terminal marker, then stop only the run-owned app."""

import argparse
import hashlib
import json
import math
import os
import re
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time


def bind_launcher_pid(result, matches):
    if len(matches) != 1:
        result.pop("launcherAppPID", None)
        return f"require one launcher app PID acknowledgement; got {len(matches)}"
    result["launcherAppPID"] = int(matches[0])
    if result["launcherAppPID"] <= 0 or result["launcherAppPID"] != result.get("appPID"):
        return "launcher/probe app PID mismatch"
    return None


def run(launch, terminate, output, receipt, timeout, identity=None, console_launcher_stop=False):
    started = time.monotonic()
    result = {"completed": False, "success": False, "schemaVersion": 2, **(identity or {})}
    process = None
    stopped = False
    messages = queue.Queue()
    bundle = result.get("bundleID")
    launcher_header = re.compile(rb"(?m)^" + re.escape(bundle.encode()) + rb": (\d+)\r?$") if bundle else None
    try:
        if console_launcher_stop and not bundle:
            raise RuntimeError("console launcher stop requires a bound bundle ID")
        with output.open("xb") as log:
            process = subprocess.Popen(launch, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            result["launcherPID"] = process.pid

            def read():
                try:
                    for line in iter(process.stdout.readline, b""):
                        messages.put(line)
                finally:
                    messages.put(None)

            threading.Thread(target=read, daemon=True).start()
            deadline = started + timeout
            while not result["completed"]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("deadline before terminal done event")
                try:
                    line = messages.get(timeout=min(remaining, 0.2))
                except queue.Empty:
                    continue
                if line is None:
                    result["stdoutEOFSeconds"] = round(time.monotonic() - started, 3)
                    raise RuntimeError("launcher exited before terminal done event")
                log.write(line)
                log.flush()
                if b"PROBE " in line:
                    try:
                        row = json.loads(line.split(b"PROBE ", 1)[1])
                    except (ValueError, UnicodeDecodeError):
                        continue  # The conformance parser rejects malformed evidence.
                    if isinstance(row, dict) and row.get("event") == "done":
                        result["completed"] = True
                    if isinstance(row, dict):
                        result["lastProbeEvent"] = row.get("event")
                        result["lastProbeTimestampMS"] = row.get("t_ms")
                    if isinstance(row, dict) and row.get("event") == "app.entry":
                        result["appEntryObserved"] = True
                    if isinstance(row, dict) and row.get("event") == "launch" and type(row.get("pid")) is int:
                        result["appPID"] = row["pid"]

            # SwiftUI intentionally stays alive after the scenario. A stop is
            # accepted only after done and a successful termination of our app.
            # simctl may flush its PID header only after termination; bind that
            # identity after draining the launcher, before accepting success.
            if console_launcher_stop:
                result["terminationMethod"] = "console-launcher-signal"
                if process.poll() is not None:
                    raise RuntimeError("console launcher exited before owned stop signal")
                # simctl launch --console[-pty] documents forwarding received
                # signals to its app. Signal only this invocation's Popen PID.
                result["terminationSignal"] = signal.SIGTERM
                os.kill(process.pid, signal.SIGTERM)
                result["terminationSignalDelivered"] = True
            else:
                stop = subprocess.run(terminate, capture_output=True, timeout=20)
                result["terminateExitCode"] = stop.returncode
                if stop.returncode:
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
                    line = messages.get(timeout=remaining)
                except queue.Empty:
                    raise RuntimeError("launcher output did not close after stop")
                if line is None:
                    break
                log.write(line)
            if console_launcher_stop:
                log.flush()
                identity_error = bind_launcher_pid(result, launcher_header.findall(output.read_bytes()))
                if identity_error:
                    raise RuntimeError(identity_error)
                stopped = True
            result["success"] = True
    except (OSError, RuntimeError, subprocess.TimeoutExpired, queue.Empty) as error:
        result["error"] = str(error)
    finally:
        if process is not None:
            # Preserve the observed launcher state before cleanup can signal it.
            result["launchExitCodeBeforeCleanup"] = process.poll()
            # The launcher can exit while the app it launched remains alive.
            if not stopped:
                try:
                    stop = subprocess.run(terminate, capture_output=True, timeout=10)
                    result["cleanupExitCode"] = stop.returncode
                except (OSError, subprocess.TimeoutExpired) as error:
                    result["cleanupError"] = str(error)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:
                    process.terminate()
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                except OSError as error:
                    result["cleanupError"] = str(error)
                    result["success"] = False
            result["launchExitCode"] = process.returncode
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
        receipt.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["success"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=200)
    parser.add_argument("--run-id")
    parser.add_argument("--simulator-id")
    parser.add_argument("--scenario")
    parser.add_argument("--bundle-id")
    parser.add_argument("--console-launcher-stop", action="store_true",
                        help="after done, signal this console launcher's PID; require its final app PID acknowledgement")
    parser.add_argument("--terminate-command", nargs="+", required=True)
    parser.add_argument("--launch-command", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    if not args.launch_command or not math.isfinite(args.timeout) or args.timeout <= 0 or args.receipt.exists():
        parser.error("require a launch command, positive timeout, and fresh receipt path")
    if args.console_launcher_stop and not args.bundle_id:
        parser.error("--console-launcher-stop requires --bundle-id")
    return run(args.launch_command, args.terminate_command, args.output, args.receipt, args.timeout,
               dict(runID=args.run_id, simulatorID=args.simulator_id, scenario=args.scenario, bundleID=args.bundle_id),
               console_launcher_stop=args.console_launcher_stop)


if __name__ == "__main__":
    raise SystemExit(main())
