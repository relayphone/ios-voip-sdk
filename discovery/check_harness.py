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
        for label in ("incoming-a", "incoming-a-duplicate"):
            traces(f"off-main-report-{label}", lambda d, label=label: mutate_row(d, "report.incomingCompleted",
                   lambda rows, r: r.update(main=False), label=label), False)
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
        fresh = subprocess.run([sys.executable, str(ROOT / "summarize.py"), str(strict_source)],
                               capture_output=True, text=True, timeout=10)
        check(fresh.returncode == 1 and all(not json.loads(fresh.stdout)["scenarios"][name]["success"]
                                           for name in ("runtime", "push")),
              "fresh capture without shipping identity accepted")
        checks.append("fresh-capture-requires-shipping-evidence")
        for mutation, error in (("missing", "require one runtime.identity"),
                                ("unknown", "shipping runtime")):
            target = work / f"fresh-{mutation}-runtime-identity"
            shutil.copytree(strict_source, target)
            rows = [json.loads(line) for line in (target / "runtime.jsonl").read_text().splitlines()]
            launch = next(row for row in rows if row["event"] == "launch")
            # Synthetic OS/compiler evidence lets identity mutations reach their
            # intended gate rather than an unrelated environment rejection.
            runtime_id = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
            (target / "runtimes.json").write_text(json.dumps(dict(runtimes=[dict(
                identifier=runtime_id, platform="iOS", version="26.5", buildversion="23F77", isAvailable=True)])))
            (target / "compiler-version.txt").write_text("Xcode 26.6\nBuild version 17F113\n")
            (target / "manifest.json").write_text(json.dumps(dict(schemaVersion=1, profileID="ios-27.0",
                runID=launch["runID"], simulatorID=launch["simulatorID"], simulatorRuntimeID=runtime_id,
                simulatorOSVersion="26.5", simulatorOSBuildVersion="23F77", compilerXcodeVersion="26.6",
                compilerXcodeBuildVersion="17F113")))
            if mutation == "unknown":
                for scenario in ("runtime", "push"):
                    path = target / f"{scenario}.jsonl"
                    rows = [json.loads(line) for line in path.read_text().splitlines()]
                    rows.insert(-1, dict(event="runtime.identity", version="unknown", t_ms=rows[-1]["t_ms"]))
                    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
                    receipt_path = target / f"{scenario}.receipt.json"
                    receipt = json.loads(receipt_path.read_text())
                    receipt["traceSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                    receipt_path.write_text(json.dumps(receipt))
            result = subprocess.run([sys.executable, str(ROOT / "summarize.py"), str(target)],
                                    capture_output=True, text=True, timeout=10)
            summary = json.loads(result.stdout)
            check(result.returncode == 1 and all(not summary["scenarios"][name]["success"] and
                                                error in summary["scenarios"][name]["error"]
                                                for name in ("runtime", "push")),
                  f"fresh-{mutation}-runtime-identity: {result.stdout}")
            checks.append(f"fresh-{mutation}-runtime-identity")
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
            result = subprocess.run([sys.executable, str(ROOT / "summarize.py"), str(target), "--allow-legacy", "--require-receipts"],
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

        # A launcher's own PID header may flush only after its app terminates.
        # Keep launcher and app separate so this ordering is actually exercised.
        bound_probe = work / "bound_probe.py"
        bound_probe.write_text(
            "import json,os,pathlib,sys,time\n"
            "pid=pathlib.Path(sys.argv[1]); mode=sys.argv[2]\n"
            "pid.write_text(str(os.getpid()))\n"
            "rows=({'event':'app.entry','t_ms':0},{'event':'launch','t_ms':1,'pid':os.getpid()},{'event':'done','t_ms':2})\n"
            "payload=''.join('PROBE '+json.dumps(row)+'\\n' for row in rows)\n"
            "if mode not in ('never','cleanup-failure','eof'):\n"
            " value=os.getpid()+(1 if mode=='mismatch' else 0)\n"
            " header='dev.callkitsim.fixture: '+str(value)+'\\n'\n"
            " pathlib.Path(str(pid)+'.ack').touch()\n"
            " payload=header+payload if mode=='header-first' else payload+header*(2 if mode=='duplicate' else 1)\n"
            "os.write(1,payload.encode())\n"
            "if mode=='eof': sys.exit(0)\n"
            "time.sleep(30)\n"
        )
        bound_launcher = work / "bound_launcher.py"
        bound_launcher.write_text(
            "import subprocess,sys\n"
            "app=subprocess.Popen([sys.executable,sys.argv[1],sys.argv[2],'never'])\n"
            "print('dev.callkitsim.fixture: '+str(app.pid),flush=False)\n"
            "app.wait()\n"
        )
        bound_stop = work / "bound_stop.py"
        bound_stop.write_text(
            "import os,pathlib,signal,sys\n"
            "pid=pathlib.Path(sys.argv[1]); mode=sys.argv[2]\n"
            "pathlib.Path(str(pid)+'.stopped').touch()\n"
            "try: os.kill(int(pid.read_text()),signal.SIGTERM)\n"
            "except (ProcessLookupError,FileNotFoundError): pass\n"
            "sys.exit(7 if mode in ('terminate-failure','cleanup-failure') else 0)\n"
        )
        for mode, expected_error in (("header-first", None), ("post-stop", None),
                                     ("never", "require one launcher app PID acknowledgement"),
                                     ("mismatch", "launcher/probe app PID mismatch"),
                                     ("duplicate", "require one launcher app PID acknowledgement"),
                                     ("eof", "require one launcher app PID acknowledgement"),
                                     ("terminate-failure", "failed to terminate completed run-owned app"),
                                     ("cleanup-failure", "failed to terminate completed run-owned app")):
            receipt = work / f"bound-{mode}.receipt.json"
            pid = work / f"bound-{mode}.pid"
            launch = [sys.executable, str(bound_launcher), str(bound_probe), str(pid)] if mode == "post-stop" else [
                sys.executable, str(bound_probe), str(pid), mode]
            command = [sys.executable, str(ROOT / "run_scenario.py"),
                       "--output", str(work / f"bound-{mode}.log"), "--receipt", str(receipt),
                       "--timeout", "20", "--bundle-id", "dev.callkitsim.fixture",
                       "--terminate-command", sys.executable, str(bound_stop), str(pid), mode,
                       "--launch-command", *launch]
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            check(receipt.exists(), f"runner-bound-{mode}: no receipt: {result.stderr}")
            evidence = json.loads(receipt.read_text())
            expected = expected_error is None
            check((result.returncode == 0) is expected and evidence["success"] is expected and
                  evidence["completed"] is True, f"runner-bound-{mode}: {evidence}")
            if expected:
                check(evidence.get("launcherAppPID") == evidence["appPID"] and evidence["terminateExitCode"] == 0,
                      f"runner-bound-{mode}: unbound success: {evidence}")
            else:
                check(expected_error in evidence.get("error", ""), f"runner-bound-{mode}: wrong primary error: {evidence}")
            if mode == "cleanup-failure":
                check("require one launcher app PID acknowledgement" in evidence.get("identityError", ""),
                      f"runner-bound-{mode}: missing secondary identity failure: {evidence}")
            if mode in ("terminate-failure", "cleanup-failure"):
                check(evidence.get("cleanupExitCode") == 7, f"runner-bound-{mode}: missing cleanup failure: {evidence}")
            check(Path(str(pid) + ".stopped").exists(), f"runner-bound-{mode}: owned stop skipped")
            try:
                os.kill(int(pid.read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError(f"runner-bound-{mode}: owned process survived")
            checks.append(f"runner-bound-{mode}")

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
