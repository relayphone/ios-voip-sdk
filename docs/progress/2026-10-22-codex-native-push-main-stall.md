# Native incoming report while main is blocked

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
settlement must precede the one native completion after main resumes, and the
public SDK snapshot must contain the same incoming UUID and canonical payload.
Missing, substituted, reordered and duplicate evidence fails.

The runtime deliberately dispatches its incoming-report completion to main. The
native two-second settlement wait is therefore expected to expire during this
three-second fixture stall even if report entry succeeds. That refusal diagnostic
does not become a fabricated settlement acknowledgement. The separate actual
hook boundary is the entry oracle; the four-second completion watchdog must not
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
