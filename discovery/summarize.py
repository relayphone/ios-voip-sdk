#!/usr/bin/env python3
"""Assert the measured discovery profile; capture processing is not media proof."""

import argparse
import hashlib
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


def shipping(rows):
    return any(r["event"] == "runtime.identity" and r.get("version") == "0.1.0" for r in rows)


def expected_timeouts(rows):
    allowed = set()
    for action in rows:
        if action["event"] != "provider.perform" or action.get("kind") != "CXSetMutedCallAction" or action.get("muted") is not False:
            continue
        require(any(r["event"] == "provider.perform" and r.get("call") == action["call"] and
                    r.get("muted") is True and r["t_ms"] < action["t_ms"] for r in rows),
                "post-end unmute has no earlier mute")
        require(any(r["event"] == "observer.callChanged" and r.get("uuid") == action["call"] and
                    r.get("ended") is True and r["t_ms"] <= action["t_ms"] for r in rows),
                "post-end unmute precedes call end")
        fulfilled = fulfill_action(rows, action)
        timeout = one(rows, "provider.timedOut", id=action["id"], kind=action["kind"])
        before(rows, fulfilled, timeout)
        require(5000 <= timeout["t_ms"] - action["t_ms"] <= 5900, "post-end unmute timeout budget")
        allowed.add(action["id"])
    return allowed


def common(rows, name):
    launch = one(rows, "launch")
    require(launch.get("traceVersion", 1) in (1, 2), "unsupported trace version")
    require(all(a["t_ms"] <= b["t_ms"] for a, b in zip(rows, rows[1:])),
            "non-monotonic event time")
    callbacks = ("provider.perform", "provider.executeTransaction", "provider.didActivateAudio",
                 "provider.didDeactivateAudio", "provider.timedOut", "observer.callChanged",
                 "report.incomingCompleted")
    require(all(r.get("main") is True for r in rows if r["event"] in callbacks),
            "nil-queue delegate callback delivered off main")
    if name != "genuine":
        invalidated = next((r for r in rows if r["event"] == "provider.invalidated"), None)
        require(not any(r["event"] == "provider.didReset" and
                        (invalidated is None or rows.index(r) < rows.index(invalidated)) for r in rows),
                "unexpected provider reset")
        allowed = expected_timeouts(rows) if shipping(rows) else set()
        timeouts = [r for r in rows if r["event"] == "provider.timedOut"]
        require(len(timeouts) == len(allowed) and {r.get("id") for r in timeouts} == allowed,
                "unexpected action timeout")
        performs = [r for r in rows if r["event"] == "provider.perform"]
        executions = [r for r in rows if r["event"] == "provider.executeTransaction"]
        require(len(executions) == len(performs), "missing or unexpected transaction execution")
        for perform, execute in zip(performs, executions):
            require(execute.get("actions") == [perform.get("kind")], "transaction action inventory mismatch")
            before(rows, execute, perform)
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
    # This discovery scenario expects no timeout callbacks. Versioned device
    # conformance scenarios declare their post-end system-unmute timeout separately.
    require(not any(r["event"] in ("action.failed", "action.fulfilledLate") for r in rows),
            "unexpected failed or delayed action completion")
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
    if shipping(rows):
        own_mute = one(rows, "request.begin", label="mute-a")["actionIDs"][0]
        extras = [r for r in performed if r["kind"] == "CXSetMutedCallAction" and r["id"] != own_mute]
        require(len(extras) == 2 and {r.get("muted") for r in extras} == {True, False}, "missing mute echoes")
        for extra in extras: fulfill_action(rows, extra)
        performed = [r for r in performed if r not in extras]
    require(len(performed) == len(expected), "unexpected/missing delegate actions")
    identities = [row.get("id") for row in performed]
    require(all(isinstance(i, str) and i for i in identities) and
            len(set(identities)) == len(identities), "duplicate/missing action identity")
    if one(rows, "launch").get("traceVersion") == 2:
        all_performed = [r for r in rows if r["event"] == "provider.perform"]
        action_pairs = {(r["id"], r["kind"]) for r in all_performed}
        completions = [r for r in rows if r["event"] == "action.fulfilled"]
        require(all((r.get("id"), r.get("kind")) in action_pairs for r in completions),
                "completion for unknown action")
        require(len(completions) == len(all_performed) - 1, "unexpected completion inventory")
    for label, kind, call, fields in expected:
        candidates = [r for r in performed if r.get("kind") == kind and r.get("call") == call and
                      all(r.get(k) == v for k, v in fields.items())]
        require(len(candidates) == 1, f"missing/duplicate {kind} delivery")
        action = candidates[0]
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
    merge_action = one(rows, "provider.perform", kind="CXSetGroupCallAction", call=a)
    if one(rows, "launch").get("traceVersion") == 2:
        merge_request = one(rows, "request.begin", label="merge-a-b")
        require(merge_action.get("groupWith") == b, "merge target not observed")
        require(merge_request.get("groupWith") == b, "merge request target missing")
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
    audio = [r["event"] for r in rows if r["event"] in
             ("provider.didActivateAudio", "provider.didDeactivateAudio")]
    require(audio == ["provider.didActivateAudio", "provider.didDeactivateAudio"] * 3,
            "missing, duplicated or unordered audio ownership cycles")
    changed = [r for r in rows if r["event"] == "observer.callChanged"]
    for call_id in (a, b, c, d, e):
        states = [r for r in changed if r.get("uuid") == call_id]
        require(any(r.get("ended") is False for r in states) and
                any(r.get("ended") is True for r in states), "missing observer lifecycle")
    for label in ("ringing", "answered", "held", "outgoing"):
        snap = snapshot(rows, label)
        for state in snap["calls"]:
            require(any(all(row.get(k) == v for k, v in state.items()) and
                        row["t_ms"] <= snap["t_ms"] for row in changed),
                    f"{label}: snapshot has no preceding observer callback")
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
    fields = {"kind": "CXAnswerCallAction"}
    if one(rows, "launch").get("traceVersion", 1) >= 2:
        fields["id"] = timeout_answer["id"]
    retained = one(rows, "action.held", **fields)
    before(rows, timeout_answer, retained)
    before(rows, retained, timeout_end)
    require(not any(r["event"] in ("action.fulfilled", "action.failed", "action.fulfilledLate") and
                    r.get("kind") == "CXAnswerCallAction"
                    for r in rows[rows.index(timeout_answer) + 1:rows.index(timeout_end)]),
            "answer-d-never completed before expiry")
    before(rows, timeout_answer, timeout_end)
    lower, upper = (59_000, 61_000) if one(rows, "launch").get("traceVersion") == 2 else (50_000, 75_000)
    require(lower <= timeout_end["t_ms"] - timeout_answer["t_ms"] <= upper,
            "answer expiry outside configured iOS27 profile budget")
    for label in ("after-timeout-wait", "after-late-fulfill"):
        require(snapshot(rows, label)["calls"] == [], f"{label}: timed-out call survived/resurrected")
    require(snapshot(rows, "after-timeout-wait")["pending"] == 1,
            "expired answer no longer pending as measured")
    require(snapshot(rows, "after-late-fulfill")["pending"] == 0,
            "late fulfillment did not settle the retained action")
    before(rows, timeout_end, snapshot(rows, "after-timeout-wait"))
    late_fields = {"id": timeout_answer["id"]} if "id" in fields else {}
    late = one(rows, "late.fulfill", **late_fields)
    before(rows, snapshot(rows, "after-timeout-wait"), late)
    before(rows, late, snapshot(rows, "after-late-fulfill"))


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
    if one(rows, "launch").get("traceVersion") == 2:
        fulfilled = one(rows, "action.fulfilled", kind=action["kind"], id=action["id"])
        before(rows, action, fulfilled)
        return fulfilled
    end = next((i for i in range(start + 1, len(rows))
                if rows[i]["event"] == "provider.perform"), len(rows))
    fields = {"kind": action["kind"]}
    if one(rows, "launch").get("traceVersion", 1) >= 2:
        fields["id"] = action["id"]
    fulfilled = one(rows[start + 1:end], "action.fulfilled", **fields)
    return fulfilled


def build_identity(directory, rows):
    manifest = json.loads((directory / 'manifest.json').read_text())
    launch = one(rows, 'launch')
    require(manifest.get('schemaVersion') == 1 and manifest.get('profileID') == 'ios-27.0', 'invalid run manifest')
    for key in ('runID', 'simulatorID'):
        require(manifest.get(key) == launch.get(key), 'manifest identity mismatch')
    identity = one(rows, 'runtime.identity')
    require(identity.get('version') == '0.1.0' and launch.get('injected') is True, 'shipping runtime not active')
    for key in ('probeSHA256', 'runtimeSHA256', 'profileSHA256'):
        digest = manifest.get(key)
        require(isinstance(digest, str) and len(digest) == 64 and all(c in '0123456789abcdef' for c in digest), 'missing build digest')
        require(identity.get(key) == digest, f'loaded {key} differs from manifest')
    for relative, key in (('CKSimRuntime.dylib', 'runtimeSHA256'), ('profiles/ios-27.0.json', 'profileSHA256')):
        path = directory / 'runtime-dist' / relative
        require(hashlib.sha256(path.read_bytes()).hexdigest() == manifest[key], f'packaged {key} differs from manifest')
    return manifest


def shipping_journal(directory, name, rows, receipt):
    manifest = build_identity(directory, rows)
    launch = one(rows, 'launch')
    path = directory / f'{name}.engine.jsonl'
    require(receipt.get('engineSHA256') == hashlib.sha256(path.read_bytes()).hexdigest(), 'engine journal hash mismatch')
    engine = [json.loads(line) for line in path.read_text().splitlines()]
    require(engine and [r['sequence'] for r in engine] == list(range(1, len(engine) + 1)), 'engine journal sequence mismatch')
    require(all(a['t_ms'] <= b['t_ms'] for a, b in zip(engine, engine[1:])), 'engine journal time mismatch')
    for row in engine:
        require(all(row.get(key) == launch.get(key) for key in ('runID', 'pid', 'bundleID')), 'engine process mismatch')
        require(row.get('profile') == manifest['profileID'], 'engine profile mismatch')
    accepted = {r['transactionID']: r for r in engine if r['event'] == 'request.accepted'}
    delivered = [r for r in engine if r['event'] == 'transaction.delivered']
    require(len({r['transactionID'] for r in delivered}) == len(delivered), 'duplicate delivered transaction identity')
    for request in (r for r in rows if r['event'] == 'request.begin'):
        match = accepted.get(request['transactionID'])
        require(match is not None and [i[:8] for i in match['actionIDs']] == request['actionIDs'], 'submitted action identity mismatch')
    inventory = {}
    for transaction in delivered:
        require(transaction['requestID'] != transaction['transactionID'], 'provider reused requested transaction identity')
        if transaction['requestID'] != 'system':
            request = accepted.get(transaction['requestID'])
            require(request is not None and request['error'] == 0 and request['actionIDs'] == transaction['actionIDs'], 'unvalidated actions delivered')
        for identity, kind in zip(transaction['actionIDs'], transaction['kinds']):
            require(identity[:8] not in inventory, 'duplicate delivered action identity')
            inventory[identity[:8]] = kind
    performs = [r for r in rows if r['event'] == 'provider.perform']
    require(inventory == {r['id']: r['kind'] for r in performs}, 'engine/probe action inventory mismatch')
    executions = [r for r in rows if r['event'] == 'provider.executeTransaction']
    require(len(executions) == len(delivered), 'engine/probe transaction inventory mismatch')
    for a, b in zip(executions, delivered):
        require(a.get('transactionID') == b['transactionID'] and a.get('actionIDs') == [i[:8] for i in b['actionIDs']], 'provider transaction identity mismatch')
    if name == 'runtime':
        one(engine, 'provider.invalidated')
        a = one(rows, 'step', name='incoming')['uuid']
        b = one(rows, 'step', name='call-waiting')['uuid']
        groups = [r for r in engine if r['event'] == 'call.grouped']
        require(len(groups) == 1 and groups[0]['uuid'][:8] == a and groups[0]['group'][:8] == b, 'runtime group membership mismatch')


def validate(directory, require_receipts=True, allow_legacy=False):
    summary = {"profile": "simulator-discovery-v2", "mediaProof": False, "scenarios": {}}
    identities = set()
    for name in SCENARIOS:
        try:
            if require_receipts:
                receipt = json.loads((directory / f"{name}.receipt.json").read_text())
                require(receipt.get("success") is True and receipt.get("completed") is True,
                        f"{name}: runner did not complete successfully")
                require(receipt.get("schemaVersion") == 2 and receipt.get("terminateExitCode") == 0 and
                        receipt.get("lastProbeEvent") == "done" and
                        receipt.get("launchExitCode") in (0, -15, 143), "invalid runner receipt")
            rows = load(directory, name)
            if require_receipts:
                launch = one(rows, "launch")
                require(launch.get("traceVersion") == 2,
                        "live run requires traceVersion 2")
                path = next(p for p in (directory / f"{name}.log", directory / f"{name}.jsonl") if p.exists())
                require(receipt.get("traceSHA256") == hashlib.sha256(path.read_bytes()).hexdigest(),
                        "receipt trace hash mismatch")
                require(type(launch.get("pid")) is int and launch["pid"] > 0 and
                        receipt.get("appPID") == launch["pid"] and receipt.get("launcherAppPID") == launch["pid"], "receipt process mismatch")
                require(receipt.get("bundleID") == launch.get("bundleID") == "dev.callkitsim.probe", "receipt bundle mismatch")
                for field in ("runID", "simulatorID"):
                    require(isinstance(launch.get(field), str) and bool(launch[field]) and
                            receipt.get(field) == launch[field], f"receipt {field} mismatch")
                require(receipt.get("scenario") == name, "receipt scenario mismatch")
                identities.add((launch["runID"], launch["simulatorID"]))
            common(rows, name)
            {"runtime": runtime, "genuine": genuine, "push": push}[name](rows)
            if require_receipts and name != 'genuine' and (not allow_legacy or shipping(rows)):
                shipping_journal(directory, name, rows, receipt)
            summary["scenarios"][name] = {"success": True, "events": len(rows)}
        except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
            summary["scenarios"][name] = {"success": False, "error": str(error)}
    summary["success"] = all(s["success"] for s in summary["scenarios"].values())
    if require_receipts and len(identities) != 1:
        summary["success"] = False
        summary["identityError"] = "mixed run or simulator evidence"
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--require-receipts", action="store_true")
    parser.add_argument("--allow-legacy", action="store_true", help="explicit pre-shipping replay; add --require-receipts to retain receipt checks")
    args = parser.parse_args()
    summary = validate(args.directory, not args.allow_legacy or args.require_receipts, allow_legacy=args.allow_legacy)
    print(json.dumps(summary, indent=2))
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
