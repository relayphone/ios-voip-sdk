# Simulator lifecycle helper

`sim.py` bounds host commands, records simulator ownership before create, and
allows **one shared infrastructure retry** before the caller marks an app
checkpoint. It never changes call deadlines or decides product assertions.

For shell runners, source `sim.sh`, set `SIM_STATE` inside a fresh output
directory, and install an EXIT/INT/TERM cleanup trap before creating a device:

```bash
source scripts/sim/sim.sh
SIM_STATE="$OUT/simulator-state.json"
UDID=''
trap 'sim_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
UDID=$(sim_limit 30 xcrun simctl create "$NAME" "$DEVICE_TYPE" "$RUNTIME")
sim_limit 60 xcrun simctl boot "$UDID"
sim_limit 300 xcrun simctl bootstatus "$UDID" -b
sim_limit 180 xcrun simctl install "$UDID" "$APP"
# Keep the caller's console supervisor and its existing deadline here.
# Mark the first observed app checkpoint before any further lifecycle calls.
sim_checkpoint
```

Every bound is in seconds. A timed-out host process and its process group are
killed and reaped; timeout returns 124. Native stdout and exit status are
preserved. A boot, bootstatus or install recovery deletes the old device,
creates a fresh one, and replays successful preparation with the original
timeouts, including earlier installations. The shell wrapper updates `UDID`;
an optional `simulator_changed` callback updates the runner's evidence identity.
Write final identity from the current device, never a cached original UUID.

Ownership records persist full unique names before create. A create timeout is
reconciled through exact-name inventory; other devices are never selected by
prefix. Cleanup attempts delete even when shutdown times out, and retains
unresolved ownership when deletion or inventory fails. Call cleanup again from
the workflow's always-running step if the runner was forcibly killed.

Python callers can use `Session(path).call(argv, timeout)`, `.checkpoint()`, and
`.cleanup()`. `bounded(argv, timeout)` provides execution without lifecycle
recovery. Sessions own their simulators; borrowed-device adapters are a separate
runner migration. Do not wrap a console launch with the CLI when its supervisor
binds native launcher PIDs or process groups.

The direct launch API retries only the exact NSPOSIX 3/no-process-handle
rejection with empty stdout. Timeouts, partial output, PID acknowledgements and
checkpoints forbid replay. Evidence supervisors that also inspect runtime
sessions/journals must retain those stricter guards and their original aggregate
deadline. Never nest their existing retry loop with a helper retry loop.

Failures and recovered retries appear in `GITHUB_STEP_SUMMARY` as `infra:<step>`
with the retry result. Use `sim.py product <check>` for product failures; it never
executes or retries a check. Summary labels exclude command arguments and
environment values. The lifecycle API rejects `spawn` and container RPCs. During
incremental adoption, `sim.sh` keeps existing product probes on the bounded path
without lifecycle retries; their replacement requires the owning lane's product
controls.

A stateless bounded probe can declare one expected nonzero status with
`sim.py call --accepted-status 1 '' 180 <command>`, or scope
`SIM_ACCEPTED_STATUS=1 sim_limit 180 <command>` in shell. The native status is
preserved without a failure label or marker. Only native status 1 can be
accepted; usage errors (2), timeouts (124), helper exceptions (125 with this
option), and signal exits remain failures. Stateful lifecycle calls reject the
CLI option and ignore the shell scope, retaining their existing retry policy.

Set `SIM_CLEANUP_TIMEOUT` before shell lifecycle calls when a runner uses a
different cleanup bound. Recovery uses that same bound; final cleanup accepts
it explicitly as `sim_cleanup <seconds>`.

`paths.py` replaces completed-app container queries with host filesystem
discovery. It first binds the original trace/hash/PID/stop receipt, then requires
one canonical session under the exact owned simulator and its original journal.
It refuses ambiguous or stale sessions and symlink paths. The runner still copies
the journal and runs its unchanged product conformance checks.

Host controls require no Xcode or simulator:

```bash
python3 -m unittest discover -s scripts/sim -p 'test_*.py' -v
```
