import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def events(name):
    path = out / f"{name}.log"
    if not path.exists(): return []
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        if "PROBE " in line:
            try: rows.append(json.loads(line.split("PROBE ", 1)[1]))
            except ValueError: pass
    return rows
for name in ["genuine", "runtime", "push"]:
    rows = events(name)
    count = lambda e: sum(1 for r in rows if r["event"] == e)
    results = [f'{r["label"]}={r["result"].split(".")[-1]}' for r in rows if r["event"] in ("request.completed", "report.incomingCompleted")]
    mic = [f'{r["label"]}:{r.get("frames", 0)}' for r in rows if r["event"] == "mic.result"]
    print(f"== {name}: events={len(rows)} didActivate={count('provider.didActivateAudio')} systemEnds={sum(1 for r in rows if r['event']=='provider.perform' and r.get('kind')=='CXEndCallAction')} timedOut={count('provider.timedOut')} pushes={count('push.received')} mic={mic}")
    print("   " + ", ".join(results)[:1500])
log = (out / "callservicesd.log")
if log.exists():
    text = log.read_text(errors="replace")
    print(f"== callservicesd: no-UI disconnects={text.count('wont be a UI')} audio activation errors={text.count('Error setting audio active')}")
