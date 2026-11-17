# Simulator runtime

This is the runtime formerly published as "CallKit Simulator". It now lives in `ios-voip-sdk`, and the SDK will activate it in-process (see the [documentation index](README.md)). The standalone loader below still serves apps that don't use the SDK.

A simulator-only CallKit runtime for testing existing iOS calling integrations.
Apps and SDKs continue to use Apple's `CXProvider`, `CXCallController`, actions,
observer and PushKit delegate APIs. A Swift engine supplies the missing call
service, while a small Objective-C layer interposes those APIs at launch.

The `ios-27.0` behavior profile follows measurements from an iPhone 13. It covers
provider routing, incoming and outgoing calls, answer, end, hold, mute, grouping,
DTMF, action deadlines, observer state and audio-session ownership. Its CLI can
deliver synthetic VoIP pushes and issue system call-waiting transactions.

This is experimental test infrastructure. It uses private simulator ABI and must
never be embedded in a device or App Store build. Both native layers reject device
compilation. There is no system call-screen app; use the CLI or your app's
UI. Synthetic pushes reproduce the profile's reporting enforcement, but do not establish APNs delivery.
State and arbitration are per application process; calls in other apps are outside
this version's scope. The runtime activates the app's real audio session; it does not provide signaling,
WebRTC transport, network peers or audio samples for a silent CI microphone.

Each SDK release publishes this runtime's package; its provenance and verification are described in [releases](https://github.com/relayphone/ios-voip-sdk/blob/main/docs/runtime-releases.md).

## Build and run

Requirements: macOS with Xcode 27.1 and an iOS simulator runtime, and Node.js 24 to
build the package. Install and boot your app in a simulator first.

```sh
node tools/build-runtime.ts /tmp/callkit-runtime
/tmp/callkit-runtime/cksim --simulator SIMULATOR_UUID --bundle com.example.app launch
/tmp/callkit-runtime/cksim --simulator SIMULATOR_UUID --bundle com.example.app status
```

Builds contain arm64 and x86_64 simulator slices by default, a signed loader, the
`cksim` command-line tool for the Mac, profile data and a checksummed
`build-info.json`. An output directory is published only after the package is
complete. For a local build on one architecture, pass `--archs arm64` or
`--archs x86_64`. `swift run cksim` runs the tool from a checkout.

## Apps without the SDK: load in the test host by default

Use a process launch environment for apps that do not yet activate the runtime
in-process. `cksim launch` above does this for a direct launch. For XCTest, build
with `xcodebuild build-for-testing`, copy the generated `.xctestrun`, and edit only
the selected app-hosted test target under `TestConfigurations[].TestTargets[]`.
Its `TestingEnvironmentVariables` dictionary should contain:

```text
DYLD_INSERT_LIBRARIES = <existing libraries>:/absolute/runtime/CKSimLoader.dylib
CKSIM_RUNTIME        = /absolute/runtime/CKSimRuntime.dylib
CKSIM_BUNDLE_IDS     = com.example.app
CKSIM_ENABLED        = 1
CKSIM_PROFILE        = ios-27.0
```

Append the loader to existing `DYLD_INSERT_LIBRARIES` entries, including any
inherited simulator launchd value (for example Argent), rather than replacing
them. Preserve the other generated testing variables and other test targets.
Use the actual test host's bundle ID in the allowlist; a CocoaPods app host can
have a different ID from the production app. The loader checks that allowlist
before opening the runtime. Run `xcodebuild test-without-building -xctestrun
/absolute/MyApp.cksim.xctestrun -destination 'platform=iOS Simulator,id=UUID'`.
Keep the package at its absolute path until that test invocation finishes, then
discard the edited `.xctestrun` and package. This changes no simulator launchd
environment. Xcode's `man xcodebuild.xctestrun` documents
`TestingEnvironmentVariables` as the environment for `TestHostPath`.

For UI tests, the test runner and the app under test are separate processes.
Put these variables in the selected target's `UITargetAppEnvironmentVariables`
for the app under test, or its `XCUIApplication.launchEnvironment`, with that
app's bundle ID. An injection into the test runner alone does not reach the app.
Other test tools should likewise set the environment only on the app they launch.

App-hosted XCTest integration can use a generated `.xctestrun` and an allowlist
without global simulator environment changes. Each host still needs its own
ring/join acceptance run.

## Optional simulator-wide loader and recovery

Use `install` only when a process launch environment is unavailable, such as a
manual home-screen launch. It appends the allowlisted loader to simulator
launchd, so **every subsequently launched process opens the loader**, even though
only named app bundles open the runtime. Add another allowed bundle by running
`install` for that bundle. Keep the extracted package at the same absolute path
until uninstalling it; deleting it first can prevent later simulator app launches.

```sh
cksim --simulator SIMULATOR_UUID --bundle com.example.app install
# Launch through your existing test framework.
cksim --simulator SIMULATOR_UUID --bundle com.example.app uninstall
```

Installation records its original and applied values in
`~/.local/state/callkit-simulator/SIMULATOR_UUID.json`, including recovery values
before it starts writing. Uninstall restores the environment when the recorded
values still match. If another injector appends a library, an installation stops
partway through, or the package was already deleted, run a current copy of the
CLI (`swift run cksim` in a checkout also works):

```sh
cksim --simulator SIMULATOR_UUID repair
```

Repair needs neither `--bundle` nor the old package. It removes only the saved
exact `CKSimLoader.dylib` path, preserves unrelated library entries, and restores
the saved `CKSIM_*` keys only when their values are recognized as belonging to
that installation. It preflights all keys before writing. An ambiguous external
edit to a `CKSIM_*` key, or an extra identical loader entry, refuses with the key
and ownership-file path: inspect both, preserve external edits, deliberately
restore a recognized saved value, then retry. It never guesses which external
value to overwrite. The state file stays available after a failed repair; a
completed repair deletes it, and repeating repair is a no-op. Do not delete the
ownership file before recovery. Simulator subprocesses have a 60-second deadline;
after a timeout, inspect the environment and rerun repair.

The runtime is scoped to one booted simulator. Specify its UUID when several
simulators are booted. Repair affects subsequent launches; stop and relaunch an
app that already has the runtime loaded.

## Control calls

`status --json` returns the versioned status envelope (JSON is also the default).
`calls` remains the live system-call view. `retainedCalls` adds the SDK call ID when
known, system UUID, lifecycle state, end reason and `reportedAtMS`, `answeredAtMS`,
`connectedAtMS`, `endedAtMS`. Times are monotonic milliseconds from the same runtime
epoch as journal `t_ms`; unavailable times are absent. SDK state distinguishes
connecting from connected even when the system already shows a joined conversation.
The runtime retains every live call and the most recent 256 ended calls until exit.

`answer CALL_UUID --after-ms 21000` schedules an answer 21 seconds from the incoming
report, rather than from the command. An elapsed offset answers immediately if the
call still rings. Offsets must be integers from 0 to 120000. The command returns an
`answerScheduled` acknowledgement; `answer.scheduled` and the eventual action rows
share its `requestID`. If the call ends or stops ringing first, `answer.cancelled`
records the skipped answer. A delivery failure produces `answer.failed`. Runtime
shutdown cancels pending answers.

With the SDK and runtime active in-process, `sdk.state`, `sdk.accept`,
`sdk.connected`, `sdk.ended` (with reason) and `sdk.joinDeadlineExpired` use the
existing journal and Inspector. The last event records expiry of the configured
incoming-call media preparation deadline; it does not impose a new timer or assume
that every app uses a 27-second deadline. System-only apps have no SDK call IDs or
SDK events. First-packet received/sent telemetry is planned as a separate transport
event-stream change; its absence means unknown, and connection or audio activation
never synthesizes a packet event.

Every command targets a bundle, process and run. The app must already be running
with the runtime. `status` returns full call UUIDs for subsequent commands.

```sh
cksim --bundle com.example.app push --payload-file invitation.json --must-report true
cksim --bundle com.example.app push --payload-file invitation.json --must-report true --delay-ms 5000
cksim --bundle com.example.app push --payload-file invitation.json --must-report true --duplicate 2 --spacing-ms 700
cksim --bundle com.example.app push --payload-file invitation.json --must-report true --drop
cksim --bundle com.example.app answer CALL_UUID
cksim --bundle com.example.app hold CALL_UUID --held true
cksim --bundle com.example.app hold-and-accept WAITING_UUID --active-call ACTIVE_UUID
cksim --bundle com.example.app end-and-accept WAITING_UUID --active-call ACTIVE_UUID
cksim --bundle com.example.app decline WAITING_UUID
cksim --bundle com.example.app end CALL_UUID
cksim --bundle com.example.app events
```

Payloads go through the app's actual registered PushKit delegate. Metadata-capable
delegates receive the explicit `mustReport` flag; legacy delegates always have a
reporting obligation. The runtime records the actual callback API and completion.
Each push has a correlation ID. Synchronous incoming reports inherit it; later
end reports use the call's stored binding. Reports without thread-local push context,
including LiveCommunicationKit reports on its own queue and late reports after callback
return, satisfy the oldest outstanding obligation. This FIFO attribution is unverified
simulator policy when several pushes overlap. One new UUID satisfies at most one push.

`push` accepts delivery faults for a running app. `--delay-ms` delays the first
attempt from command acceptance; `--duplicate N` adds N copies of the same payload,
and `--spacing-ms` sets the interval between attempts. Zero spacing keeps their
submission order. Timings must be nonnegative, at most 100 copies may be added,
and the entire schedule must fit within 120,000 ms. Spacing requires duplicates.
`--drop` combines with delay and duplication: each attempt is journaled as
`push.dropped` and never reaches PushKit, so it has no reporting deadline.

The command returns immediately with the original `pushID`. Every attempt has a
distinct `pushID` in `push.scheduled`, correlated to that command by `requestID`;
the original retains the request ID. Each actual `push.received` starts its own
reporting budget, including for delayed and duplicate deliveries. A report for
one copy cannot satisfy another. Pending schedules are cancelled when the runtime
stops.

With `--launch`, `--delay-ms` waits from host command acceptance before staging or
requesting launch; startup cannot wake the app early. The payload is validated
and frozen before waiting, and stopped-app verification runs after the delay.
The envelope's separate 30-second freshness window starts at staging. `--drop`
records a host `push.dropped` row and a dropped launch receipt, without staging,
launching, invoking PushKit or creating a reporting obligation. Drop may combine
with delay. Use a fresh run ID and receipt path for each request. Cold launches
now stage version-two envelopes with stable request/delivery identities;
version-one decoding remains supported. Cold-launch `--duplicate` and `--spacing-ms`
reuse the runtime scheduler, anchored to the first actual delegate entry. Keep the
host command running until the process exits: it verifies the service/PID and
records undelivered copies as `push.cancelled`, including exits before runtime
scheduling. Copies with delegate entry or a prior terminal outcome are excluded.
Concurrent explicit kills and the observer serialize cancellation writes. No copy
is replayed into a later launch. A launch transport failure leaves execution
unknown: inspect the retained envelope and events before retrying.

`status --json` includes `result.processLifecycle`: optional `process.entered` and
`runtime.ready` anchors, native registry/handler observations, and measured
launch-, entry- and runtime-relative readiness durations. Launch-relative durations
include simulator launch service latency; entry-relative values exclude earlier
startup/dyld work. Registry readiness is checked on its delivery queue; handler
readiness requires an explicit native acknowledgement of an installed generation.
The Expo attachment bridge emits that acknowledgement in Debug simulator builds.
Missing observations remain absent; the host records separate registry/handler
observation timeout events after 30 seconds while continuing exit supervision.
Envelope expiry is a distinct event with its own freshness bound. CLI watch and
Inspector retain each host/runtime producer sequence in one combined event view.

### Push reporting enforcement

The `ios-27.0` profile enforces reporting by default. Legacy delegates always owe a
report; metadata-capable delegates owe one exactly when `mustReport` is true.
Completion and callback return do not satisfy or cancel an obligation. An incoming
report must **enter under a new call UUID** before its delivery-relative deadline.
Reporting an existing call again does not count, including when the report fails
with duplicate UUID code 2 ([#247](https://github.com/relayphone/ios-voip-sdk/pull/247)).
A filtered report under a fresh UUID counts even when its completion returns an error.
The runtime remembers incoming-report UUIDs for the process; reuse after a call ends also
does not count, an explicitly unverified simulator policy.

| Delivery context | Reporting budget | Qualification |
| --- | --- | --- |
| Foreground without a joined call, or newly launched | 4.4 s | iPhone 13 / iOS 27.0 and 27.1: termination about 4.4 s after delivery; a report started at 3.15 s survived, one due at 5 s did not |
| Background with a joined call | 30 s | iPhone 13 / iOS 27.0 and 27.1: a `callEnded` push re-reported against the live call terminated about 30 s after delivery; applying that budget to other required pushes in this context is unverified |
| Foreground with a call, `mustReport: false` | No deadline | iPhone 13 / iOS 27.0 and 27.1: PushKit did not require reporting and the process survived |
| Other required-push contexts | 4.4 s | Unverified fallback: background without a joined call, foreground with a call when explicitly required, or unknown activity |

The [push captures](../Tests/Fixtures/LiveCommunicationKit/push/README.md) and
[#247](https://github.com/relayphone/ios-voip-sdk/pull/247) describe the measurements.
The runtime snapshots UIKit activity and joined-call state at delivery; later changes
do not move the deadline. It models neither lock state nor background suspension.
It always honors metadata `mustReport: false`, including contexts where iOS 27.1 was
observed to contradict that flag; those contradictions are outside this rule.

`push.reportDeadline` records the budget, verification and evidence. `report.incoming`
includes `qualifyingReport`, and `push.reportSatisfied` binds a qualifying UUID to its
push. On expiry the runtime appends `diagnostic.pushReportExpired` and
`runtime.processTerminated`, with `pushID`, reason `required-new-call-report-missing`
and `signal: 6`, flushes the journal and aborts the app with SIGABRT, as the measured
PushKit failure did. The host can read the journal after the process exits. There is
no enforcement opt-out; tests of report errors can report directly without a push.

`faults --report-delay-ms 1500` delays incoming-report completion so tests can
answer or decline before it returns. `faults --stale-audio` suppresses activation
to exercise recovery from missing audio activation. Calling `faults` without
flags clears all faults; with flags, omitted settings stay unchanged.
`--invalidate-during-handoff` invalidates the selected
provider during the next system Hold/End & Accept transaction, for lifecycle
recovery tests. A command timeout is an unknown outcome: query
`status`/`events` before retrying an externally visible action.

Incoming-report filtering is a persistent setting for the current runtime
session, separate from faults. The Inspector exposes the same mutually exclusive
toggles as the CLI:

```sh
cksim --bundle com.example.app incoming-filter --reason do-not-disturb
cksim --bundle com.example.app incoming-filter --reason none
```

| Reason flag | Incoming-call error code | Device qualification |
| --- | --- | --- |
| `do-not-disturb` | 3 | Measured: about 2.07 s to error; process survives; same-number repeat after 69 s still filtered |
| `restricted-sharing-mode` | 5 | Unverified |
| `call-is-protected` | 6 | Unverified |
| `sensitive-participants` | 7 | Unverified |

Errors use `com.apple.CallKit.error.incomingcall`. Each report snapshots the
selected filter and callback delay when it enters; later settings affect future
reports. Filtered reports create no call, ring timer or audio activation. Codes
5–7 currently reuse the 2.07 s delay as explicitly unverified simulator policy.
The [device capture](../Tests/Fixtures/LiveCommunicationKit/push/README.md)
is the reference for code 3; filtering never grants a repeated-caller exception.
The [blocked-number LCK measurements](../Tests/Fixtures/LiveCommunicationKit/multicall/README.md)
([#85](https://github.com/relayphone/ios-voip-sdk/pull/85)) succeeded and rang; a repeat
66 seconds later also succeeded, with the unanswered call ending at about 60 s.
Code 4 is not produced by iOS 27.0 for LCK in these measurements. It is available
only as an explicit fault: `faults --incoming-error-code 4`; use `0` to clear it.
The Inspector labels it separately as an injected error. Its callback uses the
normal configured delay, not the measured DND delay. Journals identify it with
`verification: injected-fault` and `filterReason: none`. Duplicate UUID code 2
still takes priority. Each entered report retains its fault/filter snapshot.
`RuntimeTests` checks the app's actual completion errors for filters 3/5–7 and
injected fault 4, that the app's mailbox still answers beyond 4.4 s, and that a
repeated call from the same number is filtered too.

For direct launch customization, the process environment accepts `CKSIM_RUN_ID`,
`CKSIM_PROFILE=ios-27.0` and `CKSIM_LATENCY=device`. `CKSIM_SHADOW=1` additionally
forwards incoming reports to genuine CallKit, shielding the app from its simulator
teardown. That experimental mode does not prove real-push obligations are met.

## Remaining device measurements

The iPhone 13 / iOS 27.0 LCK-only captures in
[#85](https://github.com/relayphone/ios-voip-sdk/pull/85) cover system Hold/End/End Held
& Accept, delayed or failed constituents, configuration-dependent choices, successful
application unpause, merge/unmerge pass-through and lock-screen behavior. The
[multi-call report](../Tests/Fixtures/LiveCommunicationKit/multicall/README.md)
contains the observations; the cases below remain unverified.

LCK exposes neither concrete transaction IDs nor group membership. Simulator IDs
provide simulator correlation. The advertised action `timeoutDate` is 30 seconds;
observed effective expiry is about 5.3 seconds for Pause/End and 64 seconds for Join.
Representative samples and simulator scheduling policies do not establish bounds
for other devices, OS versions or action kinds.

The simulator uses these observations for system call-waiting settlement barriers,
effective expiry, capacity choices and application unpause behavior. Transaction
identity and group membership remain simulator policy. Injected delayed-action
and audio regressions verify that policy; they add no device measurements.

| Initial state | Measurement | Evidence needed |
| --- | --- | --- |
| A paused, B joined, configuration 2×1 | In one application `perform`, pause B and unpause A | Constituent inventory/order, B's resulting state, delivery versus settlement, intermediate states and audio order. Repeat reversed fulfillment, each failure and each pending constituent. |
| A paused, B joined, configuration 2×1 | Unpause A alone with delayed, failed or pending settlement | Generated End B timing versus delivery and settlement, both conversation states and audio order. The existing capture covers immediate successful settlement only. |
| Genuine CallKit-only probe | Hold/End/End Held & Accept and application merge/unmerge | Actual `CXTransaction` identifiers/composition and public CallKit group behavior. Use a separate probe without a simultaneous LCK manager (D13). |
| Ringing, joining or leaving near capacity | Incoming/start during each transition, then end/fail the existing call | Which transient states consume capacity, slot-release timing and error domain/code. Existing measurements cover joined/paused capacity and outgoing Start error 7. |
| An otherwise valid conversation/action | Leave Start, Mute, tones, Merge or Unmerge pending | Effective expiry versus advertised 30 seconds, cleanup callbacks, state and audio effects. |
| Conversation left after a failed or expired constituent | Immediately fulfill the generated cleanup End; compare failed/pending settlement | Reproduce the observed cleanup-End timeout after fulfillment, retaining action identity and duplicate callbacks. Keep this anomaly distinct from normal End settlement. |
| Relevant system settings enabled | Incoming reports for restricted sharing, protected calls or sensitive participants | Actual codes 5–7, domain, report-to-completion interval, process survival and repeated-caller behavior. Incoming code 4 was absent in the LCK captures; its injected form is a synthetic fault. |

Retain OS/build, configuration, full stable conversation/action UUIDs, monotonic
and wall times, callback entry/exit, parameters, advertised deadlines, settlement
times, manager snapshots and audio callbacks. Identify each assertion's source:
public LCK observation, genuine CallKit observation or simulator policy.

## Verification

```sh
swift test
xcodebuild test -scheme VoIPSDK-Package -only-testing:RuntimeTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
node tools/runtime-smoke.ts /tmp/callkit-runtime
```

`RuntimeEngineTests` checks the runtime's policies against the profile and replays
the iPhone 13 captures in `Tests/Fixtures/LiveCommunicationKit`; `CKSimToolTests`
covers `cksim` against a fake simulator and mailbox. `RuntimeTests` activates the
runtime in the test process and drives CallKit and genuine LiveCommunicationKit
calls through its mailbox. The smoke test launches an app that doesn't link the
runtime with a built package's runtime injected, then answers and ends a pushed
call with that package's `cksim`. The release workflow runs all three against the
package it publishes.
The smoke app also verifies actual process termination near 4.4 s for missing, late
and duplicate reports, survival of a report entered at 3.15 s, and unreported optional
metadata pushes. These intentional terminations run outside the test runner.

CallX and GetStream's mock are not dependencies and no code was copied from them.

### Live runtime timeline

`cksim --simulator <UUID> --bundle <app.bundle.id> watch` replays the current
run and follows new events until Ctrl-C. Add `--json` for the original JSONL,
`--after <sequence>` to skip already consumed events, or `--duration <seconds>`
for a bounded CI capture. Watching a source-activated SDK app requires no runtime
package or injection. A new session resets the sequence and the watcher follows
it with a diagnostic on stderr.

The CLI, CI and inspector consume the same append-only
`Documents/.callkit-simulator/<runID>/events.jsonl` channel. Every row has
`schemaVersion: 1`, `sequence`, `runID`, `pid`, `bundleID`, `profile`, monotonic
`t_ms` since runtime preparation, and Unix `wallTimeMS`. Sequences start at 1
within each session; consumers reject unsupported versions and identity/order
mismatches and buffer incomplete trailing lines. New event names and fields are
additive within version 1. Do not assume a fixed set of event names.

For an offline snapshot, use `cksim --bundle com.example.app events --run-id <runID>`.
This reads the selected app container without a runtime mailbox round trip or an installed
runtime package, so host observations remain readable before app startup and after exit.
It emits JSONL, while `events` without `--run-id` retains its mailbox response format.
Cold push launches persist `process.launchRequested` before invoking the simulator launcher.
They require a fresh run ID: an existing runtime or host run directory prevents staging, so
an earlier invocation's boundaries cannot be attributed to a new process.
Host producers each own an exclusive segment at
`Documents/.callkit-simulator/process/<runID>/<producerID>.jsonl`; they never append to the
runtime's file. A host row has a producer UUID and an optional app PID, absent before launch.

Runtime rows additionally carry absolute `uptimeNanoseconds`. Snapshots merge this shared
monotonic time across host and runtime segments, breaking ties by producer identity and then
producer sequence. They preserve each producer's sequence instead of renumbering it globally.
Wall-clock changes never reorder observations. A runtime journal without absolute uptime is
refused with a rebuild diagnostic rather than guessed into the host timeline. Each snapshot
validates invocation identity and contiguous producer sequences, omits incomplete trailing
rows, and limits segments to 16 MiB and the merged rows to 64 MiB.
Each runtime invocation emits `process.entered` with `boundarySource: runtime-preparation`
at its first Swift preparation entry, followed by `runtime.ready` with
`boundarySource: hooks-installed` when installation completes. Entry retains the captured
monotonic time even though the journal opens later, and is the runtime's `t_ms: 0` anchor.
For source activation this includes only execution from runtime preparation onward, not
earlier app startup or pre-entry dyld work. Hook readiness establishes neither PushKit
registry readiness nor application handler attachment; those require separate observations.
The Inspector and `watch` continue to follow the runtime segment; combined streaming and
readiness projections follow separately.

Stop a specific run before a cold-recovery test with
`cksim --bundle com.example.app process kill --run-id <runID> --cause abrupt`.
Use `--cause user-requested` for simulator termination instead of an abrupt kill.
The host resolves the installed bundle, checks its published run and live service PID,
persists `process.killRequested`, and repeats identity verification immediately before
termination. It records `process.exited` and returns a JSON receipt only after both the
service and old PID are absent. `--command-receipt <new-file>` persists that receipt.
After confirmed exit, the host reads the pinned run's final delivery journal and
records `push.cancelled` for scheduled copies that never entered a PushKit delegate
and were not dropped or already cancelled. Each row retains its request ID, push ID,
old PID and requested exit cause; the receipt's `cancelledDeliveries` lists those IDs.
Delegate entry ends pending status even if its reporting obligation or completion is
still outstanding. Cancellation never fulfills a reporting obligation.
An incomplete or inconsistent journal leaves delivery outcomes unknown and fails the
command after retaining the confirmed `process.exited` boundary; it cannot manufacture
cancellation. This stricter final-snapshot rule does not change offline event snapshots,
which still omit incomplete tails. Automatic launch supervision follows separately;
cold-launch duplicate flags remain gated until that observer is available.
Identity changes, query failures, and an unconfirmed exit fail the command; inspect state
before staging another push. These controls model test intent, not jetsam selection or
SpringBoard's persistent force-quit eligibility. A later `push --launch` is an explicit
launch override and requires a fresh run ID.

Reports use `report.*`; conversation snapshots use `call.changed` (including
caller name, handle, ringing, connected, held, muted and ended). Actions use
`action.deadline`, `action.settled`, `action.expired`, `action.timeout` and
`action.cancelled`. Action rows carry kind, origin, call and transaction identity,
provider API, issue/deadline wall times, the device profile's deadline/expiry
seconds, and monotonic `latencyMS` since delivery. Settlement includes
`fulfilled` and whether expiry already occurred. `expired` records the runtime's
expiry decision; `timeout` separately records the provider timeout callback path.
Provider invalidation cancels remaining actions. Push lifecycle and reporting
violations, audio activation/deactivation/failure and runtime diagnostics are on
this channel too. Caller metadata is local development data in the app container.

Compare action latency to its advertised budget: the measured profile has LCK
30 s deadlines and CallKit 60/600/5 s deadlines. This is a deadline comparison,
not a measured device benchmark for the application's handler. Profile expiry
policies retain the measured/proposed qualifications in the profile source.

### SwiftUI call inspector

The Inspector runs as a native Mac app or in a separate display simulator.
The Mac app is recommended: it is lighter and stays beside the target simulator.
Build it for macOS 26 or later, then connect to the running target:

```sh
node tools/build-inspector.ts /tmp/inspector-mac --platform macos
cksim --simulator <target-UUID> --bundle <app.bundle.id> \
  --runtime-dir <runtime-package> inspect --app /tmp/inspector-mac/CKSimInspector.app
```

`cksim inspect` detects the Mac bundle, launches it with the authenticated bridge
environment, and closes it on Ctrl-C. To run the iOS Inspector instead, use the
default simulator build:

```sh
node tools/build-inspector.ts /tmp/inspector-ios
cksim --simulator <target-UUID> --bundle <app.bundle.id> \
  --runtime-dir <runtime-package> inspect --app /tmp/inspector-ios/CKSimInspector.app
```

For an iOS bundle, the inspector creates a disposable display simulator with the target's
runtime and device type. Keeping the target app foregrounded avoids suspension
while the inspector is visible. Ctrl-C closes the local bridge and deletes that
display simulator. To reuse a separate, already booted simulator, pass
`inspect --app <path> --inspector-simulator <display-UUID>`; that simulator is
never deleted by the command.

The incoming banner expands to a full call screen. Answer and Decline handle a
single incoming call. Call waiting options follows the runtime's available choices,
including Hold & Accept, End & Accept and End Held & Accept where supported.
End Call ends a connected call. Application pause, unpause, merge and unmerge
controls request application origin; call-waiting buttons request system origin.
Acceptance follows the resulting journal state. Conversations, pending deadlines, action
settlement latency versus the profile budget, and audio activation remain live.
The device-reference section compares journal-measured simulator intervals with
the iPhone 13 / iOS 27.0 LCK captures: about 190 ms from push to report done,
236 ms from join callback to audio activation, 8–17 ms from mute fulfillment to
its echo, and a 4.4 s unreported-push deadline. It names the simulator API and
measurement endpoints; missing or ambiguous event pairs remain unmeasured.
The UI retains the latest 300 events and five ended conversations; the full
journal remains available to watch and CI.

A random-token-authenticated bridge binds only to host loopback. It incrementally
reads the same event channel and forwards system call controls, application
pause/unpause and merge/unmerge requests, incoming-report filter settings and
the explicit incoming code 4 fault through the existing mailbox.
The target run/process identity is pinned for both reads and
commands. A target restart requires reconnecting with `cksim inspect`; connection
errors disable controls. A control timeout means its outcome is unknown: inspect
the timeline before retrying. No inspector transport or app code is linked into
the SDK or device builds.

`InspectorTests` covers the Inspector's model on the host: its timing references,
its LiveCommunicationKit projection, and that a control or setting changes nothing
until the journal confirms it. `RuntimeTests` runs the same model against the
runtime's real journal on the simulator, under `xcodebuild test`: it follows and
answers a CallKit call, sets the incoming filter and the injected error, and controls
LiveCommunicationKit calls with system and application origin.

The `Inspector GUI` CI workflow drives the Mac Inspector with macOS XCUITest beside one
target simulator: expand an incoming banner, answer, end the call, then change an incoming-report
filter. It checks the target journal for the ordered report, fulfilled answer and end
actions, connected and ended snapshots, and confirmed filter setting. The incoming push
waits until XCUITest has activated the Inspector, so runner startup does not consume the ring timeout. Screenshots are
diagnostic only: on failure, the workflow uploads XCUITest attachments and a final screenshot
of the target simulator in an `inspector-journey` artifact, retained for seven days.

### Optional packet observations

`CallMedia.transportEvents()` returns typed `MediaTransportEvent` observations, with a `CallID`,
`firstPacketReceived` or `firstPacketSent`, and a `SuspendingClock.Instant`. Existing media
implementations compile unchanged and return an empty stream. Missing directions mean unknown.
`MediaTransportEvent.Kind` is an extensible, hashable value type. New kinds may be added;
consumers compare the static members they understand and use a fallback for other values
(including a `default` branch when switching). The packet journal ignores kinds it does not know.
Media implementations return an independent stream per subscriber, and emit each direction at
most once per preparation. Subscribe before preparing media to observe its earliest packets.
The SDK subscribes before attaching the calling framework and push source.

The LiveKit native example reads actual `inbound-rtp.packetsReceived` and
`outbound-rtp.packetsSent` counters greater than zero. It checks unresolved directions every
250 ms for at most 30 seconds after preparation, stopping when both are observed, or on release,
failure or teardown. Its timestamps identify when sampling first observed the counter; they do
not claim the packet's arrival/send time. Statistics may update less often than the sampler.
Adapters without packet counters keep the default empty stream. Preparation, connection and
activation never stand in for packet observations. No raw transport statistics are public events.

With an embedded Debug simulator runtime, the journal records `sdk.firstPacketReceived` and
`sdk.firstPacketSent`, each with `callID`, `callUUID` and `observedAtMS` on the journal's runtime
epoch. `t_ms` remains the journal receipt time; `observedAtMS` preserves the earlier observation.
The suspending monotonic clock matches the journal's uptime clock across host sleep. Observations
before runtime startup or with future timestamps are discarded. Packet journal instrumentation is
absent in device and Release builds. This stream does not change call state or action settlement.

### Confirmed video observations

`calls[].hasVideo` and `retainedCalls[].hasVideo` reflect successful framework reports (`CXCallUpdate.hasVideo`, including the LiveCommunicationKit adapter). Requests and SDK previews do not predict the value. Each confirmed change emits `call.videoChanged` with `callUUID`, `hasVideo` and runtime-relative `atMS`, and appends `{atMS, hasVideo}` to the retained call's `videoChanges`. Same-value reports add no video transition. Ended and unknown calls keep their history unchanged. cksim status, watch and Inspector expose these observations.

iOS has no system-initiated mid-call video action; there is no simulator video injection command. App and server changes must travel through the app's framework-report path. Older recordings without video fields decode as audio-only with an empty video history.

### Delayed JavaScript attachment checks

The bundled example integration build selects `journeys/entry.ts`, leaving the normal
example entry and handler unchanged. The host writes a validated scenario configuration
before launch (`handlerAttachDelayMS`, `connectDeadlineMS`, run identity). This build alone
sets its connection deadline to 27 seconds. Incoming controls use `push --launch`, report
natively before JavaScript attaches, and answer through `cksim answer`.

The test coordinator observes connecting, then delays ordinary handler attachment by one
second or 28 seconds. It reconciles current calls before starting its counting application
transport and reporting connection. Native `app.handlerReady` acknowledgement is required;
a JavaScript timestamp or PushKit registry registration cannot substitute for it. The late
control must end with `failed.connectTimedOut` before attachment, with zero transport starts
and no positive packet observations. A distinct preview-Join control delays attachment
past placement expiry, requires `deadline_exceeded`, and remains a preview with a failed
system action. It does not claim a connection timeout.

The counting transport produces no network traffic. Its counters prove that the fixture
never started application media in the late controls; missing runtime packet observations
alone prove only missing telemetry. Real packet qualification uses the media test harness.
Each scenario retains application results, the merged journal and launch diagnostics as CI
artifacts. These checks model call state, not the lock-screen appearance or APNs eligibility.
