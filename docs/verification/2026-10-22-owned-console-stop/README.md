# Owned console-launcher stop

**Measured primary source:** local `xcrun simctl help launch` documents that signals received by a console launcher are forwarded to its app. [Source excerpt and help digest](primary-source.json).

**Measured hosted red:** [run 39698551274](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39698551274/job/119561832953) completed all 23 `refused-queues` behavior checks, but the normal simulator terminate command timed out after 20 seconds and its cleanup retry timed out after 10 seconds. The [failed receipt and bound trace](traditional-red/) are failure evidence, not acceptance.

**Proposed implementation:** `--console-launcher-stop` sends SIGTERM only to the known launcher PID after `done`. It requires bounded launcher exit/output drain and a final single positive app PID matching the probe. Any signal, output or identity failure stays failed and invokes the existing terminate command for cleanup. Unflagged callers retain command termination.

Signal receipts record `terminationMethod: console-launcher-signal`, `terminationSignal: 15` and `terminationSignalDelivered: true`. They do not claim a terminate-command exit code. The shared `successful_stop` helper rejects incomplete, contradictory or mismatched receipts. Both runtime runners opt in; the SDK runner must use the same flag and helper when this change enters its branch.

**Measured offline:** all 93 harness checks pass, including 36 new subprocess/receipt controls and all 57 existing checks. Ignored signals, malformed identity, early exit and continued descendant output stay failed and invoke fallback cleanup. Independent specification and standards reviews are clean. [Outputs](offline-checks.json) and [source binding](offline-verification.json).

**Native qualification pending:** only a single owned-simulator `refused-queues` case is authorized for the first measurement.
