# Simulator CallKit discovery

`run.sh` runs an instrumented CallKit probe in a run-owned simulator three ways: genuine CallKit, the same app with the injected runtime spike, and a synthetic VoIP push with a shadow report. This is the executable baseline for runtime PR #2, not the packaged Swift implementation.

Run `python3 discovery/check_harness.py` for adversarial CLI checks against the saved hosted traces and real subprocess completion/failure/timeout paths. Run `bash discovery/run.sh` on a Mac for native execution. It prints a fresh evidence directory; an explicit `OUT` must not already exist. Temporary build files and the owned simulator are removed on exit, while evidence remains.

After a current runtime capture completes, run `python3 discovery/check_shipping_controls.py <output-directory>`.
It first requires passing shipping, semantics and generation captures, then
materializes tampered copies for the shipping mute echoes, post-end unmute,
engine journal, controller outcomes, action identities, observer states and
lifecycle checks. It recomputes the receipts' hashes so each rejection exercises
the intended semantic rule. Its JSON result binds the controls to the input
manifest and traces. The mutations are derived negative tests, not additional
simulator or device measurements. Historical strict-v2 fixtures remain unchanged.

Run `python3 discovery/check_cli_controls.py` for synthetic controls against the
real `Tools/cksim` executable: package corruption and traversal, invalid runtime
sessions, mismatched response identities and command timeout. A temporary fake
`xcrun` supplies a mailbox responder; the controls do not use a simulator or
write loader installation state.

The launcher watches the probe's `done` event, then terminates only that run's app. The SwiftUI probe otherwise remains alive. A missing terminal marker, failed app termination, unexpected launcher status, or incomplete evidence fails the run. Genuine simulator teardown/unknown-call errors are expected control behavior; runtime outcomes, state, answer expiry, and audio ownership are asserted separately.

`summarize.py <directory>` replays saved `.jsonl` or captured `.log` traces. Live runs additionally require process receipts and trace version 2 with `--require-receipts`. Shipping runtime qualification also binds the manifest's exact simulator runtime ID, OS version/build and selected compiler version/build to saved `runtimes.json` and `compiler-version.txt`. The summary reports these separately from the `ios-27.0` behavior profile. Missing or inconsistent environment metadata fails qualification. Loaded runtime versions must match the run manifest and packaged build information. Historical pre-shipping replay requires `--allow-legacy`; add `--require-receipts` to keep receipt checks for the synthetic strict-v2 fixtures. Historical fixtures remain immutable replay inputs and are labelled `historical-replay`; replay success does not qualify the current runtime or an OS version. Microphone frames can have zero peak on hosted runners: processing frames proves neither audible playback nor independent two-way media. The synthetic lane proves delivery/reporting, not APNs wake-up or watchdog behavior.

The SDK header controls compilation of the newer PushKit callback and metadata subclass; older SDKs use the legacy callback. Both require hosted execution evidence before a toolchain is called supported. No provider/APNs credentials are needed for this harness.

`COMPILER_DEVELOPER_DIR` selects a compiler/SDK separately from the active Xcode
that hosts CoreSimulator. CI tests Xcode 26.6 and 26.3 compiler paths on macOS 26.
**Measured:** [hosted run 39680771297](https://github.com/relayphone/ios-voip-sdk/actions/runs/39680771297)
used iOS **26.5 (23F77)** with the `ios-27.0` behavior profile. Its Xcode 26.6
lane used Xcode **26.6 (17F113)** on macOS **26.6.2 (25G83)**. The compiler
matrix does not establish additional simulator OS coverage. This run does not
qualify iOS 27.0 or LiveCommunicationKit; LCK acceptance is the next work item
in [START-HERE §4.B](../docs/START-HERE.md#b-make-lck-the-runtimes-acceptance-target).
The [verification index](../docs/verification/README.md) links current workflows
and historical environment captures. Future runs select the newest available iOS simulator
runtime and record its exact version/build; they fail if that metadata is absent.
The earlier macOS 15.7.9 / iOS 26.2 attempt compiled successfully but produced no
app trace before its launch deadline and remains unqualified. It is not a CallKit
behavior measurement. App-entry markers, launcher PIDs and bounded container-trace
recovery now help distinguish startup failure from console attachment failure.

`python3 discovery/check_environment.py` runs offline corruption controls at the
shipping identity seam, including profile/OS confusion, changed OS/compiler
builds, missing source files, and unavailable or ambiguous runtime selection.

Normal microphone probes wait for CallKit's audio activation callback before
constructing an audio engine. The explicit `PROBE_MODE=audio` experiment can
inspect inactive input separately; it is not part of the normal CI gate.
Failure receipts preserve launcher state before cleanup and last probe progress;
recovered container traces and app-scoped system logs remain diagnostic only.

The provider comparator derives per-action deadline bands from `timeoutIn` in
all eight committed iOS 27.0 provider-routing traces. It uses the largest device
sample for each action, permits 2 seconds of delegate scheduling delay below it,
and allows 0.1 seconds above it for probe rounding. These tolerances are chosen
qualification policy. Pooling matters: the `single` answer callback was sampled
with 58.9 seconds remaining, while other device cases recorded 60 seconds.
Missing, invalid or inconsistent reference samples fail the check.

The CLI's Hold & Accept, End & Accept and Decline compositions come from the
successful `device-system-ui/2026-10-20-iphone13-ui10-app.jsonl` phases. Each CLI
receipt must bind to one journal transaction and ordered delegate actions with
the device's action kinds, active/waiting call roles and hold value. The earlier
`ui7` attempt timed out and is rejected as an oracle. `call-waiting.jsonl` measures
app requests and is not the system-UI D5 oracle.

In `inv`, cleanup iterates `observer.calls`: the measured B-call then A-call order
is incidental collection order. The check requires the device's complete call
and provider inventory and preserves each run's submitted cleanup request order;
it does not claim a stable observer iteration order. Generation checks enforce
runtime lifecycle policy without a device reference, and label their output so.

`python3 discovery/check_oracles.py -v` replays the committed evidence and runs
negative controls for these expectations without booting a simulator. `run.sh`
runs these controls before allocating build files or a simulator.

`run.sh` also builds the measured `lck.swift` source and runs its four scenarios
under the runtime: `basic`, `cx-after`, `lck-after` and `two-managers`. Its only
source transformation is the asserted single `exit(0)` to `return`, allowing the
supervisor to terminate the app and bind the complete trace, engine journal and
receipt. `CKSIM_ONLY=lck` runs all four journeys in one run-owned simulator and
exits after LCK conformance. `CKSIM_ONLY=lck-basic` (or `lck-cx-after`,
`lck-lck-after`, `lck-two-managers`) selects one diagnostic journey.

`lck_conformance.py <capture-directory> [--case <scenario>]` requires the process
receipt and R5 loaded-image/package identity checks. It compares ordered action
receivers and values, app action identities, per-manager state sequences,
observer states, labeled snapshots, main callbacks, measured action deadlines,
audio ownership and mute-echo inventory against the four iPhone traces. UUIDs
are bound to request/report journey roles; cross-manager callback interleaving
is not treated as a platform guarantee. `check_lck_conformance.py -v` runs offline
device replays and tamper controls before simulator allocation.

LCK acceptance ends at each scenario's final journey snapshot. R3 startup and
teardown lifecycle callback inventory remains deferred; post-snapshot
`didBegin`/`didReset` callbacks are reported separately. Other late events fail.
This does not claim full raw-trace parity. The measured CX tap exposes only its
receiver and action kind, and has no tone/pause handlers, so its omissions do not
prove absence of those underlying actions. LCK-to-CX action UUID mapping is also
unmeasured; the journal is bound to the process and build, while LCK request UUIDs
are checked against LCK delegate deliveries directly.

The normal incoming journey's idle callback must precede its successful report
log, as on the device. The `basic` remote incoming report and callback share a
millisecond with reversed logging order; that report's ordering remains
unqualified while its state projection is checked. Source-derived LCK bands
currently center on the measured 30-second samples, with R7's explicit scheduling
and rounding tolerances. A native runtime acceptance run remains required before
calling this prepared LCK integration qualified.
