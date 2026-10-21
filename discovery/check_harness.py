#!/usr/bin/env python3
"""Adversarial CLI checks using genuine saved traces and real child processes."""

import json
import hashlib
import os
from pathlib import Path
import shutil
import shlex
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
            else:
                command.append("--allow-legacy")
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

        # A positive strict-v2 replay and 13 materialized tampered traces. Four
        # derived cases are named explicitly: the review never supplied F-I.
        strict_source = ROOT / "fixtures/strict-v2"
        cases = json.loads((strict_source / "mutations.json").read_text())
        cases.append(dict(name='derived-ghost-completion-kind', mutation='ghost-kind', error='completion for unknown action'))
        for case in [dict(name="strict-v2-positive", mutation="none"), *cases]:
            target = work / case["name"]
            shutil.copytree(strict_source, target)
            path = target / "runtime.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            receipt_path = target / "runtime.receipt.json"
            receipt = json.loads(receipt_path.read_text())
            mutation = case["mutation"]
            if mutation == "mixed-run":
                next(r for r in rows if r["event"] == "launch")["runID"] = "another-run"
                receipt["runID"] = "another-run"
            elif mutation == "forged-receipt":
                receipt = dict(success=True, completed=True)
            elif mutation == "off-main":
                next(r for r in rows if r["event"] == "provider.perform")["main"] = False
            elif mutation == "audio-order":
                next(r for r in rows if r["event"] == "provider.didDeactivateAudio")["event"] = "provider.didActivateAudio"
            elif mutation == "nonmonotonic":
                next(r for r in rows if r["event"] == "provider.perform")["t_ms"] = 0
            elif mutation == "pid":
                receipt["appPID"] += 1
            elif mutation == "unexpected-timeout":
                r = next(r for r in rows if r["event"] == "action.fulfilled" and r.get("kind") == "CXSetMutedCallAction")
                rows.insert(rows.index(r) + 1, dict(r, event="provider.timedOut"))
            elif mutation == "no-observer":
                rows = [r for r in rows if r["event"] != "observer.callChanged"]
            elif mutation == "reset":
                r = next(r for r in rows if r["event"] == "provider.perform")
                rows.insert(rows.index(r), dict(event="provider.didReset", main=True, t_ms=r["t_ms"]))
            elif mutation == "late-id":
                next(r for r in rows if r["event"] == "late.fulfill")["id"] = "wrong-id"
            elif mutation == "missing-version":
                next(r for r in rows if r["event"] == "launch").pop("traceVersion")
            elif mutation == "unknown-version":
                next(r for r in rows if r["event"] == "launch")["traceVersion"] = 99
            elif mutation == "ghost-kind":
                row = next(r for r in rows if r['event'] == 'action.fulfilled')
                rows.insert(rows.index(row) + 1, dict(row, kind='CXUnknownCallAction'))
            elif mutation == "group-target":
                next(r for r in rows if r["event"] == "provider.perform" and r.get("kind") == "CXSetGroupCallAction")["groupWith"] = "wrong-call"
            path.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
            if mutation != "forged-receipt":
                receipt["traceSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            receipt_path.write_text(json.dumps(receipt))
            result = subprocess.run([sys.executable, str(ROOT / "summarize.py"), str(target)],
                                    capture_output=True, text=True, timeout=10)
            expected = mutation == "none"
            check((result.returncode == 0) is expected, f"{case['name']}: {result.stdout}")
            if not expected:
                check(case["error"] in result.stdout, f"{case['name']}: wrong rejection: {result.stdout}")
            checks.append(case["name"])

        for scenario, event in (("push", "provider.didReset"), ("push", "provider.timedOut")):
            def unexpected(d, scenario=scenario, event=event):
                path = d / f"{scenario}.jsonl"
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                rows.insert(-1, dict(event=event, t_ms=rows[-2]['t_ms'], main=True, id='unknown', kind='CXEndCallAction'))
                path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            traces(f"{scenario}-unexpected-{event}", unexpected, False)
        traces("no-execute-callbacks", lambda d: remove_events(d, "runtime",
               lambda r: r['event'] == 'provider.executeTransaction'), False)
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

        # Execute the actual shell run() failure branch. Diagnostics must not
        # replace a scenario failure with a secondary copy failure.
        binaries = work / "bin"
        binaries.mkdir()
        container = work / "container" / "Documents"
        container.mkdir(parents=True)
        (container / "trace.jsonl").write_text("{}\n")
        for name, body in {
            "python3": "exit 7\n",
            "cp": "exit 9\n",
            "xcrun": "printf '%s\\n' " + shlex.quote(str(container.parent)) + "\n",
        }.items():
            executable = binaries / name
            executable.write_text("#!/bin/sh\n" + body)
            executable.chmod(0o755)
        source = (ROOT / "run.sh").read_text().split("run() {\n", 1)[1].split("\n}\nLIBS=", 1)[0]
        driver = work / "shell-failure.sh"
        driver.write_text("set -euo pipefail\nOUT=" + shlex.quote(str(work)) +
                          "\nUDID=owned-fixture\nRUN_ID=fixture\nLIBS=fixture\nSIMCTL_CHILD_DYLD_INSERT_LIBRARIES=''\n"
                          "limit() { shift; \"$@\"; }\nrun() {\n" + source + "\n}\nrun genuine\n")
        result = subprocess.run(["/bin/bash", str(driver)], capture_output=True, timeout=10,
                                env={**os.environ, "PATH": f"{binaries}:/usr/bin:/bin"})
        check(result.returncode == 7, "diagnostic copy replaced scenario exit status")
        checks.append("shell-preserves-scenario-failure")
    print(json.dumps({"success": True, "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
