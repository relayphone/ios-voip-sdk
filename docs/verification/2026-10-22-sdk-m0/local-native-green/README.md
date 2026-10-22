# M0 local native acceptance

**Measured:** source `0d46635a4c2168549092411218ad7745a9e885a1` passed the complete M0 runner on iOS 27.0, with a Release Expo 58 example and bundled JavaScript. No runtime injection was requested. The conversation rang beyond the genuine simulator teardown interval, joined, and ended. The three bootstrap cases passed, and both the linked device probe and all five SwiftPM device objects passed runtime-implementation exclusion.

`summary.json` is the runner's result. `source-before.json` and `build-receipt.json` bind the source before compilation to the exact products. `manifest.json` binds the complete capture, including executable/JavaScript/object bytes, build logs, installed product hashes, trace receipts, runtime and cleanup. All four supervisor receipts prove a successful owned-launcher signal stop and matching application PID. No fallback termination was used.

The owned simulator's shutdown and deletion succeeded. A separate inventory and filesystem check confirmed its UUID was absent after this run. Only that run-owned simulator was used.

This committed directory is a lean receipt collection. Executable/object bytes and full native build logs are retained in the task's ignored `discovery/out/sdk-m0-local-0d46635` capture. Consequently, this directory alone is **not** a complete replay input for `sdk_m0_conformance.py`; the gate was run against the complete capture and must continue to require every bound byte. Replay uses the captured source commit, because later documentation commits change HEAD. Hosted CI preserves its own complete artifact and remains a separate pending acceptance.

The manifest SHA-256 is `0c153638783ea3c2bdfcabe527a8382dbdb8ff14445497e7767cbe6caf9449f5`. The result establishes M0 packaging/bootstrap behavior, not the M1 client, PushKit delivery or media behavior.
