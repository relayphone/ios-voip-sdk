# Source bootstrap compile evidence

Measured locally on 2026-10-22. `compile-summary.json` records the source-file digests, compile targets, current SDK/toolchain, device object inspection, source-linked UIScene probe binary digest and standalone profile layout check. It is compile evidence only, with no simulator launch or ring/join acceptance. Swift emits ordinary support force-load markers for the empty Engine module; those are preserved separately from runtime implementation symbols. Final linked-device-app inspection remains pending.

`validator-controls.json` contains synthetic positive and corruption checks for the bootstrap receipt validator. These synthetic fixtures do not establish runtime behavior. Independent code reviews found no actionable issues. All listed build outputs were owned temporary verification outputs and have been deleted.
