# A0.1 / A1: bounded PushKit report entry

**Proposed implementation; native acceptance pending.** This acceptance concerns
PushKit callback/report ordering and completion liveness. It does not qualify
physical-device cold launch or replace the earlier device measurements.

The registry now delivers on its own serial queue. The receiver decodes the
untyped dictionary synchronously there, then creates one detached reporting Task.
That Task enters the SDK's MainActor, registers typed metadata before any report
suspension, and directly awaits LCK. A new UUID has no serializer Task; same-UUID
attempts await their actual predecessor using continuations. Foreground duplicate
and per-delivery TaskLocal correlation behavior remain intact.

The native delegate waits off main for actual report settlement, for at most two
seconds. An independent four-second watchdog invokes system completion once if
reporting has not settled. Completion never waits for main or for the blocked
registry queue. Settlement and watchdog races cannot complete twice; a watchdog
does not acknowledge report settlement. Late reporting remains possible, and
explicit diagnostics retain the timeout. No SDK path aborts the process.

## Why settlement acknowledges entry

The local iOS 27.1 LCK interface offers only an async throwing incoming-report
method, with no public entry callback or Objective-C completion overload. A flag
set before `await` would not establish framework entry. The implementation waits
for the actual awaited invocation to return or throw, which conservatively proves
entry. When that bounded wait expires, it reports failure rather than inventing
an entry acknowledgement. A blocked main executor can still defeat the reporting
budget; the dedicated callback queue prevents a self-deadlock, not arbitrary
application stalls. An underlying hung LCK Task may outlive the watchdog;
this does not promise an absolute host-failure deadline.

The detached reporting Task still makes one SDK MainActor hop before registering
metadata and invoking LCK. Removing the serializer's extra Task does not bypass
that state-owner hop. React Native startup or another main-thread stall can
therefore consume the two-second callback wait before framework entry. A bounded
failure diagnostic is not an entry guarantee in that case. The simulator's strict
rule will reject the missing entry; this implementation needs corrected-head
locked and unlocked cold-launch measurements before beta. Removing the remaining
hop would require changing ownership of the incoming metadata/UUID ledger; a
transport-only shortcut could let LCK callbacks precede metadata registration.

Apple's [February 2025 DTS workaround](https://developer.apple.com/forums/thread/774958)
uses a completion-handler PushKit delegate, a Task, and an arbitrary short sleep.
The newer [WWDC26 metadata example](https://developer.apple.com/videos/play/wwdc2026/226/?time=562)
uses the metadata async delegate. Neither supplies a public entry acknowledgement
or establishes that every current async delegate is broken. The [registry API](https://developer.apple.com/documentation/pushkit/pkpushregistry/init%28queue%3A%29)
recommends serial delivery; [metadata reporting requirements](https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate/pushregistry%28_%3Adidreceiveincomingvoippushwith%3Ametadata%3Awithcompletionhandler%3A%29)
remain conditional on `mustReport`.

The two/four-second bounds are **proposed SDK liveness policy**, not measured OS
deadlines. They leave completion independent of a stalled report while keeping a
callback queue wait finite. Their suitability for locked/unlocked physical cold
launch remains to be measured before beta. Core state stays on MainActor; typed
metadata registration occurs in the one reporting Task while the native callback
is still waiting, avoiding synchronous main dispatch.

## Simulator enforcement and controls

The runtime observes its real provider incoming-report hook. At callback return
and completion it records `reportEntered` and `mustReport`; a required missing
report emits `diagnostic.pushReportingViolation` with severity `error`. It does
not accept an SDK pre-await marker, another push's report, or a late report as
proof that an earlier callback returned correctly. Optional omission remains
valid. Completed boundary pairs release the per-delivery obligation state.

**Measured host/compiler controls:** existing projection/queue and push-policy
controls pass; the exact receiver/report methods and obligation model pass host
behavioral checks; journal tamper controls reject missing, reordered,
substituted or incorrectly typed evidence. Sixteen ticket/API controls and the
existing 26 platform controls pass, including receiver lifetime, double/late
finish, watchdog races and independent completion. Full Swift 6 source
typechecking passes for simulator and device; the scene-capable native probe
also typechecks. These are host/compiler results, not native PushKit acceptance.

The focused native probe contains SDK-required and same-UUID duplicate paths,
plus generic missing/deferred/optional delegates. These are deliberate in-app
simulator injections for A0/A1, not A5 push-initiated process launch or APNs. The normal strict validator
must accept only conforming required/optional delivery. The missing and deferred
controls must be rejected; reaching a terminal probe marker does not waive a
reporting violation. Built source, executable, resource, console, runtime journal,
owned simulator/environment and cleanup evidence will be retained for review.

No RFC 0001 public API deviation was identified. The native receiver/ticket seam
is implementation plumbing. No device action, APNs key or real push is part of
this acceptance.

## Acceptance continuation

**Measured:** three local native preflights ended before installation or launch:
a launchctl environment-query timeout, refusal of public `simctl getenv`'s
key-specific missing response, and a nonterminal boot/data-migration timeout.
Their exact receipts and cleanup limitations are indexed in
[`docs/verification/2026-10-22-push-entry/`](../verification/2026-10-22-push-entry/README.md).
Every created simulator was deleted and independently absent; the final additional
simulator was never booted. No native case result is claimed.

**Proposed:** the focused five-case runner now uses the existing M0 CI simulator,
probe build and supervisor. It binds the source, installed product, real PID/run,
profile/session, console and native journal. Normal-rule validation remains red
for missing/deferred delegates; a separate negative-fixture validator requires
complete, correctly correlated evidence. Host controls cover three normal shapes,
two deliberate negative shapes, 46 journal tamper cases and complete-capture
missing/empty/substituted evidence. Native acceptance awaits CI; physical cold
launch remains for the coordinated iPhone measurement.

Claude's outstanding device handoff is to use the corrected source head, not the
earlier D3 success: test an APNs cold launch both unlocked and locked, retain native
callback/report entry/return/completion timestamps, and then measure lock-screen
answer to genuine `didActivate`. The current simulator fixture neither measures
that delivery nor qualifies the main-actor stall case.
