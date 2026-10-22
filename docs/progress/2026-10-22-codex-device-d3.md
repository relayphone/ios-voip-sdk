# Device D3 — required cold reporting

**Measured:** the instrumented shared SDK at source
`e2de09c90c34085c2eb27e1d279640ef75346944` received a real sandbox push on
iOS 27.0 (24A5355q) after controlled readiness-process termination and verified
absence. Its new process received metadata `mustReport=true`, successfully
reported the incoming conversation through LCK, and invoked PushKit completion.
Source/input/executable, run/launch/PID, delivery and conversation identities
remain bound across those observations.

The process survived the selected 30-second post-completion observation window.
The operator measured 62.299819416 seconds; independent review establishes a
conservative 49.916574833-second lower bound from sequential command durations
alone. The SDK projected ringing, ended and empty state. Two end actions bracket
the fixture cleanup mark; their causes are not inferred.

The [public D3 evidence](../verification/2026-10-22-sdk-device-d3/README.md)
contains a [receipt](../verification/2026-10-22-sdk-device-d3/receipt.json) and
[allowlisted trace excerpt](../verification/2026-10-22-sdk-device-d3/trace-excerpt.jsonl).
Raw evidence remains private and hash-bound rather than published as a replay
bundle. Independent review matched 209 non-secret manifest digests and 86
non-secret streams; token and secret-metadata bytes were not accessed. All 45
operator commands exited zero, one sandbox send occurred, and temporary secret
paths were confirmed absent. The operator was private one-off tooling; no CI
gate or SDK API was added for this measurement.

This answers D3 for this source-bound run through observed process survival,
not a direct acknowledgement of the system's reporting check. The fixture's
synchronous MainActor JSON/`fsync` work remains on the measured path. No
production latency baseline or cross-OS guarantee is claimed.

The earlier generic-caller Focus3 failure and initial CLI-ordering failure with
zero sends remain separate preparation evidence; there is no causal comparison
about `phoneNumber` or Focus. D1 awaits physical locked answer/timing. D2
readiness failed with zero pushes and supplies no active-call metadata result.
The proposed fixture budgets are not Apple deadlines. Media transport and
audio-engine health are outside D3; R3 remains deferred.

The later [Claude steering](2026-10-22-claude-steering.md) requires a dedicated PushKit queue,
report-entry ordering and a completion watchdog before further SDK milestones
merge. This earlier successful observation does not qualify those corrections;
locked and unlocked cold-launch measurements must be repeated at their final source.
