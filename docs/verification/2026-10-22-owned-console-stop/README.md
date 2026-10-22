# Owned console-launcher stop

**Measured primary source:** local `xcrun simctl help launch` documents that signals received by a console launcher are forwarded to its app. [Source excerpt and help digest](primary-source.json).

**Measured hosted red:** [run 39698551274](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39698551274/job/119561832953) completed all 23 `refused-queues` behavior checks, but the normal simulator terminate command timed out after 20 seconds and its cleanup retry timed out after 10 seconds. The [failed receipt and bound trace](traditional-red/) are failure evidence, not acceptance.

**Implemented:** `--console-launcher-stop` sends SIGTERM only to the known launcher PID after `done`. It requires bounded launcher exit/output drain and a final single positive app PID matching the probe. Any signal, output or identity failure stays failed and invokes the existing terminate command for cleanup. Unflagged callers retain command termination.

Signal receipts record `terminationMethod: console-launcher-signal`, `terminationSignal: 15` and `terminationSignalDelivered: true`. They do not claim a terminate-command exit code. The shared `successful_stop` helper rejects incomplete, contradictory or mismatched receipts. Both runtime runners opt in; the SDK runner must use the same flag and helper when this change enters its branch.

**Measured offline:** all 93 harness checks pass, including 36 new subprocess/receipt controls and all 57 existing checks. Ignored signals, malformed identity, early exit and continued descendant output stay failed and invoke fallback cleanup. Independent specification and standards reviews are clean. [Outputs](offline-checks.json) and [source binding](offline-verification.json).

**Measured native green:** the single `refused-queues` case passes all 23 checks on the installed iOS 27.0 simulator runtime from clean source `087025f90729bcbda0ef6dbcc81dd365fbe9f830`. The signal receipt completes in 3.805 seconds: owned launcher PID 99296 receives SIGTERM, its final app acknowledgement matches probe PID 99318, launcher exit is 0, and no terminate-command/fallback result is claimed. [Native receipt, trace and manifest](native-green/) and [verification](native-verification.json) bind source and bytes. The owned simulator was independently confirmed deleted.

**Proposed hosted acceptance:** rerun the complete ABI and discovery suites on both hosted compiler lanes. This local single-case result does not claim iOS 26.5 CI qualification.
