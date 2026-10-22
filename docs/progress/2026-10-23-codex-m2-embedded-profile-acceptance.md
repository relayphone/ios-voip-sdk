# M2 embedded simulator profile acceptance

**Measured source-only correction; fresh native acceptance is proposed.** The
[158afe4 M2 run](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39858008068)
built its selected LiveKit Release example and Debug contracts, then failed a
stale acceptance predicate requiring the runtime resource bundle in both apps.
The Expo SDK build uses `CKSIM_SDK_SOURCE` and embeds the canonical profile in
its simulator executable. The standalone Debug contracts use a resource fixture.

The M2 builder now records an `exampleEmbeddedProfile` proof binding the guarded
raw Swift literal, canonical source/product profile, and actual example binary.
The gate compares JSON values without boolean/number coercion and requires the
complete raw UTF-8 payload in the executable, recording its occurrence count.
It recomputes the proof from retained products and the runner recomputes it from
the installed example. Debug contracts retain their resource inventory and digest
checks. Shipping sources and profile contents are unchanged.

**Measured controls:** all 32 synthetic/mocked M2 test groups pass, including
fully rebound missing/changed payloads, proof schema/type tampering, canonical
source mismatches, and the Debug resource requirement. Python bytecode and Bash
syntax checks pass. A read-only replay of artifact `12461661067` finds the exact
2,371-byte raw payload once in the real Release example and zero times in the
Debug contracts; its typed JSON equals the 2,372-byte canonical file. All 13
retained product digests match the original build receipt.

The [source-only receipt](../verification/2026-10-23-m2-embedded-profile-acceptance/source-only.json)
binds the edited inputs, controls, retained product hashes and unchanged shipping
and physical-evidence files. No compiler, simulator, phone or audio ran for this
correction. The prior terminal failure remains a failure; its archived products
omit app bundles, so this replay makes no claim about their resource inventory.
Fresh modern/legacy M2 native journeys, installed-byte checks and owned cleanup
remain required before acceptance.
