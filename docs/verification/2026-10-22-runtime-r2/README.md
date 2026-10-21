# R2 ABI guard evidence

**Measured:** `red-baseline/` completed against the unchanged v0.1 interposition on an iOS 27.0 simulator. A concrete `CXXPCProvider` incoming-report override bypassed the active runtime. The probe recorded the genuine sentinel and failed its incoming, snapshot and transaction assertions. This is the earlier incoming-only probe revision.

**Measured:** `primary-8x13/` passed eight scenarios with 13 checks each: concrete operational overrides, shadow refusal, a missing method lookup, a throwing KVC setter, and four ignored snapshot setters. These receipts were captured **before the final action-superclass forwarding change**. They do not qualify that final change. Receipt hashes bind the raw console traces; manifests and build metadata identify their binaries and runtime source inputs.

**Measured:** `compile-checks.json` and `shipping-build-info.json` record the final candidate's arm64 and x86_64 build. The shipping image excludes both compile-test-only fault controls. Compiler IR checks confirm retained returns for all five initializer hooks, matching Objective-C initializer ownership in the [Clang ARC specification](https://clang.llvm.org/docs/AutomaticReferenceCounting.html).

**Measured:** `green-final-8x18/` passes the frozen final candidate: eight cases with 18 checks each (144 total). Genuine preload references and an untracked, three-level action hierarchy exercise original fulfillment, failure, deadline and dated-fulfillment forwarding. All bound receipts completed normally; the owned simulator was shut down and deleted. The candidate source-input digest matches `compile-checks.json`.

**Pending CI:** the existing full discovery push lane must pass before merge, because it uses genuine shadow forwarding. No device or LCK acceptance is implied by the local ABI run.

Run final acceptance from the repository root:

```sh
OUT=/tmp/callkit-r2-fresh bash discovery/run_abi.sh
```

Replay the final saved acceptance:

```sh
python3 discovery/abi_conformance.py docs/verification/2026-10-22-runtime-r2/green-final-8x18
```

The runner owns and deletes its throwaway simulator. `discovery/abi_conformance.py` checks saved final receipts, identities, exact check labels and diagnostic expectations; live runs additionally compare the built binary bytes with the manifest. The earlier probe revisions in this directory intentionally predate its final 18-check contract. No device behavior, R3 teardown callback behavior, or LCK conformance is claimed here.
