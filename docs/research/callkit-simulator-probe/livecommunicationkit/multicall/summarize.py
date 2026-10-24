#!/usr/bin/env python3
"""summarize.py ROW.jsonl: one line per meaningful lckmulti event, times relative to the first row."""
import json
import sys

SKIP = {"lckmulti.performExit", "lckmulti.stepDone"}
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if r["event"].startswith("lckmulti.") and r["event"] not in SKIP]
t0 = rows[0]["mono_ms"] if rows else 0
for r in rows:
    e = r["event"][9:]
    t = int(r["mono_ms"] - t0)
    if e == "perform":
        extra = f"{r['kind']} {r['conv']} paused={r.get('isPaused','')} mergeWith={r.get('mergeWithConv','')} timeoutIn={r['timeoutIn']} appState={r.get('appState')} n={r['n']}"
    elif e == "settled":
        extra = f"{r['kind']} {r['conv']} failed={r['failed']} how={r['how']} afterMs={r['afterMs']} state={r['actionState']}"
    elif e == "changed":
        extra = f"{r['conv']} -> {r['state']}"
    elif e in ("reported", "requestResult"):
        extra = " ".join(f"{k}={r[k]}" for k in ("kind", "conv", "result", "domain", "code", "afterMs") if k in r)
    elif e == "snapshot":
        extra = r["label"] + " " + ", ".join(f"{c['conv']}:{c['state']}" for c in r["conversations"]) + (f" pending={[p['kind'] + ':' + p['conv'] for p in r['pending']]}" if r["pending"] else "")
    elif e in ("didActivate", "didDeactivate"):
        extra = ""
    elif e == "timedOut":
        extra = f"{r['kind']} {r['conv']}"
    elif e == "step":
        extra = f"{r['op']} {r.get('id','')} {r.get('other','')}"
    elif e == "waitState":
        extra = f"{r['conv']} wanted={r['wanted']} seen={r['seen']}"
    else:
        extra = " ".join(f"{k}={v}" for k, v in r.items() if k in ("status", "conv", "kind", "order", "seconds"))
    print(f"{t:>7} {e:<14} {extra}")
