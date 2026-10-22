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

## Original CI failure and zero-tolerance follow-up

**Measured red:** SDK CI `39761541639`, attempt 1, built the original A2
`1fd33b4` source and failed `unhandled-expiry: journey failed`. Its
[classification](../verification/2026-10-22-a2-deadlines/original-ci-failure.json)
binds the artifact, exact gate, SDK inputs, process and trace. M0 and the
pod-built Release device exclusion passed before that failure. The effective
pending deadline was 28.5 seconds; the first cleared-pending snapshot appeared
about the native 30-second boundary, followed by a pending system End. The
conversation remained ringing when the old fixture failed. The original trace
does not timestamp policy firing or LCK settlement entry/return, so it cannot
locate that delay. Existing device LCK probes always fulfill; they do not measure
failed joins. The original red and its receipts remain unchanged.

**Proposed correction:** the critical scheduler now requests
`Task.sleep(..., tolerance: .zero)`. Swift's
[clock documentation](https://docs.swift.org/main/documentation/swift/continuousclock/clock-implementations/)
allows wake-up coalescing when tolerance is unspecified. Leaving that tolerance
unspecified is incompatible with reserving a 1.5-second margin; this source
correction does not establish coalescing as the original failure's cause or
guarantee timely execution on a blocked actor.

The Debug simulator native contract adds `unhandled-fail` beside
`unhandled-accept`. It observes policy firing, settlement entry/return and the
coordinator's pending publication, then separately binds actual SDK snapshots
and the runtime's failed action settlement. The internal diagnostic sink and
all its call sites compile only under `DEBUG && targetEnvironment(simulator)`.
It passes scalar observations; the fixture owns synchronous trace I/O, whose
overhead is included in the measured Debug timeline. A publication marker alone
only means the coordinator's `didChange` callback returned.

RFC 0001's no-handler policy fails the action; it does not promise to end its
conversation. The new fail fixture therefore records whether the conversation
remains, and explicitly labels any fixture cleanup report. It does not infer
automatic teardown. The original Expo M1 empty-state oracle remains unchanged.
The changed head requires fresh native qualification; no retry of the original
source qualifies this correction.

**Measured host/compiler preparation:** the
[zero-tolerance receipt](../verification/2026-10-22-a2-deadlines/zero-tolerance-followup.json)
binds 120 unchanged source/control inputs across four focused final checks.
The [pre-review preparation](../verification/2026-10-22-a2-deadlines/zero-tolerance-pre-review.json)
retains its 18 passing checks. Review caught a fixture cleanup race: pending
removal alone did not prove asynchronous native failure had been forwarded.
The corrected fixture waits through the recorded SDK platform expiry, then
re-samples conversation presence before cleanup. Actual native failure must
still precede both SDK and runtime expiry, so cleanup cannot make it pass.
Only the fixture and two gate/control files changed; affected checks were rerun
and 15 unaffected preparation checks are retained.

The native contract's 17 synthetic test methods cover policy/identity/timing,
missing diagnostics, actual snapshot publication, explicit cleanup, and delayed
forwarding without an invented forwarding timeout; they are not native
measurements. Four real SDK compiler configurations confirm the diagnostic sink
exists only in Debug simulator output. The corrected complete Debug fixture
typechecks against the installed Apple SDK. No iOS application was launched.

The original runtime CI `39761541757`, attempt 1, was green in both **Xcode 26.3
and Xcode 26.6** compiler lanes, each using the **iOS 26.5 simulator** with the
**ios-27.0 behavior profile**. It is separate from the SDK red and qualifies its
original source only. Main, including the probe answer-checkpoint correction,
was merged forward locally without rewriting the original A2 history.

## Generic M1 projection controls

**Measured synthetic gap and correction:** the
[generic-margin receipt](../verification/2026-10-22-a2-deadlines/generic-margin-followup.json)
preserves the old gate accepting both coherent 30-second and 28.5-second public
deadlines. The generic fixture now publishes 28.5 seconds and separately binds
the native 30-second deadline to the unique answer transaction/provider. Both
coordinated restorations to a public 30-second deadline are rejected. Eleven
host control methods pass; these are checker controls, not native execution.
The device sampling bands, dedicated native deadline contracts, and existing
generic failure/liveness/empty-expiry predicates are unchanged. The generic
cross-layer margin allowance does not establish LCK/CX UUID equality.

**Measured pre-app CI red:** corrected head `dfc81fc` reached its runner
environment query in SDK CI `39772309614`, attempt 1, then
`xcodebuild -version` exceeded the existing 30-second budget. The
[bound classification](../verification/2026-10-22-a2-deadlines/ci-dfc81fc-pre-app-failure.json)
records tree-equal tested merge `13ed8dc`, matching source/build receipts and
zero app journey traces. App installation and the final manifest were absent,
so this run qualifies no native journey. It is distinct from the original
`1fd33b4` actual expiry failure. No retry was requested.

## Combined PushKit and runner preparation

The [integrated preparation receipt](../verification/2026-10-22-a2-deadlines/integrated-preparation.json)
binds the local normal merges of A1, the reviewed host-metadata ordering change,
and the native-origin correction. All four native contract cases survive:
`guard`, `unhandled-accept`, `unhandled-fail`, and `duplicate-wrapper`. Native
transaction origin is `application`; SDK handler origin remains `app`.

**Measured host/compiler preparation:** the full 20-command SDK offline/typecheck
preparation passed before the host-metadata merge. Protected SDK/probe/gate
bytes remained unchanged, and four affected runner/origin checks passed after
the later merges. The host control verifies five metadata commands run once before
simulator creation with their existing 30-second budgets, and that the final
environment preserves those fields while adding four simulator fields. The
container lookup remains cached across the four contract cases. These mocked
host controls establish ordering and field preservation, not the cause of the
previous timeout. Both review axes cleared the conflict resolutions.

**Measured prior-source runtime CI:** corrected `dfc81fc` runtime run
`39772309722`, attempt 1, passed both Xcode 26.3 and 26.6 compiler lanes on the
iOS 26.5 simulator with the ios-27.0 profile. Ten offline gate replays per lane
matched their CI JSON results; the Xcode 26.6 loader-repair receipt also passed
its 16 checks. Live CLI operations were not re-executed locally. These greens
qualify `dfc81fc`, not the newly integrated source, whose native CI is pending.

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
