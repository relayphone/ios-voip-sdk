# Simulator CallKit discovery

`run.sh` runs an instrumented CallKit probe in a run-owned simulator three ways: genuine CallKit, the same app with the injected runtime spike, and a synthetic VoIP push with a shadow report. This is the executable baseline for runtime PR #2, not the packaged Swift implementation.

Run `python3 discovery/check_harness.py` for adversarial CLI checks against the saved hosted traces and real subprocess completion/failure/timeout paths. Run `bash discovery/run.sh` on a Mac for native execution. It prints a fresh evidence directory; an explicit `OUT` must not already exist. Temporary build files and the owned simulator are removed on exit, while evidence remains.

The launcher watches the probe's `done` event, then terminates only that run's app. The SwiftUI probe otherwise remains alive. A missing terminal marker, failed app termination, unexpected launcher status, or incomplete evidence fails the run. Genuine simulator teardown/unknown-call errors are expected control behavior; runtime outcomes, state, answer expiry, and audio ownership are asserted separately.

`summarize.py <directory>` replays saved `.jsonl` or captured `.log` traces. Live runs additionally require process receipts and trace version 2 with `--require-receipts`. Shipping runtime qualification also binds the manifest's exact simulator runtime ID, OS version/build and selected compiler version/build to saved `runtimes.json` and `compiler-version.txt`. The summary reports these separately from the `ios-27.0` behavior profile. Missing or inconsistent environment metadata fails qualification. Historical fixtures remain immutable replay inputs and are labelled `historical-replay`; replay success does not qualify the current runtime or an OS version. Microphone frames can have zero peak on hosted runners: processing frames proves neither audible playback nor independent two-way media. The synthetic lane proves delivery/reporting, not APNs wake-up or watchdog behavior.

The SDK header controls compilation of the newer PushKit callback and metadata subclass; older SDKs use the legacy callback. Both require hosted execution evidence before a toolchain is called supported. No provider/APNs credentials are needed for this harness.

`COMPILER_DEVELOPER_DIR` selects a compiler/SDK separately from the active Xcode
that hosts CoreSimulator. CI tests Xcode 26.6 and 26.3 compiler paths on macOS 26.
**Measured:** [hosted run 39680771297](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39680771297)
used iOS **26.5 (23F77)** with the `ios-27.0` behavior profile. Its Xcode 26.6
lane used Xcode **26.6 (17F113)** on macOS **26.6.2 (25G83)**. The compiler
matrix does not establish additional simulator OS coverage. This run does not
qualify iOS 27.0 or LiveCommunicationKit; LCK acceptance is the next work item
in [START-HERE §4.B](../docs/START-HERE.md#b-make-lck-the-runtimes-acceptance-target).
The [R8 evidence](../docs/verification/2026-10-22-runtime-r8/) preserves its
environment capture. Future runs select the newest available iOS simulator
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
