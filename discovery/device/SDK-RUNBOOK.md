# SDK device measurement operator recipe

**Proposed, not device-qualified.** This recipe complements [the fixture guide](SDK-README.md)
for START-HERE §4.D. Run device and APNs steps only during the coordinated device
phase. Use the dedicated approved QA phone and the already built app; do not
select a device by discovery, register one, or modify LaunchServices. R3 remains deferred.

## Private inputs and bounded commands

Supply `SDK_DEVICE_ID`, `SDK_DEVICE_BUNDLE_ID` and `SDK_DEVICE_APP` from private
operator setup. `SDK_DEVICE_APP` points to the retained signed `.app`; preserve
its original source/build receipt. A documentation commit does not rebuild it.
Do not enable shell tracing. The commands below use installed `devicectl` help;
they have not been executed on a device as part of this preparation.

```sh
umask 077
: "${SDK_DEVICE_ID:?approved dedicated QA device only}"
: "${SDK_DEVICE_BUNDLE_ID:?approved QA app identity}"
: "${SDK_DEVICE_APP:?retained signed app path}"
export SDK_DEVICE_QA_RUN_ID="$(uuidgen)"
export SDK_DEVICE_QA_SCENARIO=enrollment
export SDK_DEVICE_RUN_DIR=".env/sdk-device-run-$SDK_DEVICE_QA_RUN_ID"
# The existing .env parent must be caller-owned, mode 0700 and ignored by Git.
test -d .env && test "$(stat -f %Lp .env)" = 700
mkdir -m 700 "$SDK_DEVICE_RUN_DIR"
git check-ignore -q "$SDK_DEVICE_RUN_DIR/result.md"
cp discovery/device/result-worksheet.template.md "$SDK_DEVICE_RUN_DIR/result.md"
```

Use fresh filenames for every command. Redirect both output streams to the
private run directory and record each exit status there. Stop on failure or
timeout; do not assume a timeout means no installation, launch or termination
occurred. Reconcile the owned app's state before another attempt.

```sh
perl -e 'alarm shift; exec @ARGV' 60 xcrun devicectl device install app \
  --device "$SDK_DEVICE_ID" "$SDK_DEVICE_APP" --timeout 45 \
  --json-output "$SDK_DEVICE_RUN_DIR/install.json" >"$SDK_DEVICE_RUN_DIR/install.log" 2>&1
printf '%s\n' "$?" >"$SDK_DEVICE_RUN_DIR/install.exit"

DEVICECTL_CHILD_SDK_DEVICE_QA_RUN_ID="$SDK_DEVICE_QA_RUN_ID" \
DEVICECTL_CHILD_SDK_DEVICE_QA_SCENARIO="$SDK_DEVICE_QA_SCENARIO" \
perl -e 'alarm shift; exec @ARGV' 60 xcrun devicectl device process launch \
  --device "$SDK_DEVICE_ID" "$SDK_DEVICE_BUNDLE_ID" --timeout 45 \
  --json-output "$SDK_DEVICE_RUN_DIR/launch.json" >"$SDK_DEVICE_RUN_DIR/launch.log" 2>&1
printf '%s\n' "$?" >"$SDK_DEVICE_RUN_DIR/launch.exit"

perl -e 'alarm shift; exec @ARGV' 60 xcrun devicectl device copy from \
  --device "$SDK_DEVICE_ID" --domain-type appDataContainer \
  --domain-identifier "$SDK_DEVICE_BUNDLE_ID" --source Documents/SDKDeviceQA \
  --destination "$SDK_DEVICE_RUN_DIR/container-enrollment" --timeout 45 \
  --json-output "$SDK_DEVICE_RUN_DIR/copy-enrollment.json" >"$SDK_DEVICE_RUN_DIR/copy-enrollment.log" 2>&1
printf '%s\n' "$?" >"$SDK_DEVICE_RUN_DIR/copy-enrollment.exit"
```

The phone must be awake and unlocked for development launch. Do not attach
`--console`, LLDB or UI automation to the measurement launch: their lifecycle
and signals would confound cold launch and process survival. Verify `launch.ready`,
the intended persisted `config.json`, a current token and the app/source/binary
identity in the private trace before proceeding. Protect copied files with
`0600` and directories with `0700`; copied app-container modes are not assumed.
Never print or publish `token.txt`, raw traces, receipts or UI captures.

For a measurement, choose a fresh run UUID and one of `locked-answer`,
`active-call` or `cold-reporting`. First terminate only the known owned app PID
from the preceding launch receipt, then repeat the launch/copy commands with
fresh output names and the new scenario. An already running app does not rerun
its launch configuration. Keep its readiness launch separate from its later
cold APNs launch; the cold launch reads persisted configuration, not the prior
process environment.

```sh
: "${SDK_DEVICE_PID:?known owned app PID from its launch receipt}"
perl -e 'alarm shift; exec @ARGV' 60 xcrun devicectl device process terminate \
  --device "$SDK_DEVICE_ID" --pid "$SDK_DEVICE_PID" --timeout 45 \
  --json-output "$SDK_DEVICE_RUN_DIR/terminate.json" >"$SDK_DEVICE_RUN_DIR/terminate.log" 2>&1
printf '%s\n' "$?" >"$SDK_DEVICE_RUN_DIR/terminate.exit"

# Proposed scoped absence check; inspect its actual result, not just exit zero.
perl -e 'alarm shift; exec @ARGV' 60 xcrun devicectl device info processes \
  --device "$SDK_DEVICE_ID" --filter "processIdentifier == $SDK_DEVICE_PID" --timeout 45 \
  --json-output "$SDK_DEVICE_RUN_DIR/owned-process.json" >"$SDK_DEVICE_RUN_DIR/owned-process.log" 2>&1
printf '%s\n' "$?" >"$SDK_DEVICE_RUN_DIR/owned-process.exit"
```

For cold scenarios, run termination and the scoped absence check again for the
readiness PID before sending. Do not use a user swipe force-quit as a substitute.
Record any intervening app launch; a new PID or launch UUID alone does not prove
the app was absent at delivery. Have Hamza physically lock the phone for D1;
record that observation separately. Never use a private lock selector. Retrieve
the measurement trace only after the observation window, using a fresh copy
destination. A failed locked copy is not evidence that the app could not write.

## Canonical SDK invitation

The [template](incoming-call.template.json) is parsed by the actual SDK `PushWire`
in `bash Tests/VoIPSDK/run_push.sh`. `incomingCall` is a nested JSON object;
`eventId`, `serverCallId` and `caller` belong inside it. Neither a flat invitation,
a JSON string nor the historical probe's `from` payload exercises this path.

Create a private payload without printing it:

```sh
python3 - "$SDK_DEVICE_RUN_DIR/incoming-call.json" <<'PY'
import json, os, sys, uuid
from pathlib import Path
payload = json.loads(Path('discovery/device/incoming-call.template.json').read_text())
payload['incomingCall']['eventId'] = str(uuid.uuid4())
payload['incomingCall']['serverCallId'] = str(uuid.uuid4())
with os.fdopen(os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
    json.dump(payload, stream, indent=2)
    stream.write('\n')
PY
```

Record both identifiers and the payload hash privately. Every independent send
gets fresh identifiers; intentionally reusing `eventId` tests deduplication,
not these measurements. Use only the [sandbox sender](../send-apns.mjs), a current
private token file, the matching environment-supplied `.voip` topic and a fresh
private sender receipt. Fetch credentials only through the approved private
workflow during the device phase; delete temporary key copies afterwards. The
sender's unknown outcome requires reconciliation before retry. HTTP 200 records
APNs acceptance, never confirmed delivery.

## D1 / D2 / D3 result boundaries

Copy the [empty worksheet](result-worksheet.template.md) into each private run.
Retain exact bytes and hashes, including command errors; do not repair traces
or infer absent callbacks. Bind each observation to source/input/executable
hashes, run ID, launch ID, PID, delivery/action/conversation IDs and actual OS.

- **D1:** prove cold delivery and physical lock, then correlate the actual join
  `action.ingress` and genuine `audio.activated` on the native monotonic clock.
  `(activation.nanoseconds - join.nanoseconds) / 1_000_000` measures callback
  ingress to activation in milliseconds. It does not measure the human screen
  tap; record tap evidence and its uncertainty separately. The fixture performs
  synchronous MainActor JSON/`fsync` work, so this is instrumented fixture latency,
  not a production SDK latency baseline. No activation means no latency result.
- **D2:** in `active-call`, use the fixture's reference-call button and establish
  a joined/connected conversation before a fresh invitation. Read `api=metadata`
  and its actual `mustReport` on `push.ingress`. A legacy callback has no measured
  metadata value. App state alone does not prove an active conversation. The
  fixture ends reference calls after 60 seconds; delivery after end is inconclusive.
- **D3:** prove cold launch, actual required ingress (`mustReport=true`), matching
  `report.begin`, successful `report.result`, `push.completion`, and survival of
  the same process through a recorded observation window (proposed: 30 seconds).
  That window is an operator choice, not an Apple deadline. Completion is a mark
  just before invoking PushKit's callback, not a reporting-check acknowledgement.
  Record the observed legacy path separately if used; a metadata callback with
  `mustReport=false` cannot qualify the required-report question. APNs acceptance,
  report success or a restarted process alone is insufficient. Conclude observed
  survival on this OS/run, not a universal guarantee or a no-report counterfactual.

Missing cold/lock evidence, an optional or filtered delivery, unavailable trace,
or unbound process state remains pending/inconclusive. None of these runs proves
media transport, audio-engine health or R3 teardown behavior.
