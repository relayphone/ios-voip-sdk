# Simulator lifecycle helper

`sim.py` bounds host commands, records simulator ownership before create, and
allows **one shared infrastructure retry** before the caller marks an app
checkpoint. It never changes call deadlines or decides product assertions.

For shell runners, source `sim.sh`, set `SIM_STATE` inside a fresh output
directory, and install an EXIT/INT/TERM cleanup trap before creating a device:

```bash
SIM_STATE="$OUT/simulator-state.json"
source scripts/sim/sim.sh
UDID=''
trap 'sim_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
UDID=$(sim_limit 30 xcrun simctl create "$NAME" "$DEVICE_TYPE" "$RUNTIME")
sim_limit 60 xcrun simctl boot "$UDID"
sim_limit 300 xcrun simctl bootstatus "$UDID" -b
sim_limit 180 xcrun simctl install "$UDID" "$APP"
sim_limit 60 xcrun simctl privacy "$UDID" grant microphone "$BUNDLE"
# Keep the caller's console supervisor and its existing deadline here.
# Mark the first observed app checkpoint before any further lifecycle calls.
sim_checkpoint
```

Every bound is in seconds. A timed-out host process and its process group are
killed and reaped; timeout returns 124. Native stdout and exit status are
preserved. Recovery from boot, bootstatus, install or privacy grant failure
deletes the old device, creates a fresh one, and replays successful preparation
with the original timeouts, including earlier installations and privacy grants.
Create, boot, bootstatus, install, privacy grants and eligible launch share the
same single pre-app retry budget. Only exact `privacy <device> grant <service> <bundle>`
commands join recovery and preparation replay; reset, revoke and other privacy
operations remain bounded without retries or replay. The shell wrapper updates
`UDID`; an optional `simulator_changed` callback updates the runner's evidence
identity.
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

`sim.sh` exports `SIM_STATE` to console children. `Session.attach(path, simulator)`
joins that existing owned session and verifies its current simulator; it never
creates a child budget. `reserve_retry()` atomically spends the single budget
shared by create, boot, installation, privacy grants and launch. Checkpoints and
spent reservations are permanent across processes and later scenarios.
The stable session lock fails closed on contention instead of extending a
startup deadline. Attached children update only those flags; stale ownership
writes are refused, preserving the authoritative cleanup records.

`discovery/run_scenario.py` keeps its direct native launcher and stream handling.
With an attached session, an exact completed pre-app rejection may recover once
after proving its own launcher group is absent. It retains the first trace and
receipt under `<trace>.preapp-attempt-1/` and gives replay only the time remaining
in the original startup deadline. Any app/PID/probe evidence latches the shared
checkpoint, including evidence from a failed capture. Missing session context
allows one capture without recovery; invalid supplied context fails closed.

An inherited-group SDK capture only latches checkpoints and classifies failures.
Its SDK driver remains the recovery owner, consumes the same reservation, and
retains all session/journal, group-absence and late-evidence checks. M0's first
app checkpoint disables recovery in its later bootstrap, M1 and SDK journeys.

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
