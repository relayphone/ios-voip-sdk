#!/usr/bin/env python3
"""Run a probe to its terminal marker, then stop only the run-owned app."""

import argparse
import json
import math
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time


def run(launch, terminate, output, receipt, timeout):
    started = time.monotonic()
    result = {"completed": False, "success": False}
    process = None
    stopped = False
    messages = queue.Queue()
    try:
        with output.open("xb") as log:
            process = subprocess.Popen(launch, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)

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
                    if process.poll() is not None:
                        raise RuntimeError("launcher exited before terminal done event")
                    continue
                if line is None:
                    raise RuntimeError("launcher exited before terminal done event")
                log.write(line)
                log.flush()
                if b"PROBE " in line:
                    try:
                        row = json.loads(line.split(b"PROBE ", 1)[1])
                    except (ValueError, UnicodeDecodeError):
                        continue  # The conformance parser rejects malformed evidence.
                    result["completed"] = isinstance(row, dict) and row.get("event") == "done"

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
        result["elapsedSeconds"] = round(time.monotonic() - started, 3)
        receipt.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["success"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=200)
    parser.add_argument("--terminate-command", nargs="+", required=True)
    parser.add_argument("--launch-command", nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    if not args.launch_command or not math.isfinite(args.timeout) or args.timeout <= 0 or args.receipt.exists():
        parser.error("require a launch command, positive timeout, and fresh receipt path")
    return run(args.launch_command, args.terminate_command, args.output, args.receipt, args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
