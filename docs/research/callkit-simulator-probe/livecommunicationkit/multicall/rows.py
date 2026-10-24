#!/usr/bin/env python3
"""Multi-call rows for the iPhone 13: the lckmulti.swift script plus the system-UI steps for each row.

rows.py NAME config  -> Documents/lck-multi.json for that row ({} disarms the probe)
rows.py NAME ui      -> JSON array for MultiCallUITests (TEST_RUNNER_MULTI_UI)
rows.py list         -> row names in run order
"""
import json
import os
import sys


def answer(conv="A"):
    # Reported while the probe is frontmost; the UI test answers it from the incoming banner.
    return [{"op": "incoming", "id": conv}, {"op": "waitState", "id": conv, "state": "joined", "timeout": 40}, {"op": "wait", "s": 2}]


def waiting(conv="B", timeout=45):
    # A call-waiting report; the UI test picks Hold & Accept or End & Accept on InCallService.
    return [{"op": "incoming", "id": conv}, {"op": "waitState", "id": conv, "state": "joined", "timeout": timeout},
            {"op": "wait", "s": 3}, {"op": "snapshot", "label": f"{conv}-after-choice"}]


def act(op, conv, other=None, **extra):
    step = {"op": op, "id": conv, **extra}
    if other:
        step["other"] = other
    return [step, {"op": "wait", "s": 3}, {"op": "snapshot", "label": f"after-{op}-{conv}{'-' + other if other else ''}"}]


def row(steps, ui, groups=2, per_group=1, **cfg):
    return {"config": {"groups": groups, "perGroup": per_group, "steps": steps, **cfg}, "ui": ["?dismiss:3", "launch", *ui]}


HA = ["accept", "holdAccept", "done:60"]
EA = ["accept", "endAccept", "done:60"]

ROWS = {
    "hold-accept": row(answer() + waiting() + act("end", "B"), HA),
    "end-accept": row(answer() + waiting(), EA),
    "swap-app": row(answer() + waiting() + act("pause", "A", paused=False) + act("pause", "B", paused=False), ["accept", "holdAccept", "done:80"]),
    "merge-b-into-a": row(answer() + waiting() + act("merge", "B", "A"), HA, per_group=2),
    "merge-a-into-b": row(answer() + waiting() + act("merge", "A", "B"), HA, per_group=2),
    "unmerge-a": row(answer() + waiting() + act("merge", "B", "A") + act("unmerge", "A"), ["accept", "holdAccept", "done:80"], per_group=2),
    "unmerge-b": row(answer() + waiting() + act("merge", "B", "A") + act("unmerge", "B"), ["accept", "holdAccept", "done:80"], per_group=2),
    "unmerge-singleton": row(answer() + act("unmerge", "A"), ["accept", "done:40"], per_group=2),
    "grouped-hold-accept-move": row(
        answer() + waiting() + act("merge", "B", "A") + waiting("C") + act("merge", "A", "C") + act("unmerge", "A"),
        ["accept", "holdAccept", "choices:45", "done:100"], per_group=2),
    # With A held and B joined, a third call offers End & Accept, Decline and End Held & Accept (no Hold & Accept).
    "third-end-held-accept": row(answer() + waiting() + act("merge", "B", "A") + waiting("C"),
                                 ["accept", "holdAccept", "endHeldAccept", "done:80"], per_group=2),
    "third-end-accept": row(answer() + waiting() + waiting("C"), ["accept", "holdAccept", "endAccept", "done:80"]),
    "grouped-end-accept": row(answer() + waiting() + act("merge", "B", "A") + waiting("C"),
                              ["accept", "holdAccept", "endAccept", "done:80"], per_group=2),
    "cap-1x1": row(answer() + [{"op": "incoming", "id": "B"}, {"op": "waitState", "id": "B", "state": "joined", "timeout": 30},
                               {"op": "snapshot", "label": "B"}] + act("outgoing", "D"),
                   ["accept", "choices:25", "?endAccept:5", "done:90"], groups=1, per_group=1),
    "cap-2x1": row(answer() + waiting() + [{"op": "incoming", "id": "C"}, {"op": "waitState", "id": "C", "state": "joined", "timeout": 25},
                                           {"op": "snapshot", "label": "C"}] + act("outgoing", "D"),
                   ["accept", "holdAccept", "choices:20", "?decline:5", "done:90"]),
    "cap-1x2": row(answer() + [{"op": "incoming", "id": "B"}, {"op": "waitState", "id": "B", "state": "joined", "timeout": 30},
                               {"op": "snapshot", "label": "B"}] + act("merge", "B", "A") + act("outgoing", "D"),
                   ["accept", "choices:25", "?holdAccept:5", "?endAccept:5", "done:90"], groups=1, per_group=2),
    # Two groups of two: after an app merge of B into A, the third call C still has no Hold & Accept.
    "cap-2x2": row(answer() + waiting() + act("merge", "B", "A") + waiting("C")
                   + [{"op": "incoming", "id": "D"}, {"op": "waitState", "id": "D", "state": "joined", "timeout": 20},
                      {"op": "snapshot", "label": "D"}] + act("outgoing", "E"),
                   ["accept", "holdAccept", "choices:45", "endHeldAccept:5", "choices:20", "?decline:5", "done:100"], per_group=2),
    "caps-none": row(answer() + [{"op": "incoming", "id": "B"}, {"op": "waitState", "id": "B", "state": "joined", "timeout": 30},
                                 {"op": "snapshot", "label": "B"}] + act("pause", "A"),
                     ["accept", "choices:25", "?holdAccept:5", "?endAccept:5", "done:80"], capabilities=[]),
    "caps-toggle": row(answer() + [{"op": "caps", "id": "A", "capabilities": []}, {"op": "wait", "s": 2},
                                   {"op": "incoming", "id": "B"}, {"op": "waitState", "id": "B", "state": "joined", "timeout": 30},
                                   {"op": "snapshot", "label": "B"}, {"op": "caps", "id": "B", "capabilities": ["pausing"]},
                                   {"op": "wait", "s": 1}] + act("pause", "B"),
                       ["accept", "choices:30", "?holdAccept:5", "?endAccept:5", "done:80"]),
    "ha-delay-pause": row(answer() + waiting(), HA, fulfill={"Pause": {"mode": "delay", "ms": 2000}}),
    "ha-reverse": row(answer() + waiting(), HA, fulfill={"Pause": {"mode": "reverse"}, "Join": {"mode": "reverse", "nth": 2}},
                      reverseWindowMs=600),
    "ha-fail-pause": row(answer() + waiting(), HA, fulfill={"Pause": {"mode": "fail"}}),
    "ha-fail-join": row(answer() + waiting(), HA, fulfill={"Join": {"mode": "fail", "nth": 2}}),
    "ha-pending-pause": row(answer() + waiting() + [{"op": "wait", "s": 35}, {"op": "snapshot", "label": "after-expiry"}],
                            ["accept", "holdAccept", "done:110"], fulfill={"Pause": {"mode": "pending"}}),
    "ha-pending-join": row(answer() + waiting() + [{"op": "wait", "s": 35}, {"op": "snapshot", "label": "after-expiry"}],
                           ["accept", "holdAccept", "done:110"], fulfill={"Join": {"mode": "pending", "nth": 2}}),
    "ea-delay-end": row(answer() + waiting(), EA, fulfill={"End": {"mode": "delay", "ms": 2000}}),
    "ea-fail-end": row(answer() + waiting(), EA, fulfill={"End": {"mode": "fail"}}),
    "ea-fail-join": row(answer() + waiting(), EA, fulfill={"Join": {"mode": "fail", "nth": 2}}),
    "ea-pending-end": row(answer() + waiting() + [{"op": "wait", "s": 35}, {"op": "snapshot", "label": "after-expiry"}],
                          ["accept", "endAccept", "done:110"], fulfill={"End": {"mode": "pending"}}),
    # Code 4: a contact "LCK Block Probe" (+1 555 555 0199) is created and blocked first, then removed by filter-unblock.
    "filter-block": {"config": {"maxSeconds": 170, "steps": [
        {"op": "incoming", "id": "X", "handle": "+15555550199", "name": "LCK Block Probe"}, {"op": "wait", "s": 62},
        {"op": "incoming", "id": "X2", "handle": "+15555550199", "name": "LCK Block Probe"}, {"op": "wait", "s": 5}]},
        "ui": ["?dismiss:3", "contactsBlock", "launch", "done:150"]},
    # The number stays blocked from filter-block: records what the screen shows while it reports.
    "filter-block-check": {"config": {"maxSeconds": 60, "steps": [
        {"op": "incoming", "id": "X", "handle": "+15555550199", "name": "LCK Block Probe"}, {"op": "wait", "s": 10},
        {"op": "snapshot", "label": "blocked-after-10s"}]},
        "ui": ["?dismiss:3", "launch", "wait:4", "dump:blocked-call", "?choices:3", "done:40"]},
    "filter-unblock": {"config": None, "ui": ["contactsUnblock", "checkBlockedList"]},
    "filter-blocked-list": {"config": None, "ui": ["checkBlockedList"]},
    # Last: the lock screen shows the full in-call UI (swap and merge); the phone stays locked afterwards.
    "locked-system-ui": row(answer() + [{"op": "wait", "s": 6}] + waiting() + [{"op": "wait", "s": 25}, {"op": "snapshot", "label": "locked-end"}],
                            ["accept", "wait:2", "lock", "holdAccept:45", "wait:3", "dump:locked-two-calls", "?swap:8", "wait:3",
                             "dump:after-swap", "?merge:8", "wait:3", "dump:after-merge", "done:30"], per_group=2),
}


LOCKED = "locked-system-ui"  # leaves the phone locked, so `run.sh locked` runs it alone, after everything else


def main():
    if sys.argv[1] == "list":
        print("\n".join(r for r in ROWS if r != LOCKED))
        return
    name, part = sys.argv[1], sys.argv[2]
    spec = ROWS[name]
    if name == LOCKED and os.environ.get("LCK_LOCKED") != "1":
        spec = {"config": None, "ui": ["?dismiss:3"]}
    if part == "config":
        cfg = spec["config"]
        print(json.dumps({"row": name, **cfg}) if cfg else "{}")
    else:
        print(json.dumps(spec["ui"]))


if __name__ == "__main__":
    main()
