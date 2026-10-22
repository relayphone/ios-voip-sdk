# D3 — required cold PushKit report on the SDK

**Measured on iOS 27.0 (24A5355q), source `e2de09c`:** a real sandbox push
cold-launched the instrumented SDK fixture, delivered metadata `mustReport=true`,
and received a successful LCK incoming report followed by PushKit completion
invocation. The new process remained alive beyond the chosen 30-second window.
The operator recorded 62.299819416 seconds after observing completion; summing
subsequent sequential command durations alone independently bounds survival
below by **49.916574833 seconds**, excluding sleeps and other work.

The [receipt](receipt.json) binds the compiled inputs, executable, original raw
trace, prerequisite readiness/termination/absence evidence and private operator
capture. Its [sanitized trace excerpt](trace-excerpt.jsonl) preserves native
timestamps, sequence numbers and correlation IDs. Sequence gaps are intentional.
The private raw trace has 28 records; thirteen retained copies are exact prefixes.
This is a lean public record of audited private evidence, not a standalone replay
bundle. Device, app and signing identities, credentials, tokens and private paths
are omitted.

The controlled cold setup terminated only the verified readiness PID, proved
that PID absent, then sent once. The source-bound new launch reported one
delivery UUID and one conversation UUID through report attempt, successful result
and completion. The SDK projected ringing, then ended and empty state. All 45
operator commands exited zero. Independent review verified 209 non-secret
manifest digests and 86 non-secret command streams; it did not read or rehash the
retained token or four deleted secret streams. All five temporary secret paths
were independently confirmed absent.

The [fixture](../../../discovery/device/SDKDeviceProbe.swift),
[build-only script](../../../discovery/device/build_sdk.sh) and
[guarded SDK diagnostics](../../../Sources/VoIPSDK/SDKDeviceQADiagnostics.swift)
identify the instrumentation. Native timestamps precede serialization, but
synchronous MainActor JSON/`fsync` logging remains on the measured path. This
run supplies no production latency baseline.

Two genuine end actions were observed around the fixture cleanup mark: one
arrived 8.22225 ms before it, and another 27.136 ms after it. Both settled
successfully. The fixture mark was 60.099867125 seconds after scheduling, and
empty state followed completion by 60.147275958 seconds. These are observations
of order; neither end-action cause nor a native timeout is inferred. The fixture
budget and 30-second observation window are not Apple deadlines.

The earlier generic-caller Focus3 report failure and initial CLI-ordering failure
with zero sends remain separate private preparation evidence. They are not
combined with this successful run; no causal conclusion about `phoneNumber` or
Focus follows. Completion marks invocation, not a system reporting-check
acknowledgement. The conclusion is observed survival after required reporting
on this source and OS, not a universal guarantee or a no-report counterfactual.

[START-HERE §4.D](../../START-HERE.md) D1 still requires a physical locked answer
and timing. D2 readiness failed before any push and remains unqualified. Media
transport, audio-engine health and R3 are outside this acceptance.

The later [Claude steering](../../progress/2026-10-22-claude-steering.md) requires a dedicated PushKit queue,
report-entry ordering and a completion watchdog before further SDK milestones
merge. This earlier successful observation does not qualify those corrections;
locked and unlocked cold-launch measurements must be repeated at their final source.
