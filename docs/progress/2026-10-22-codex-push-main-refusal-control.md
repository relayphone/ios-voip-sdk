# Push main-thread refusal host control

**Measured:** PR #37 SDK run [39852006987](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39852006987), on head `372fe4525e25b8aa007c921ec53695253daf5def` and tested merge `0b115080485a063bdedac43c9cb549943cf5282b`, stopped before the app build. The `main-wait-refused` host control observed the production refusal diagnostic and passed its false-return assertion, then failed its 50 ms elapsed upper bound. The exact duration and cause were not retained. This does not establish a blocking SDK defect.

**Proposed acceptance:** require the existing host control to reject a 120-second settlement wait on main. The unchanged 60-second subprocess guard detects accidental entry into the semaphore wait; the completion watchdog does not acknowledge settlement. The false-return, diagnostic, completion-once and receiver-release checks remain. The fixture no longer asserts a scheduler-dependent refusal latency.

**Measured source checks:** Python AST parsing, exact fixture replacement, unchanged guard/assertion checks and byte comparison of all 29 tracked `Sources/` files passed against main `addd1bf4a2d1abf90133fa6e6224f71f5271d5d4`. Independent standards and specification source reviews were clear. [The source-only receipt](../verification/2026-10-22-push-main-refusal-control/source-only.json) binds the changed checker, unchanged production code, failed run and artifact.

**Pending:** actual PR CI must compile and run the checker. No compiler, host binary, simulator, device, audio or CI ran locally for this change. The earlier PR #37 SDK result remains RED. Shipping SDK code, native PushKit acceptance and future main-thread stall acceptance are unchanged; no performance bound is claimed.
