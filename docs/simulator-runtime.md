# Simulator runtime (v0.1)

This is the runtime formerly published as "CallKit Simulator". It now lives in `ios-voip-sdk`, and the SDK will activate it in-process (see [START-HERE](START-HERE.md)). The standalone loader below still serves apps that don't use the SDK.

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

Standalone release provenance and verification are described in [runtime releases](https://github.com/ziahamza/ios-voip-sdk/blob/main/docs/runtime-releases.md).

## Build and run

Requirements: macOS, Xcode with an iOS simulator runtime, and Python 3.9 or newer.
Install and boot your app in a simulator first.

```sh
bash scripts/build-runtime.sh /tmp/callkit-runtime
/tmp/callkit-runtime/cksim --simulator SIMULATOR_UUID --bundle com.example.app launch
/tmp/callkit-runtime/cksim --simulator SIMULATOR_UUID --bundle com.example.app status
```

Builds contain arm64 and x86_64 simulator slices by default, a signed loader and
notifier, the CLI, profile data and a checksummed `build-info.json`. An output
directory is published only after the package is complete. For a local build on
one architecture, set `CKSIM_BUILD_ARCHS=arm64` or `x86_64`.

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

**Measured:** Phone's app-hosted XCTest integration uses a generated `.xctestrun`
and an allowlist without global simulator environment changes ([Phone #374](https://github.com/ziahamza/phone-app/pull/374),
reviewed in [the v0.1 review](progress/2026-10-21-claude-v01-review.md)).
**Proposed:** apply this procedure to each new host's test configuration; that
host still needs its own ring/join acceptance run.

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
CLI (the repository's `Tools/cksim` also works):

```sh
python3 /absolute/ios-voip-sdk/Tools/cksim --simulator SIMULATOR_UUID repair
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
end reports use the call's stored binding. Reports made asynchronously outside
the push callback have no inferred push correlation.

`faults --report-delay-ms 1500` delays incoming-report completion so tests can
answer or decline before it returns. `faults --stale-audio` suppresses activation
to exercise recovery from missing audio activation. Calling `faults` without
flags clears the faults. `--invalidate-during-handoff` invalidates the selected
provider during the next system Hold/End & Accept transaction, for lifecycle
recovery tests. A command timeout is an unknown outcome: query
`status`/`events` before retrying an externally visible action.

For direct launch customization, the process environment accepts `CKSIM_RUN_ID`,
`CKSIM_PROFILE=ios-27.0` and `CKSIM_LATENCY=device`. `CKSIM_SHADOW=1` additionally
forwards incoming reports to genuine CallKit, shielding the app from its simulator
teardown. That experimental mode does not prove real-push obligations are met.

## Verification

```sh
python3 discovery/check_harness.py
python3 discovery/check_environment.py
python3 discovery/check_cli_repair.py
bash discovery/run.sh
```

Legacy discovery compiles with Xcode 26.6 and 26.3 on macOS 26. It runs nightly
at 02:20 UTC or by manual dispatch, outside the PR/main acceptance gate. Hosted
simulator migration/startup continued to time out after the agreed hardening
time-box. Failures remain visible; this lane no longer blocks SDK work.
SDK M0/M1 is a separate required PR/main workflow, including Release device
exclusion checks. Changes to either workflow trigger that SDK acceptance.
**Measured:** [hosted run 39680771297](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39680771297)
used the iOS **26.5 (23F77)** simulator against the `ios-27.0` behavior profile.
That profile names the iPhone measurements being reproduced; it is separate
from the simulator OS and selected compiler. This CI run does not qualify
iOS 27.0 or LiveCommunicationKit. The [verification index](verification/README.md)
links current workflows and historical environment captures.

Fresh shipping runs record the selected runtime ID, exact OS version/build and
selected Xcode version/build in `manifest.json`, bind them to saved runtime
inventory/compiler output, and report all three identities in the summary.
Missing or inconsistent metadata fails qualification. Historical trace replays
are labelled separately. The runner owns and
removes its simulator, compares genuine behavior with the Swift runtime, replays
the eight measured provider scenarios, and exercises the shipped CLI. Trace,
process, run and build identities are checked together. The prototype and raw
device measurements remain under `docs/research` as reference evidence.

CallX and GetStream's mock are not dependencies and no code was copied from them.
