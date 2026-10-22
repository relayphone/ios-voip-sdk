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

`summarize.py <directory>` replays saved `.jsonl` or captured `.log` traces. Live runs additionally require process receipts and trace version 2 with `--require-receipts`. `simulator-discovery-v2` describes the measured baseline; historical version 1 captures remain immutable replay inputs. It is not a cross-version Apple guarantee. Microphone frames can have zero peak on hosted runners: processing frames proves neither audible playback nor independent two-way media. The synthetic lane proves delivery/reporting, not APNs wake-up or watchdog behavior.

The SDK header controls compilation of the newer PushKit callback and metadata subclass; older SDKs use the legacy callback. Both require hosted execution evidence before a toolchain is called supported. No provider/APNs credentials are needed for this harness.

`COMPILER_DEVELOPER_DIR` selects a compiler/SDK separately from the active Xcode
that hosts CoreSimulator. CI tests Xcode 26.6 and 26.3 compiler paths on macOS 26.
The earlier macOS 15.7.9 / iOS 26.2 attempt compiled successfully but produced no
app trace before its launch deadline and remains unqualified. It is not a CallKit
behavior measurement. App-entry markers, launcher PIDs and bounded container-trace
recovery now help distinguish startup failure from console attachment failure.

Normal microphone probes wait for CallKit's audio activation callback before
constructing an audio engine. The explicit `PROBE_MODE=audio` experiment can
inspect inactive input separately; it is not part of the normal CI gate.
Failure receipts preserve launcher state before cleanup and last probe progress;
recovered container traces and app-scoped system logs remain diagnostic only.
