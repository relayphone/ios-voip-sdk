#!/usr/bin/env python3
"""Check CallKit ABI interception/refusal receipts and their bound probe traces."""

import argparse
import hashlib
import json
from pathlib import Path

CASES = ["concrete-override", "shadow-concrete-override", "missing-selector", "kvc-exception",
         "kvc-ignored-outgoing", "kvc-ignored-hasConnected", "kvc-ignored-onHold", "kvc-ignored-hasEnded"]
CHECKS = {"original-reference-chain", "runtime-loads", "activation-result", "nonnull-initializers",
          "original-fulfill-chain", "original-fail-chain", "original-deadline-chain", "original-dated-fulfill",
          "incoming-result", "diagnostic-identifies-abi", "no-genuine-report", "snapshot-result",
          "transaction-result", "transaction-direct-result", "transaction-array-result",
          "no-genuine-report-after-request", "final-state", "no-genuine-operations"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(root, selected=None, runtime=None, probe=None):
    manifest = json.loads((root / "manifest.json").read_text())
    build = json.loads((root / "build-info.json").read_text())
    assert build["abiTesting"] is True, "require the explicit ABI test build"
    assert build["sourceCommit"] == manifest["sourceCommit"], "source identity mismatch"
    assert build["files"]["CKSimRuntime.dylib"] == manifest["runtimeSHA256"], "runtime build identity mismatch"
    if runtime is not None:
        assert digest(runtime) == manifest["runtimeSHA256"], "runtime bytes mismatch"
    if probe is not None:
        assert digest(probe) == manifest["probeSHA256"], "probe bytes mismatch"
    expected = [selected] if selected else CASES
    results = []
    for receipt_path in sorted(root.glob("*.receipt.json")):
        receipt = json.loads(receipt_path.read_text())
        trace = root / (receipt_path.name.removesuffix(".receipt.json") + ".log")
        assert receipt["success"] and receipt["completed"], f"incomplete scenario: {receipt_path.name}"
        assert receipt["traceSHA256"] == digest(trace), f"trace bytes mismatch: {receipt_path.name}"
        assert receipt["runID"] == manifest["runID"] and receipt["simulatorID"] == manifest["simulatorID"], "run identity mismatch"
        assert receipt["appPID"] == receipt["launcherAppPID"], "launcher/probe PID mismatch"
        assert receipt["bundleID"] == "dev.callkitsim.abi", "unexpected probe bundle"
        rows = [json.loads(line.split("PROBE ", 1)[1]) for line in trace.read_text().splitlines() if "PROBE " in line]
        checks = [row for row in rows if row["event"] == "abi.check"]
        assert len(checks) == len(CHECKS) and {row["label"] for row in checks} == CHECKS, "missing or duplicated checks"
        failures = [row["label"] for row in checks if row["passed"] is not True]
        assert not failures, f"{receipt['scenario']}: failed checks: {failures}"
        result = [row for row in rows if row["event"] == "abi.result"]
        assert len(result) == 1 and result[0]["success"] is True, "failed or missing terminal result"
        assert [row["event"] for row in rows[:2]] == ["app.entry", "launch"] and rows[-1]["event"] == "done", "incomplete trace boundaries"
        assert len([row for row in rows if row["event"] == "abi.originalReference"]) == 1, "missing original implementation reference"
        assert all(row["pid"] == receipt["appPID"] and row["runID"] == manifest["runID"] and
                   row["bundleID"] == receipt["bundleID"] and row["case"] == receipt["scenario"] for row in rows), "mixed probe identity"
        assert all(type(row.get("t_ms")) is int and row["t_ms"] >= 0 for row in rows), "invalid probe timestamps"
        assert [row["t_ms"] for row in rows] == sorted(row["t_ms"] for row in rows), "nonmonotonic probe timestamps"
        refused = "CKSIM runtime refused:" in trace.read_text()
        assert refused == (receipt["scenario"] != "concrete-override"), "missing or unexpected refusal diagnostic"
        results.append(receipt["scenario"])
    assert sorted(results) == sorted(expected), f"missing or unexpected scenarios: {results}"
    return dict(success=True, cases=results, checksPerCase=len(CHECKS), manifestSHA256=digest(root / "manifest.json"),
                runtimeSHA256=manifest["runtimeSHA256"], probeSHA256=manifest["probeSHA256"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--probe", type=Path)
    args = parser.parse_args()
    try:
        result = check(args.root, args.case, args.runtime, args.probe)
    except (AssertionError, KeyError, OSError, ValueError, TypeError) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
