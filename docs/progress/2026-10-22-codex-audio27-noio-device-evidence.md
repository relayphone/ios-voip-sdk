# iOS 27 physical no-I/O audio transport handoff

**Measured:** the [44-row ordinary-session no-I/O packet](../research/callkit-simulator-probe/audio-session-lifecycle/2026-10-22-iphone13-ios27-noio/README.md) completes sync activate/deactivate and async activate/deactivate on iPhone 13 / iOS 27.0. Its acceptance target is the bounded physical notification-transport evidence, not A0.3 or M2 completion.

- All four actual API results succeeded off main on the SDK audio queue. All nine I/O snapshots show no engine, zero rendered frames, and zero callbacks.
- Raw notifications, the unchanged Objective-C decoder, and an actual Swift `SystemAudioSession.onLifecycle` consumer each received 2 active and 4 inactive events, with matching ordered typed scalars. All raw inactive contexts were actual `AVAudioSessionDeactivationContext`, source `1`; no resumption recommendation occurred.
- The same frozen signed executable and 14 shared source/project files were used without rebuilding or re-signing. Only the existing no-I/O launch mode was selected. The packet binds source manifest `b769cdfa…`, executable `d7c1f3d9…`, trace `42496556…`, and private provenance/cleanup hashes.
- Exact executable/PID stop, two subsequent PID-absence readbacks, owned-app removal, and independent bundle absence passed inside the unchanged 90-second native cap. No app or process remains from this run.
- **The earlier silent-engine fixture remains RED, cause UNKNOWN.** Its sources, trace, receipt, validator, and incomplete fourth operation are unchanged. This successful no-I/O mode does not qualify rendering, LCK/system interruption, recommendation delivery, PushKit, provider media, or a main-thread stall threshold. Its maximum sampled main heartbeat gap was 54.562 ms.

**Proposed integration:** bind this complete ordinary physical transport packet into the A4 acceptance gate alongside the preserved earlier RED packet, and qualify the SDK's distinct native LCK authorization lifecycle separately. Genuine interruption/recommendation measurements remain open. No native build, device run, or audio operation was performed while packaging this evidence.
