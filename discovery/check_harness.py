#!/usr/bin/env python3
"""Adversarial CLI checks using genuine saved traces and real child processes."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

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

        def mutate_row(directory, event, change, **fields):
            path = directory / "runtime.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            selected = next(row for row in rows if row["event"] == event and
                            all(row.get(key) == value for key, value in fields.items()))
            change(rows, selected)
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))

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

        # Test the actual runner CLI and its owned stop, not a mocked Popen.
        probe = work / "fake_probe.py"
        probe.write_text(
            "import json,os,pathlib,sys,time\n"
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
            "if sys.argv[2]=='fail': sys.exit(7)\n"
            "if sys.argv[2]=='empty': sys.exit(0)\n"
            "if sys.argv[2]=='complete': print('PROBE '+json.dumps({'event':'done','t_ms':1}),flush=True)\n"
            "time.sleep(30)\n"
        )
        stop = work / "stop.py"
        stop.write_text(
            "import os,pathlib,signal,sys\n"
            "try: os.kill(int(pathlib.Path(sys.argv[1]).read_text()),signal.SIGTERM)\n"
            "except (ProcessLookupError,FileNotFoundError): pass\n"
        )
        for mode in ("complete", "fail", "empty", "timeout"):
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
            checks.append(f"runner-{mode}")
    print(json.dumps({"success": True, "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
