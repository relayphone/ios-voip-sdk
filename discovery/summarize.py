#!/usr/bin/env python3
"""Assert the measured discovery profile; capture processing is not media proof."""

import argparse
import json
from pathlib import Path

REQUEST_ERROR = "com.apple.CallKit.error.requesttransaction:"
INCOMING_ERROR = "com.apple.CallKit.error.incomingcall:"
SCENARIOS = ("genuine", "runtime", "push")


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def load(directory, name):
    paths = [directory / f"{name}.{suffix}" for suffix in ("log", "jsonl")]
    paths = [path for path in paths if path.exists()]
    require(len(paths) == 1, f"{name}: require exactly one fresh .log or .jsonl trace")
    rows = []
    for line_number, line in enumerate(paths[0].read_text().splitlines(), 1):
        if paths[0].suffix == ".log":
            if "PROBE " not in line:
                continue
            line = line.split("PROBE ", 1)[1]
        try:
            row = json.loads(line)
        except ValueError as error:
            raise EvidenceError(f"{name}:{line_number}: malformed probe JSON") from error
        require(isinstance(row, dict) and isinstance(row.get("event"), str),
                f"{name}:{line_number}: invalid event record")
        require(type(row.get("t_ms")) is int and row["t_ms"] >= 0,
                f"{name}:{line_number}: invalid timestamp")
        rows.append(row)
    require(rows, f"{name}: empty evidence")
    return rows


def one(rows, event, **fields):
    matches = [row for row in rows if row["event"] == event and
               all(row.get(key) == value for key, value in fields.items())]
    require(len(matches) == 1, f"require one {event} {fields}; got {len(matches)}")
    return matches[0]


def before(rows, first, second):
    require(rows.index(first) < rows.index(second),
            f"wrong order: {first['event']} before {second['event']}")


def result(rows, event, label, expected):
    row = one(rows, event, label=label)
    require(row.get("result") == expected, f"{label}: expected {expected}, got {row.get('result')}")
    return row


def snapshot(rows, label):
    row = one(rows, "observer.snapshot", label=label)
    require(isinstance(row.get("calls"), list) and type(row.get("pending")) is int,
            f"{label}: malformed snapshot")
    for call in row["calls"]:
        require(isinstance(call, dict) and isinstance(call.get("uuid"), str) and
                all(type(call.get(key)) is bool for key in ("ended", "connected", "held", "outgoing")),
                f"{label}: malformed call snapshot")
    return row


def common(rows, name):
    launch = one(rows, "launch")
    require(launch.get("mode") == ("push" if name == "push" else "default"), "wrong probe mode")
    require(launch.get("injected") is (name != "genuine"), "wrong injection identity")
    done = one(rows, "done")
    require(rows[-1] is done, "events appear after terminal done")
    before(rows, launch, done)
    if name != "push":
        for phase in ("incoming", "call-waiting", "outgoing", "errors", "answer-timeout", "unanswered"):
            one(rows, "step", name=phase)
        for label in ("initial", "ringing", "answered", "held", "two-calls", "merged", "after-end",
                      "outgoing", "after-timeout-wait", "after-late-fulfill", "unanswered-wait"):
            snapshot(rows, label)
        final = snapshot(rows, "final")
        require(final["calls"] == [] and final["pending"] == 0, "final state not empty")
        before(rows, final, one(rows, "provider.invalidated"))
        before(rows, one(rows, "provider.invalidated"), done)


def runtime(rows):
    for label in ("incoming-a", "incoming-b", "incoming-d", "incoming-e"):
        result(rows, "report.incomingCompleted", label, "ok")
    result(rows, "report.incomingCompleted", "incoming-a-duplicate", INCOMING_ERROR + "2")
    for label in ("answer-a", "mute-a", "dtmf-a", "hold-a", "unhold-a", "merge-a-b",
                  "end-b", "start-c", "end-c", "answer-d-never", "decline-e"):
        result(rows, "request.completed", label, "ok")
    for label, code in (("hold-a-answer-b", 6), ("answer-unknown", 4),
                        ("end-unknown", 4), ("empty-transaction", 1)):
        result(rows, "request.completed", label, REQUEST_ERROR + str(code))
    a = one(rows, "step", name="incoming")["uuid"]
    b = one(rows, "step", name="call-waiting")["uuid"]
    c = one(rows, "step", name="outgoing")["uuid"]
    d = one(rows, "step", name="answer-timeout")["uuid"]
    e = one(rows, "step", name="unanswered")["uuid"]
    # Accepted transactions alone do not establish delegate delivery. This is
    # the complete callback inventory for this measured profile, including the
    # system's end action after D expires. Rejected transactions add no actions.
    expected = [
        ("answer-a", "CXAnswerCallAction", a, {}),
        ("mute-a", "CXSetMutedCallAction", a, {"muted": True}),
        ("dtmf-a", "CXPlayDTMFCallAction", a, {"digits": "12#"}),
        ("hold-a", "CXSetHeldCallAction", a, {"onHold": True}),
        ("unhold-a", "CXSetHeldCallAction", a, {"onHold": False}),
        ("merge-a-b", "CXSetGroupCallAction", a, {}),
        ("end-b", "CXEndCallAction", b, {}),
        ("start-c", "CXStartCallAction", c, {"handle": "+15555550102", "video": False}),
        ("end-c", "CXEndCallAction", c, {}),
        ("answer-d-never", "CXAnswerCallAction", d, {}),
        (None, "CXEndCallAction", d, {}),
        ("decline-e", "CXEndCallAction", e, {}),
    ]
    performed = [row for row in rows if row["event"] == "provider.perform"]
    require(len(performed) == len(expected), "unexpected/missing delegate actions")
    identities = [row.get("id") for row in performed]
    require(all(isinstance(i, str) and i for i in identities) and
            len(set(identities)) == len(identities), "duplicate/missing action identity")
    for label, kind, call, fields in expected:
        action = one(rows, "provider.perform", kind=kind, call=call, **fields)
        if label:
            before(rows, result(rows, "request.completed", label, "ok"), action)
        if label != "answer-d-never":
            fulfill_action(rows, action)
    for label, connected, held in (("ringing", False, False), ("answered", True, False),
                                  ("held", True, True)):
        calls = snapshot(rows, label)["calls"]
        require(len(calls) == 1 and calls[0]["uuid"] == a and
                calls[0]["connected"] is connected and calls[0]["held"] is held and
                calls[0]["ended"] is False, f"{label}: incorrect incoming state")
    for label in ("two-calls", "merged"):
        state = snapshot(rows, label)
        calls = {call["uuid"]: call for call in state["calls"]}
        require(len(state["calls"]) == 2 and set(calls) == {a, b} and
                calls[a] == dict(uuid=a, connected=True, held=False, ended=False, outgoing=False) and
                calls[b] == dict(uuid=b, connected=False, held=False, ended=False, outgoing=False) and
                state["pending"] == 0, f"{label}: incorrect two-call state")
    require(snapshot(rows, "after-end")["calls"] == [], "calls survive after-end")
    outgoing = snapshot(rows, "outgoing")["calls"]
    require(outgoing == [dict(uuid=c, connected=True, held=False, ended=False, outgoing=True)],
            "outgoing call did not connect")
    for label in ("after-answer", "after-outgoing"):
        mic = one(rows, "mic.result", label=label)
        require(all(type(mic.get(key)) in (int, float) and mic[key] > 0
                    for key in ("frames", "rate", "channels")), f"{label}: no capture processing")
    activations = [r for r in rows if r["event"] == "provider.didActivateAudio"]
    deactivations = [r for r in rows if r["event"] == "provider.didDeactivateAudio"]
    require(len(activations) >= 3 and len(deactivations) >= 3, "missing audio ownership cycles")
    held = snapshot(rows, "held")
    require(any(snapshot(rows, "answered")["t_ms"] < r["t_ms"] < held["t_ms"]
                for r in deactivations), "hold did not deactivate audio")
    require(any(held["t_ms"] < r["t_ms"] < snapshot(rows, "two-calls")["t_ms"]
                for r in activations), "unhold did not reactivate audio")
    answer = one(rows, "provider.perform", kind="CXAnswerCallAction", call=a)
    before(rows, result(rows, "request.completed", "answer-a", "ok"), answer)
    require(any(answer["t_ms"] < r["t_ms"] < snapshot(rows, "answered")["t_ms"]
                for r in activations), "answer activation missing/out of order")
    timeout_answer = one(rows, "provider.perform", kind="CXAnswerCallAction", call=d)
    timeout_end = one(rows, "provider.perform", kind="CXEndCallAction", call=d)
    before(rows, timeout_answer, timeout_end)
    require(50_000 <= timeout_end["t_ms"] - timeout_answer["t_ms"] <= 75_000,
            "answer expiry outside measured profile window")
    for label in ("after-timeout-wait", "after-late-fulfill"):
        require(snapshot(rows, label)["calls"] == [], f"{label}: timed-out call survived/resurrected")
    require(snapshot(rows, "after-timeout-wait")["pending"] == 1,
            "expired answer no longer pending as measured")
    require(snapshot(rows, "after-late-fulfill")["pending"] == 0,
            "late fulfillment did not settle the retained action")
    before(rows, timeout_end, snapshot(rows, "after-timeout-wait"))


def genuine(rows):
    # A change here is baseline drift; it is not a failing calling application.
    report = result(rows, "report.incomingCompleted", "incoming-a", "ok")
    a = one(rows, "step", name="incoming")["uuid"]
    ended = one(rows, "observer.callChanged", uuid=a, ended=True)
    before(rows, report, ended)
    before(rows, ended, result(rows, "request.completed", "answer-a", REQUEST_ERROR + "4"))
    result(rows, "request.completed", "answer-unknown", REQUEST_ERROR + "4")
    result(rows, "request.completed", "end-unknown", REQUEST_ERROR + "4")
    result(rows, "request.completed", "empty-transaction", REQUEST_ERROR + "1")
    require(not any(r["event"] == "provider.didActivateAudio" for r in rows),
            "genuine baseline drift: audio now activates; inspect/reprofile")
    require(snapshot(rows, "ringing")["calls"] == [], "genuine baseline drift: incoming call survives")


def push(rows):
    received = one(rows, "push.received")
    require(received.get("api") in ("metadata", "legacy"), "unsupported push callback")
    if received["api"] == "metadata":
        require(received.get("mustReport") is True, "metadata reporting obligation missing")
    before(rows, one(rows, "push.registered"), received)
    reported = one(rows, "push.reported")
    require(reported.get("result") == "ok", "push was not reported")
    before(rows, received, reported)
    state = snapshot(rows, "after-push-wait")
    require(len(state["calls"]) == 1 and state["calls"][0]["ended"] is False and
            state["calls"][0]["connected"] is False, "push call did not stay ringing")
    before(rows, reported, state)
    cleanup = result(rows, "request.completed", "cleanup", "ok")
    before(rows, state, cleanup)
    ended = one(rows, "provider.perform", kind="CXEndCallAction", call=state["calls"][0]["uuid"])
    before(rows, cleanup, ended)
    fulfilled = fulfill_action(rows, ended)
    observed = one(rows, "observer.callChanged", uuid=ended["call"], ended=True)
    before(rows, fulfilled, observed)
    before(rows, observed, one(rows, "done"))
    if one(rows, "launch").get("traceVersion", 1) >= 2:
        final = snapshot(rows, "final")
        require(final["calls"] == [] and final["pending"] == 0, "push cleanup not empty")
        before(rows, observed, final)
        before(rows, final, one(rows, "done"))


def fulfill_action(rows, action):
    start = rows.index(action)
    end = next((i for i in range(start + 1, len(rows))
                if rows[i]["event"] == "provider.perform"), len(rows))
    fields = {"kind": action["kind"]}
    if one(rows, "launch").get("traceVersion", 1) >= 2:
        fields["id"] = action["id"]
    fulfilled = one(rows[start + 1:end], "action.fulfilled", **fields)
    return fulfilled


def validate(directory, require_receipts=False):
    summary = {"profile": "simulator-discovery-v2", "mediaProof": False, "scenarios": {}}
    for name in SCENARIOS:
        try:
            if require_receipts:
                receipt = json.loads((directory / f"{name}.receipt.json").read_text())
                require(receipt.get("success") is True and receipt.get("completed") is True,
                        f"{name}: runner did not complete successfully")
            rows = load(directory, name)
            if require_receipts:
                require(one(rows, "launch").get("traceVersion") == 2,
                        "live run requires traceVersion 2")
            common(rows, name)
            {"runtime": runtime, "genuine": genuine, "push": push}[name](rows)
            summary["scenarios"][name] = {"success": True, "events": len(rows)}
        except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
            summary["scenarios"][name] = {"success": False, "error": str(error)}
    summary["success"] = all(s["success"] for s in summary["scenarios"].values())
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--require-receipts", action="store_true")
    args = parser.parse_args()
    summary = validate(args.directory, args.require_receipts)
    print(json.dumps(summary, indent=2))
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
