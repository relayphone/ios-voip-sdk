#!/usr/bin/env python3
"""Run a probe to its terminal marker, then stop only the run-owned app."""

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time


def run(launch, terminate, output, receipt, timeout, identity=None):
    started = time.monotonic()
    result = {"completed": False, "success": False, "schemaVersion": 2, **(identity or {})}
    process = None
    stopped = False
    messages = queue.Queue()
    bundle = result.get("bundleID")
    launcher_header = re.compile(rb"(?m)^" + re.escape(bundle.encode()) + rb": (\d+)\r?$") if bundle else None
    launcher_app_pids = []
    try:
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
            # A fast probe can finish before simctl acknowledges its app PID.
            while not result["completed"] or (bundle and "launcherAppPID" not in result):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    awaiting = "launcher app PID acknowledgement" if result["completed"] else "terminal done event"
                    raise RuntimeError("deadline before " + awaiting)
                try:
                    line = messages.get(timeout=min(remaining, 0.2))
                except queue.Empty:
                    continue
                if line is None:
                    result["stdoutEOFSeconds"] = round(time.monotonic() - started, 3)
                    awaiting = "launcher app PID acknowledgement" if result["completed"] else "terminal done event"
                    raise RuntimeError("launcher exited before " + awaiting)
                log.write(line)
                log.flush()
                if launcher_header:
                    launcher_app_pids.extend(int(pid) for pid in launcher_header.findall(line))
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
                if len(launcher_app_pids) > 1:
                    raise RuntimeError(f"require one launcher app PID acknowledgement; got {len(launcher_app_pids)}")
                if launcher_app_pids and "appPID" in result:
                    if launcher_app_pids[0] <= 0 or launcher_app_pids[0] != result["appPID"]:
                        raise RuntimeError("launcher/probe app PID mismatch")
                    result["launcherAppPID"] = launcher_app_pids[0]

            # SwiftUI intentionally stays alive after the scenario. A stop is
            # accepted only after done and a successful termination of our app.
            stop = subprocess.run(terminate, capture_output=True, timeout=20)
            result["terminateExitCode"] = stop.returncode
            if stop.returncode:
                raise RuntimeError("failed to terminate completed run-owned app")
            stopped = True
            result["launchExitCode"] = process.wait(timeout=15)
            if result["launchExitCode"] not in (0, -signal.SIGTERM, 128 + signal.SIGTERM):
                raise RuntimeError(f"unexpected launcher exit: {result['launchExitCode']}")
            while True:
                line = messages.get(timeout=5)
                if line is None:
                    break
                log.write(line)
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
                matches = launcher_header.findall(data)
                identity_error = None
                if len(matches) == 1:
                    result["launcherAppPID"] = int(matches[0])
                    if result["launcherAppPID"] <= 0 or result["launcherAppPID"] != result.get("appPID"):
                        identity_error = "launcher/probe app PID mismatch"
                else:
                    result.pop("launcherAppPID", None)
                    identity_error = f"require one launcher app PID acknowledgement; got {len(matches)}"
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
    parser.add_argument("--terminate-command", nargs="+", required=True)
    parser.add_argument("--launch-command", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    if not args.launch_command or not math.isfinite(args.timeout) or args.timeout <= 0 or args.receipt.exists():
        parser.error("require a launch command, positive timeout, and fresh receipt path")
    return run(args.launch_command, args.terminate_command, args.output, args.receipt, args.timeout,
               dict(runID=args.run_id, simulatorID=args.simulator_id, scenario=args.scenario, bundleID=args.bundle_id))


if __name__ == "__main__":
    raise SystemExit(main())
