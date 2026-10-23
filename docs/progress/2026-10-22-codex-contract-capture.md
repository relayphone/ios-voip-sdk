# Contract journal capture

**Measured original failure:** [SDK run 39761951380](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39761951380), attempt 1 at `b44c35a`, exited 142 after all nine scenario supervisors reached successful terminal markers. The final contract journal, final source snapshot, manifest and aggregate results were absent. Successful supervisors are not aggregate acceptance. Artifact `12421102013`, ZIP SHA-256 `f810f3a62a8905be406ac16b20f795bac7d97a4cc31253f3ab21a546bd7c2571`, preserves that incomplete run.

The next bounded operation in the source is the repeated contract-app data-container query. This identifies a capture boundary; it does not establish why CoreSimulator stopped responding. Shutdown and deletion returned zero, with no independent hosted absence proof.

**Proposed correction:** install the contract app once, query its data container after the first successful case, and reuse that path for subsequent relaunches of the same installation. Keep the original timeout on that first query and refuse an empty or missing directory. Journal copying, per-case PID/run checks, owned process termination and simulator cleanup remain required. A missing or stale journal still fails qualification.

**Measured host preparation:** shell syntax and diff checks pass; [the small receipt](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-contract-capture/host-checks.json) binds the script bytes and command results. Native qualification of the changed runner is pending CI. No local simulator or app was operated for this correction, and the original failed run was not retried or reconstructed.
