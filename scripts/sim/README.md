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

Cleanup defers transport and evidence-writing errors until every owned teardown
has been attempted, then raises the first original exception. An optional
`cleanup(on_error=callback)` observes errors in occurrence order; observer errors
cannot interrupt teardown. Failed deletion keeps its ownership record.

Python callers can use `Session(path).call(argv, timeout)`, `.checkpoint()`, and
`.cleanup()`. `bounded(argv, timeout)` provides execution without lifecycle
recovery. Sessions own their simulators; borrowed-device adapters are a separate
runner migration. Do not wrap a console launch with the CLI when its supervisor
binds native launcher PIDs or process groups.

`Session.resume(path, simulator)` transfers an existing lifecycle record between
sequential CI steps; it never creates a new budget. Runtime fixture preparation
publishes any replacement UUID to the owner file and later workflow steps.
The exact runtimes-list timeout shares that budget with create/boot/install;
an initial query with no owned device retries only the query. Borrowed sessions
and checkpointed sessions never recover. Runtime latches the checkpoint before
its existing direct launch, so this slice adds no app-launch replay.
Fixture installs log each attempt's elapsed time and use a 180-second default.
[Two independent hosted cold installs](https://github.com/ziahamza/ios-voip-sdk/pull/111#issuecomment-6398285146)
took 124.051 and 112.653 seconds. Rounding a 25% margin over the observed maximum
to the next 30 seconds gives 180 seconds; two samples are not a percentile estimate.
`CKSIM_FIXTURE_INSTALL_TIMEOUT` permits an explicit positive bound up to 600
seconds for controlled observation. This is not full runner adoption.

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

Host controls require no Xcode or simulator:

```bash
python3 -m unittest discover -s scripts/sim -p 'test_*.py' -v
```

Swift LiveKit setup uses one owned Session for create, boot, install and exact
privacy grants. A setup recovery deletes the old simulator and replays preparation
on one fresh device; microphone permission retains its 60-second bound. Repeated
command evidence is archived under `infrastructure-attempts/`, launch environment
is refreshed after replacement, and the checkpoint is persisted before the
unchanged case supervisor starts. This slice adds no console or case retry.
Cleanup preserves the primary failure and still performs independent inventory.

Runtime fixture discovery binds the launch PID, bundle and fresh run ID to one canonical host journal. Controls and watch reuse that validated container; diagnostics use the retained channel. None of those paths queries a data container through simctl. Shared simulator preparation retains its existing one pre-app budget and no-replay barrier. Generic host commands use `scripts/ci/bounded`, with a ten-second termination grace outside the command deadline.

Each Session native attempt appends its operation, configured `timeoutSeconds`,
monotonic `elapsedSeconds`, exit code and timeout flag to `commands.status.jsonl`
beside the ownership state. Recovery attempts have separate rows, including
cleanup. Arguments and environment values are excluded. Missing timing evidence
is reported without discarding the native outcome or ownership proof. Swift
LiveKit's existing per-command status files also carry the bound and elapsed time.
These observations do not change deadlines, retry eligibility or acceptance.
Elapsed time includes executor teardown and recording overhead; it is not a
product checkpoint clock or a successful completion time for a timed-out call.
Legacy cleanup uses an explicit 60-second bound for shutdown and delete, including
its always-step reconciliation; other callers retain the 30-second default.

Legacy failure diagnostics are bounded observations before owned-device deletion;
they may be unavailable and do not establish a startup cause or fix. The original
90-second scenario result remains authoritative, and entered apps are never retried.

Legacy adoption covers preparation, cleanup and diagnostic boundaries. Its direct
scenario supervisor keeps the existing product-failure fallback; bare pre-app
launch classification and full console-policy adoption remain separate work.
