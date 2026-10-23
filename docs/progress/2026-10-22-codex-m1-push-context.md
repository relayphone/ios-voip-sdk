# M1 simulator async push context

Status: proposed native fix, measured host/compiler controls. This is simulator
journal correlation; it is not evidence of device PushKit reporting acceptance.

Measured red: the three M1 cases at source `83e396b` each recorded a nonempty
`push.received.pushID`, an empty `report.incoming.pushID`, then the original
`push.completed.pushID`. The supervisors succeeded. The preserved
[identifier-only red receipt](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-m1-push-context/red-correlation.json)
binds the original journal and supervisor digests; the private original capture
was not changed.

The proposed fix captures the runtime's thread-local push identifier before the
PushKit callback returns, carries it in simulator-only Swift task-local storage,
and associates it with the UUID immediately before the actual LCK report. The
runtime consumes that association on its serial state queue. Matching push
completion clears unused associations. The existing synchronous thread-local
path remains available when there is no association. An unexpected overlapping
association for the same UUID stays unbound until all matching pushes complete;
it cannot fall back to an unrelated thread-local identifier.

Integration requires `SimulatorSupport.associateIncomingReport(id)` immediately
before the actual `ConversationManager.reportNewIncomingConversation` call for
every new and duplicate push attempt, and serializes attempts for the same UUID.
The client change is a separate commit with one shared queued report site.
The helpers require an already-active runtime and never activate or prepare one.
This change does not alter R3 lifecycle or provider policy.

Measured controls are recorded in [host.json](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-m1-push-context/host.json):

- The test compiles the exact production task-local and association types with
  Swift 6 and warnings as errors. It covers suspension, child-task inheritance,
  unrelated and detached tasks, 32 overlapping UUIDs, once-only consumption,
  matching cleanup, UUID reuse, and persistent refusal of ambiguous overlap.
- Existing push payload/policy controls pass.
- The Swift package builds for the simulator through its real module boundaries
  with two jobs.
- A device-target shared-source binary linked and contained no runtime/context
  symbols. Its evidence wrapper correctly refused dirty-source attestation, so
  this is a compiler check, not an accepted native receipt. Root will produce the
  clean-source receipt after integration. No device was used.

Independent specification and standards reviews found no actionable issues in
the three Swift files and focused control. Their limits are recorded in the host
receipt.

Native acceptance is pending: after the client integration, rerun the unchanged
strict M1 gate and require every actual push report to carry its matching push
identifier. Preserve the pre-fix red capture and compare bound evidence. No native
run, simulator operation, device operation, or APNs activity was performed for
this scoped change.

## Report-scope lifetime followup

Proposed invariant hardening: public LCK may reject an incoming report before
calling the runtime's underlying CX hook. No new native failure was measured for
this case. A queued report could otherwise finish before the parent PushKit task
runs its completion, leaving unused context present when the next attempt starts.

`SimulatorSupport.finishIncomingReport(id)` now removes only the current task's
matching UUID and push identifier. The client places it in a `defer` immediately
after association, around its actual LCK report call. Push completion remains
additional cleanup. Unrelated UUIDs, a successor's identifier, and sticky
ambiguous state remain protected.

[report-scope-host.json](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-m1-push-context/report-scope-host.json)
binds the extended exact-production controls, including early rejection before
hook consumption, stale finish after a successor association, and the same push
identifier associated with another UUID. Independent specification and standards
reviews found no actionable issues. No new native run or device operation was
performed; the integrated native gate remains required.
