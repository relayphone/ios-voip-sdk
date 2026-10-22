# R2 ABI guard evidence

**Measured:** `red-baseline/` completed against the unchanged v0.1 interposition on an iOS 27.0 simulator. A concrete `CXXPCProvider` incoming-report override bypassed the active runtime. The probe recorded the genuine sentinel and failed its incoming, snapshot and transaction assertions. This is the earlier incoming-only probe revision.

**Measured:** `primary-8x13/` passed eight scenarios with 13 checks each: concrete operational overrides, shadow refusal, a missing method lookup, a throwing KVC setter, and four ignored snapshot setters. These receipts were captured **before the final action-superclass forwarding change**. They do not qualify that final change. Receipt hashes bind the raw console traces; manifests and build metadata identify their binaries and runtime source inputs.

**Measured:** `compile-checks.json` and `shipping-build-info.json` record the final candidate's arm64 and x86_64 build. The shipping image excludes both compile-test-only fault controls. Compiler IR checks confirm retained returns for all five initializer hooks, matching Objective-C initializer ownership in the [Clang ARC specification](https://clang.llvm.org/docs/AutomaticReferenceCounting.html).

**Measured:** `green-final-8x18/` passes the frozen final candidate: eight cases with 18 checks each (144 total). Genuine preload references and an untracked, three-level action hierarchy exercise original fulfillment, failure, deadline and dated-fulfillment forwarding. All bound receipts completed normally; the owned simulator was shut down and deleted. The candidate source-input digest matches `compile-checks.json`.

**Pending CI:** the existing full discovery push lane must pass before merge, because it uses genuine shadow forwarding. No device or LCK acceptance is implied by the local ABI run.

**Measured latest candidate:** `review-red-queues/` reproduces four wrong-queue callbacks after refusal. `review-green-13-cases/` passes all 243 checks: the original eight cases plus refused custom/nil callback queues, both initializer validation-lookup faults, and both differing concrete PushKit setters. The initializer controls prove genuine constructor calls and initialized-object state after the autorelease pool drains; the PushKit controls prove each concrete setter remains intact after refusal. `review-shipping-checks.json` and `review-shipping-build-info.json` bind the same source-input digest, both shipping architectures and the absence of all three test controls. Both review axes are clean. A cleanup receipt confirms the owned simulator was deleted.

**Measured boundary experiment:** `constructor-boundary-experiment/` forces `CXProvider` allocation to return nil. Objective-C observed nil; Swift's nonoptional constructor returned and its description bridged to an empty string. This does not create a valid object or simulate structural API removal, and no allocation workaround ships. Supported Apple ABIs must expose the advertised public provider/controller constructors. A genuinely absent constructor refuses before sample allocation and receives no initializer wrapper without a genuine original; this does not qualify a hypothetical root-absent/concrete-present hierarchy.

Run current acceptance from the repository root:

```sh
OUT=/tmp/callkit-r2-fresh bash discovery/run_abi.sh
```

Replay the latest saved acceptance:

```sh
python3 discovery/abi_conformance.py docs/verification/2026-10-22-runtime-r2/review-green-13-cases
```

The runner owns and deletes its throwaway simulator. `discovery/abi_conformance.py` checks saved final receipts, identities, exact check labels and diagnostic expectations; live runs additionally compare the built binary bytes with the manifest. Earlier captures retain their historical checker contracts; the current checker requires all thirteen cases and their exact per-case labels. No device behavior, R3 teardown callback behavior, or LCK conformance is claimed here.
