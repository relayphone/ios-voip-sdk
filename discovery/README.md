# Simulator CallKit discovery

`run.sh` runs an instrumented CallKit probe in a run-owned simulator three ways: genuine CallKit, the same app with the injected runtime spike, and a synthetic VoIP push with a shadow report. This is the executable baseline for runtime PR #2, not the packaged Swift implementation.

Run `python3 discovery/check_harness.py` for adversarial CLI checks against the saved hosted traces and real subprocess completion/failure/timeout paths. Run `bash discovery/run.sh` on a Mac for native execution. It prints a fresh evidence directory; an explicit `OUT` must not already exist. Temporary build files and the owned simulator are removed on exit, while evidence remains.

The launcher watches the probe's `done` event, then terminates only that run's app. The SwiftUI probe otherwise remains alive. A missing terminal marker, failed app termination, unexpected launcher status, or incomplete evidence fails the run. Genuine simulator teardown/unknown-call errors are expected control behavior; runtime outcomes, state, answer expiry, and audio ownership are asserted separately.

`summarize.py <directory>` replays saved `.jsonl` or captured `.log` traces. Live runs additionally require process receipts with `--require-receipts`. `simulator-discovery-v1` describes the measured baseline; it is not a cross-version Apple guarantee. Microphone frames can have zero peak on hosted runners: processing frames proves neither audible playback nor independent two-way media. The synthetic lane proves delivery/reporting, not APNs wake-up or watchdog behavior.

The SDK header controls compilation of the newer PushKit callback and metadata subclass; older SDKs use the legacy callback. Both require hosted execution evidence before a toolchain is called supported. No provider/APNs credentials are needed for this harness.
