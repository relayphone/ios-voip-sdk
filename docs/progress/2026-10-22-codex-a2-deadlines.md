# A2: settle before the platform timeout

**Implemented preparation; native qualification pending.** This change follows
Claude's October 22 steering §A.2 on base `3e4b11a`. Its single acceptance target
is application policy settlement before the platform action timeout. It does not
claim that the pending A0 release blockers or other steering items are resolved.

**Proposed policy:** the initial safety margin is 1.5 seconds. On enqueue, the
coordinator retains the platform `timeoutDate` privately and copies the action
with an effective deadline 1.5 seconds earlier. Both `PendingAction.deadline` and
the handler context expose this same effective value; the existing Expo relay
serializes it to JS without adding another timer or subtracting again. Late
handler attachment cannot extend it. No-handler policy and cancellation of
running work occur at that effective boundary. An action received inside the
margin settles immediately; execution already past platform expiry cannot
accept, even if the platform's state callback has not arrived yet.

The scheduler remains cooperative. A blocked actor cannot be preempted; after
such a stall the SDK fails instead of accepting past platform expiry. The
margin does not promise that arbitrary blocked application code can settle on
time. A4's call-time audio preparation must retain the pending entry and timer
across its await, then recheck effective expiry, generation and cancellation
before fulfillment.

**Measured reference:** the four committed LCK traces are hash-bound from the
profile. `basic` and `lck-after` each contain ten `lck.perform` samples;
`two-managers` contains four. All 24 advertise 30 seconds. `cx-after` has no LCK
delivery: the later CX provider receives the actions, so it is routing evidence,
not another measurement of a 30-second LCK deadline.

**Proposed runtime expiry policy:** LCK-owned providers advertise and expire at
30 seconds. These traces measure `timeoutDate`; they do not independently measure
an unfulfilled LCK timeout callback. The existing classifier identifies the
delegate's owning public framework image. A direct CX provider, including the
later owner in `cx-after`, retains CallKit's 60/600/5-second advertised deadlines
and separate 59.58/600/5.2-second expiry values. No new private class-name probe
or interposition is added.

The journal adds `action.deadline`, containing actual CX action ID, provider,
API kind, absolute deadline milliseconds, and selected deadline/expiry seconds.
It does not claim a measured mapping between LCK and CX action UUIDs. The native
unhandled-accept contract has exactly one answer transaction; its strengthened
gate binds that actual CX action, checks the effective margin and refuses
settlement or immediate native connection at/after its runtime deadline.
Synthetic gate fixtures are controls, not native acceptance. A8 can separately
change the later SDK connected projection to require an explicit transport
report while retaining the action-settlement timing proof.

**Measured host/compiler preparation:** the [receipt](../verification/2026-10-22-a2-deadlines/receipt.json)
binds source bytes, checks and the initial regression outputs. The new coordinator
controls use the production clock and scheduler, with no injected clock or manual
timer firing. They cover the effective snapshot/context, accept/fail policy,
late attachment/results, cancellation, inside-margin/past-timeout arrival, and
an actor stalled past platform expiry. The pre-existing injected-clock suite
remains a separate semantic control. The production profile selector is compiled
and run on the host for LCK and all three CallKit timing categories; the actual
RuntimeEngine also typechecks with the iOS 17.4 simulator SDK target and Swift 6.
No simulator or device was created or run for this preparation. The stricter
native contract and current integrated CI must qualify the resulting source.

## Stacked A0 integration preparation

The branch now includes the reviewed A0 device Release exclusion change at
`2605d4d`, as its stacked parent. The simulator-only embedded profile is
regenerated from A2's canonical profile, so both source distributions include
the separate LCK timing. The existing profile-drift control caught the stale
embedded copy before regeneration. The new LCK duration also joins the existing
finite, positive duration validation; zero, negative and three nonfinite values
are refused by the exact production guard. The test deliberately uses a
nonfinite decoding strategy only to reach that guard: the shipping decoder
already refuses those strings earlier. The omitted-field regression failed
before the one-line guard correction.

**Measured host/compiler preparation:** the
[stack integration receipt](../verification/2026-10-22-a2-deadlines/stack-followup.json)
binds 119 source/control inputs and 13 passing checks, including the real-clock
coordinator suite, exact production profile controls, existing SDK/LCK gates,
the device exclusion host controls and an actual iOS 17.4 simulator-SDK runtime
typecheck. Inputs remained unchanged across the checks. No simulator or device
was created or run. This is preparation for native CI acceptance of the stacked
head; the parent's native qualification does not qualify A2's changed source.

## RFC deviation text for the authorized fork comment

RFC 0001 describes `ActionContext.deadline` as when the platform gives up. This
implementation exposes the effective application deadline, initially 1.5 seconds
before native `ConversationAction.timeoutDate`, in both the context and pending
snapshot. The reason is to apply `unhandledAction` and cancel pending handler work
before LCK's own timeout can win the race. The native deadline is retained for a
final late-accept guard. Handler replacement/attachment does not extend either
deadline. The public shape is unchanged, but this semantic difference must be
recorded on fork PR #10; root will post the concrete reviewed comment. No upstream
action was taken by this implementation task.
