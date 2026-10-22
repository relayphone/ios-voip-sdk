# A0.1 / A1: bounded PushKit report entry

**Proposed implementation; measured host regression and compiler controls; native
simulator acceptance pending CI.** This target concerns PushKit report entry and
completion liveness. It does not qualify a physical-device cold launch.

The registry delivers on its own serial queue. Its receiver decodes the untyped
payload and reserves the canonical incoming identity and metadata synchronously,
before creating a detached reporting Task. That Task invokes the existing LCK
manager through an incoming-report-only transport, commits its actual outcome and
finishes native delivery. It then schedules its incoming-result state projection. It does
not wait for React Native startup, an SDK actor hop or a previous report.

The native delegate waits off main for actual report settlement, for at most two
seconds. An independent four-second watchdog invokes system completion once if
reporting has not settled. Completion does not depend on main or the blocked
registry queue. A watchdog does not acknowledge report settlement. An underlying
hung LCK Task may outlive it; this does not promise an absolute host-failure bound.
No SDK path aborts the process.

## One incoming ledger and a narrow framework boundary

`IncomingIntake` is the sole identity, canonical payload, report-attempt and remote
end-event ledger. One lock protects synchronous value changes. Continuation
resumption and release of retained external error objects occur after unlocking.
MainActor records cache its payload and optional terminal marker; LCK membership
and state remain authoritative for conversation projection.

Every PushKit invitation receives its own real report attempt, including a
same-UUID duplicate. A foreground duplicate may await a pending public ticket.
A duplicate platform result is normalized only with evidence of prior success or
actual membership; it may await another attempt's result without holding up
native PushKit completion. Failed unreported reservations permit a real retry.
Manager reset invalidates pending generations while retaining the canonical
metadata needed to reconcile a late real framework object; it does not invent
platform objects or runtime teardown callbacks.

Reset promptly fails internal pending tickets. A caller already awaiting its
original foreground platform report still waits for that invocation before
reading the ticket; reset does not cancel the in-flight framework operation.
Foreground duplicates that joined the ticket can receive its failure promptly.

`IncomingReportTransport` retains the client's same manager. Its explicit narrow
interop assumption is that Apple's non-actor-isolated async incoming-report API
may be invoked from the PushKit reporting worker. It does not make a retroactive
`Sendable` declaration for LCK or claim general framework thread safety. All other
manager operations, action handling and public state publication stay on the SDK
actor. Simulator correlation helpers use the runtime's existing lock/serial
state boundary.

## Why settlement acknowledges entry

The local LCK interface offers only an async throwing incoming-report method,
without a public entry callback or Objective-C completion overload. A flag set
before `await` would not establish framework entry. Waiting for the actual awaited
invocation to return or throw conservatively establishes entry. If that bounded
wait expires, the SDK logs failure instead of inventing an acknowledgement.

Apple's [DTS workaround](https://developer.apple.com/forums/thread/774958) uses a
completion-handler delegate, a Task and an arbitrary short wait. The newer
[metadata example](https://developer.apple.com/videos/play/wwdc2026/226/?time=562)
uses the metadata async delegate. Neither supplies a public entry acknowledgement
or establishes that every current async delegate is broken. The
[registry API](https://developer.apple.com/documentation/pushkit/pkpushregistry/init%28queue%3A%29)
recommends serial delivery; the
[metadata reporting requirement](https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate/pushregistry%28_%3Adidreceiveincomingvoippushwith%3Ametadata%3Awithcompletionhandler%3A%29)
remains conditional on `mustReport`.

The two/four-second bounds are **proposed SDK liveness policy**, not measured OS
deadlines. Removing the SDK actor dependency does not guarantee that Apple's
implementation or the host scheduler always enters and settles within that
budget. Locked and unlocked cold launches on the corrected device build remain
required before beta.

## Runtime enforcement and acceptance

The simulator observes its real provider incoming-report hook. At native callback
return and completion it records `reportEntered` and `mustReport`; a missing
required report emits `diagnostic.pushReportingViolation` with severity `error`.
It does not accept an SDK pre-await marker, another push's report or a late report
as proof of an earlier correct return. Optional omission remains valid.

The existing M0-owned simulator runs five focused cases: `sdk-required`,
`sdk-duplicate`, `missing`, `deferred` and `optional`. These are deliberately in-app
injections, separate from A5 push-initiated process launch and APNs. Normal-rule
validation must reject missing/deferred delegates. A separate negative-fixture
validator requires their complete boundary, actual report, settlement and
correctly correlated diagnostic sequence; a terminal probe marker alone cannot
qualify them. Source/build/installed hashes, launcher/app PIDs, run/session/profile,
console and runtime journals are bound and retained. The enclosing M0 runner
records owned simulator deletion.

Unresolved overlapping same-UUID simulator associations remain deliberately
ambiguous. The runtime refuses unbound attribution instead of guessing FIFO
identities. Host tests showing an independent required report behind a hung
predecessor do not establish concurrent framework-attribution conformance.

Reset reconciliation currently arms one terminal claim for invalidated in-flight
work. It does not establish that arbitrary multiple residual objects recreated by
old same-UUID framework calls are each ended after that claim is consumed. That
requires framework evidence and per-object idempotence, rather than blind repeated
end reports. No additional teardown/re-arm behavior is claimed here.

The additive `duplicate-wrapper` native contract calls the public SDK report API
through genuine LCK twice, requires one UUID/live conversation and underlying
provider report statuses 0 then 2, and ends through the real public end action.
It tests duplicate public-result compatibility, not NSError wrapping depth or
actual PushKit delivery. The runtime/source/process binding remains mandatory.

## Evidence and remaining measurements

**Measured:** the previous receiver still depended on MainActor before framework
entry. With main blocked for three seconds, the actual native delegate wait
returned after 2.005079 seconds; its reporting dependency did not enter until
3.001280 seconds. The exact production receiver/native wait and actual delivery
ticket were compiled and executed against a host report facade. The regression
exited red with valid delivery cardinality. The new intake/receiver/transport
passed the corresponding host invariant with main state projection still blocked.
These are host results, not an LCK app or device measurement.

**Measured:** three earlier local native preflights stopped before installation or
launch. Their exact receipts and cleanup limitations are indexed in
[`docs/verification/2026-10-22-push-entry/`](../verification/2026-10-22-push-entry/README.md).
All owned simulators were deleted and independently absent; a final additional
simulator was created but never booted. No native case result is claimed from
those captures. No global launch environment was changed.

Current host controls retain synchronous decoding/reservation, optional omission,
required fallback success/failure, one-shot pending termination and callEnded
dedup. A required callEnded queues its existing-target projection immediately even if its
unrelated fallback report remains suspended. Store controls cover concurrent
reservation/settlement, retry generations, reset and reentrant error destruction.
The actual native-wait main-stall control and real SDK compiler checks remain
separate from the mandatory CI app journeys.

Claude's outstanding device handoff is to use the corrected source head, not the
earlier D3 success: measure APNs cold launches both unlocked and locked, retaining
native callback/report entry/return/completion timestamps; then measure lock-screen
answer to genuine `didActivate`. The simulator fixtures do not replace these runs.

No RFC 0001 public API deviation was identified. No device action, APNs credential
or real push is part of this change.

The source-bound red/green, 19 integrated host/compiler checks and debug/optimized
intake controls are indexed in
[`docs/verification/2026-10-22-push-entry-main-stall/`](../verification/2026-10-22-push-entry-main-stall/README.md).
The final host candidate entered its report facade at 0.000379 s and returned the
native callback at 0.000424 s while main was measured blocked for 3.006523 s.
These values are host fixture timings, not Apple framework latency.

For later A2 integration, union its `unhandled-fail` native contract case with
`guard`, `unhandled-accept` and this branch's additive `duplicate-wrapper`; retain
their separate settlement/evidence rules. Do not replace either fixture baseline
with the other branch's assumptions.

The public foreground duplicate paths refresh the SDK cache before returning a
reported result or propagating a joined result/error. The actual-report path
retains its early refresh, which can establish observed membership for duplicate
normalization. A whole-client host control with held platform observation delivery
reproduced all three old stale-cache paths and passes after this change; it is
separate from genuine framework timing evidence.
