#!/usr/bin/env python3
"""Adversarial CLI checks using genuine saved traces and real child processes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT.parent / "docs/research/callkit-simulator-probe/ci-github-run-39481703479/macos-26"


def check(condition, label):
    if not condition:
        raise RuntimeError(label)


def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix="callkit-harness-check-") as temporary:
        work = Path(temporary)

        def traces(label, mutate=None, expected=True, strict=False):
            target = work / label
            target.mkdir()
            for name in ("genuine", "runtime", "push"):
                shutil.copyfile(FIXTURES / f"{name}.jsonl", target / f"{name}.jsonl")
            if mutate:
                mutate(target)
            command = [sys.executable, str(ROOT / "summarize.py"), str(target)]
            if strict:
                command.append("--require-receipts")
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            check((result.returncode == 0) is expected, f"{label}: {result.stdout} {result.stderr}")
            check(json.loads(result.stdout)["success"] is expected, f"{label}: no structured result")
            checks.append(label)

        def mutate_row(directory, event, change, scenario="runtime", **fields):
            path = directory / f"{scenario}.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            selected = next(row for row in rows if row["event"] == event and
                            all(row.get(key) == value for key, value in fields.items()))
            change(rows, selected)
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))

        def remove_events(directory, scenario, predicate):
            path = directory / f"{scenario}.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            path.write_text("".join(json.dumps(row) + "\n" for row in rows if not predicate(row)))

        traces("saved-measured-profile")
        traces("missing-trace", lambda d: (d / "runtime.jsonl").unlink(), False)
        traces("empty-trace", lambda d: (d / "runtime.jsonl").write_text(""), False)
        traces("truncated", lambda d: mutate_row(d, "done", lambda rows, r: rows.remove(r)), False)
        traces("malformed-json", lambda d: (d / "runtime.jsonl").write_text("{bad\n"), False)
        traces("wrong-outcome", lambda d: mutate_row(d, "request.completed",
               lambda rows, r: r.update(result="wrong"), label="answer-a"), False)
        traces("duplicate-completion", lambda d: mutate_row(d, "request.completed",
               lambda rows, r: rows.insert(-1, dict(r)), label="answer-a"), False)
        traces("wrong-final-state", lambda d: mutate_row(d, "observer.snapshot",
               lambda rows, r: r.update(pending=1), label="final"), False)
        traces("no-capture-processing", lambda d: mutate_row(d, "mic.result",
               lambda rows, r: r.update(frames=0), label="after-answer"), False)
        traces("missing-receipts", expected=False, strict=True)
        traces("ambiguous-stale-output", lambda d: (d / "runtime.log").write_text(""), False)
        for kind in ("CXSetMutedCallAction", "CXPlayDTMFCallAction", "CXSetGroupCallAction"):
            traces(f"missing-{kind}", lambda d, k=kind: remove_events(d, "runtime",
                   lambda r: r["event"] == "provider.perform" and r["kind"] == k), False)
        traces("wrong-dtmf", lambda d: mutate_row(d, "provider.perform",
               lambda rows, r: r.update(digits="wrong"), kind="CXPlayDTMFCallAction"), False)
        for label in ("two-calls", "merged"):
            traces(f"empty-{label}", lambda d, l=label: mutate_row(d, "observer.snapshot",
                   lambda rows, r: r.update(calls=[]), label=l), False)
        traces("push-no-fulfillment", lambda d: remove_events(d, "push",
               lambda r: r["event"] == "action.fulfilled"), False)
        traces("push-no-ended-transition", lambda d: remove_events(d, "push",
               lambda r: r["event"] == "observer.callChanged" and r["ended"]), False)
        traces("genuine-no-incoming-report", lambda d: remove_events(d, "genuine",
               lambda r: r["event"] == "report.incomingCompleted"), False)
        traces("answer-fulfilled-before-expiry", lambda d: mutate_row(d, "action.held",
               lambda rows, r: r.update(event="action.fulfilled")), False)
        traces("answer-not-retained", lambda d: remove_events(d, "runtime",
               lambda r: r["event"] == "action.held"), False)
        traces("no-late-fulfillment", lambda d: remove_events(d, "runtime",
               lambda r: r["event"] == "late.fulfill"), False)

        # Test the actual runner CLI and its owned stop, not a mocked Popen.
        probe = work / "fake_probe.py"
        probe.write_text(
            "import json,os,pathlib,subprocess,sys,time\n"
            "if sys.argv[2]=='detached':\n"
            " subprocess.Popen([sys.executable,__file__,sys.argv[1],'timeout'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)\n"
            " while not pathlib.Path(sys.argv[1]).exists(): time.sleep(.01)\n"
            " sys.exit(7)\n"
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
            "if sys.argv[2]=='fail': sys.exit(7)\n"
            "if sys.argv[2]=='empty': sys.exit(0)\n"
            "if sys.argv[2]=='complete': print('PROBE '+json.dumps({'event':'done','t_ms':1}),flush=True)\n"
            "time.sleep(30)\n"
        )
        stop = work / "stop.py"
        stop.write_text(
            "import os,pathlib,signal,sys\n"
            "pathlib.Path(sys.argv[1]+'.stopped').touch()\n"
            "try: os.kill(int(pathlib.Path(sys.argv[1]).read_text()),signal.SIGTERM)\n"
            "except (ProcessLookupError,FileNotFoundError): pass\n"
        )
        for mode in ("complete", "fail", "empty", "timeout", "detached"):
            receipt = work / f"{mode}.receipt.json"
            pid = work / f"{mode}.pid"
            command = [sys.executable, str(ROOT / "run_scenario.py"),
                       "--output", str(work / f"{mode}.log"), "--receipt", str(receipt),
                       "--timeout", "0.5", "--terminate-command", sys.executable, str(stop), str(pid),
                       "--launch-command", sys.executable, str(probe), str(pid), mode]
            result = subprocess.run(command, capture_output=True, text=True, timeout=15)
            expected = mode == "complete"
            check((result.returncode == 0) is expected, f"runner-{mode}: {result.stderr}")
            check(receipt.exists(), f"runner-{mode}: missing receipt: {result.stdout} {result.stderr}")
            evidence = json.loads(receipt.read_text())
            check(evidence["success"] is expected, f"runner-{mode}: {evidence}")
            check(Path(str(pid) + ".stopped").exists(), f"runner-{mode}: owned stop skipped")
            if mode == "detached":
                child = int(pid.read_text())
                for _ in range(50):
                    try:
                        os.kill(child, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(.02)
                else:
                    os.kill(child, 9)
                    raise RuntimeError("runner-detached: app survived launcher cleanup")
            checks.append(f"runner-{mode}")
    print(json.dumps({"success": True, "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
