# Simulator runtime (v0.1)

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
compilation. There is no system call-screen app in v0.1; use the CLI or your app's
UI. Synthetic pushes do not establish APNs delivery or iOS reporting enforcement.
State and arbitration are per application process; calls in other apps are outside
this version's scope. The runtime activates the app's real audio session; it does not provide signaling,
WebRTC transport, network peers or audio samples for a silent CI microphone.

Standalone release provenance and verification are described in [runtime releases](https://github.com/relayphone/ios-voip-sdk/blob/main/docs/runtime-releases.md).

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

Every command targets a bundle, process and run. The app must already be running
with the runtime. `status` returns full call UUIDs for subsequent commands.

```sh
cksim --bundle com.example.app push --payload-file invitation.json --must-report true
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
end reports use the call's stored binding. LiveCommunicationKit reports from its
own queue, so a report entered on another thread while exactly one required push
callback is still running is attributed to that push. Reports made after the
push callback returned have no inferred push correlation.

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

Build the separate simulator app with
`node tools/build-inspector.ts /tmp/inspector`. With the target app
running in its simulator, start:

```sh
cksim --simulator <target-UUID> --bundle <app.bundle.id> \
  --runtime-dir <runtime-package> inspect --app /tmp/inspector/CKSimInspector.app
```

The inspector creates its own disposable display simulator with the target's
runtime and device type. Keeping the target app foregrounded avoids suspension
while the inspector is visible. Ctrl-C closes the local bridge and deletes that
display simulator. To reuse a separate, already booted simulator, pass
`inspect --app <path> --inspector-simulator <display-UUID>`; that simulator is
never deleted by the command. The inspector is iPhone-only for this MVP.

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
