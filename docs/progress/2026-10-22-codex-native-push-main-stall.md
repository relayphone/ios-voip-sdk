# Native incoming report while main is blocked

**Acceptance update:** the measured local iOS 27 and hosted iOS 26.5 results are now recorded in the [incoming-report handoff](2026-10-22-codex-push-entry-acceptance.md). The preparation record below preserves its original stage and evidence.

**Proposed acceptance; native result pending.** PR #28's five native entry cases
keep main responsive. Their actual LCK/provider-hook results cannot establish
whether reporting also enters while main is blocked by application startup. The
host reporting facade exercises that SDK ordering boundary but does not execute
the Apple framework.

The additional `sdk-main-stall` case uses the same source-built probe, supervisor,
owned simulator and source/build/installed/process/session/profile bindings. A
probe-only Objective-C category invokes the existing registry owner's exact
linked `deliverPayload:mustReport:completion:` body on a worker. Main first records
the stall boundary, signals that worker and synchronously sleeps for three
seconds. There is one real manager, receiver and native delivery ticket; the
fixture supplies only a payload and the controlled stall. No SDK/runtime API or
shipping behavior changes.

This is a **direct native callback-body fixture**, not `CKSimInjectPush`, an actual
PushKit delivery or APNs. It deliberately avoids the injector's own main-queue
registry bookkeeping. Fixture invocation, return and completion markers never
substitute for the actual provider `report.incoming` hook.

Acceptance requires the actual report hook after stall start and before both the
native method's return and stall end. Strict serialized journal order establishes
these causal boundaries even when fast events share a millisecond timestamp. The
observed stall must last at least 2.9 seconds. One actual successful report
settlement must precede the one native completion, and the public SDK snapshot
must contain the same incoming UUID and canonical payload. Settlement and native
completion may occur while main is stalled or after it resumes.
Missing, substituted, reordered and duplicate evidence fails.

The runtime dispatches incoming-report completion to the provider's configured
queue, falling back to main. Public LCK delegate callbacks arriving on main do
not establish its internal provider completion queue. The native two-second
settlement wait may expire during this three-second fixture stall if completion
waits for main, even when report entry succeeds. Early settlement and completion
are equally valid. The separate actual hook boundary is the entry oracle; a wait
refusal does not fabricate settlement, and the four-second watchdog must not
replace the successful settlement required by this case.

Physical locked/unlocked APNs cold launches and lock-screen answer-to-activation
measurements remain required on the corrected device head. This fixture cannot
establish physical PushKit acceptance or general LCK thread safety.

**Measured host preparation:** ten focused checks pass at input digest
`41a7deda65ca46a7262fbf6cf2d669c8ee9e7df4773fc761ed8595b46946c068`: the
new gate accepts three synthetic positives and refuses 62 malformed variants;
full-capture controls also refuse rebound missing entry and substituted payloads.
The Objective-C helper passes syntax checking, and the actual SDK plus probe
passes strict Swift 6 typechecking. The [receipt](../verification/2026-10-22-native-push-main-stall/host-preparation.json)
binds all shipping sources and the affected fixture/build/gate inputs, with no
shipping-source changes against `8077f0d`. It does not claim an app build or run.
Independent SPEC and STANDARDS reviews cleared the source and retained evidence.

The native-origin oracle correction `c19ef89` and preboot host-metadata correction
`6121c0a` were merged normally. All 40 preparation inputs remain identical; the
[merged receipt](../verification/2026-10-22-native-push-main-stall/merged-host-checks.json)
binds the three additional integration inputs and eight passing affected gate,
workflow and syntax checks at digest
`ae3c7e79ab7778d19cb24ebf23c86ea81f256caf0309d79af3a6f62942c4e9fc`.
The unchanged compiler and intake suites were not repeated. Both review axes
cleared the integration. Native CI and corrected-device acceptance remain pending.

A subsequent [synthetic oracle correction](../verification/2026-10-22-native-push-main-stall/oracle-correction.json)
removes the unmeasured private-queue assumption. The old gate rejects a valid
early-settlement fixture; the revised gate accepts it while requiring the same
strict entry/return/stall chain and the separate report/settlement/completion
chain. Four synthetic positives and 62 refusals pass, along with the full-capture
and diff checks, at input
`6108b9a7f56c543a480ca602dbacef3e3541c502c1605142bbd867abf6fbb78c`.
Only the gate and its synthetic controls change; the other 41 integration inputs,
including all shipping and probe/compiler inputs, remain identical. This records
a test-oracle correction, not a measured framework queue or native result.
