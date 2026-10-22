# M1 integrated native red at 83e396b

**Measured red:** the combined native acceptance at source `83e396bac6b9c3465b17320cc80ba7088bf53ca4` ended with `success=false`, `missing LCK state left`. The prerequisite M0 gate checks for a `left` state between `sdk.joined` and `sdk.ended`; its capture logged `idle` and `joined` only. `sdk_m1_conformance.validate` calls that prerequisite before validating its three M1 cases, so this run supplies no strict M1 conformance pass. The failure's implementation cause is not established by this receipt.

The source-input SHA256 is `ba0b475bac39b0adc6edddca74e86c790f47a26bcb63c1de627b97fec9ffdea5`. The capture is `discovery/out/sdk-m1-red-83e396b`, run `6AE1F33A-A788-49D2-BF5A-9258A2081CEF`. The saved environment records arm64, Xcode 27.1 (27A9275), SDK 27.1 and the iOS 27.0 simulator (24A434). The manifest records no requested runtime injection. Its inherited external DYLD value is represented by a digest, rather than reproduced here.

**Measured process results:** all three M1 supervisor receipts record `success=true`, `completed=true`, app entry, terminal `done`, acknowledged console-launcher termination and launch exit zero. Their trace/journal hashes match the original files, and journal run/PID identities match their receipts. Each app logs `sdk.result.success=true`; those observations do not replace the failed acceptance gate.

| Case | App assertion rows, all passed | Logged LCK states | `done` timestamp |
| --- | --- | --- | --- |
| journey | 11 | idle, joined, paused, joined | 1.791 s |
| cold-launch | 5 | idle, joined | 0.476 s |
| unhandled-expiry | 5 | idle | 32.050 s |

The journey records join, hold, hold and end handler calls. Cold launch records a pending join before handler attachment and later join/end handler calls. Unhandled expiry records no attached handler and a later empty hook projection. All three end with hook conversation count zero. These are captured observations; deadline, ordering, projection and push-policy acceptance remains pending because M1's checker was not reached.

The saved cleanup receipt records shutdown/delete exit zero and `deleted=true` for the run-owned simulator. This draft performs no simulator operation and makes no independent device-absence claim.

The accompanying compact `receipt.json` preserves source/environment identities, aggregate observations and hashes of the original metadata, supervisor receipts, traces and journals. The raw capture and build products remain private in the ignored output directory; this draft copies no raw logs or binaries. There was no real APNs, physical-device, locked-launch, or media/audio acceptance run.

**Proposed next step:** resolve and regress the missing terminal-state observation, then rerun the unchanged combined acceptance with fresh source-bound evidence. M1 acceptance remains open until the M0 prerequisite and all three strict M1 cases pass. Product decisions and post-M1 device measurements remain with Hamza.
