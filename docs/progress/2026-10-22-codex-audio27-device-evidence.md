# iOS 27 physical audio diagnostic handoff

**Measured:** the [ordinary-session evidence packet](../research/callkit-simulator-probe/audio-session-lifecycle/2026-10-22-iphone13-ios27/README.md) preserves the exact probe sources and a 37-row iPhone 13 / iOS 27.0 trace. This change's acceptance target is documentation and source/capture provenance only.

- Raw notifications, the unchanged C decoder, and an actual Swift `SystemAudioSession.onLifecycle` consumer agree on 2 active and 3 inactive events. Raw inactive contexts are typed `AVAudioSessionDeactivationContext`, source `1`.
- The first sync activation rendered 240672 zero-filled frames; sync deactivation succeeded and frames stayed stable. Async activation and initial engine start succeeded, but after 5013.695 ms the engine was stopped with no additional frames. The render guard failed; the fourth operation never ran. Cause is unknown.
- **Full fixture RED, unchanged.** This does not complete A0.3, M2, LCK/system interruption, async-deactivation, recommendation, PushKit, or stall acceptance.
- Exact executable/PID stop, two PID-absence readbacks, owned-app removal, and independent app absence were verified within the 90-second native cap. No app remains from the run.

The receipt binds source packet `b769cdfabed1785d6fcd4474fb29d8efcce9200c03db5c63da47e8e9942d03a8`, signed executable `d7c1f3d9c5c1a450539c2677edcf1aa443a3fa3f92928b8d69c74c4afb7eca2b`, trace `9684181eb77d61cfabd7eb382712ef119fd414adfc35711c6fe52d17e11e4f32`, and immutable private build/launch/operator/cleanup receipts. The eight copied production audio files match frozen `a212b9e` and published M2 `4dbb07c`; the complete source manifest is in the packet.

**Proposed next work for Claude:** inspect the engine-stop failure without changing this result, then choose a separate bounded measurement for the remaining fourth operation and genuine interruption/recommendation behavior. Ordinary app-owned activation is a different composition from LCK; no SDK activation-policy change follows from this capture. No additional device or native run was performed while packaging this handoff.
