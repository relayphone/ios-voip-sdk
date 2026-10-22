# LCK post-end unmute: narrow runtime correction

**Measured red:** source `2e6afe6` completed all four local LCK launches with successful supervisor receipts. `cx-after`, `lck-after` and `two-managers` conformed. `basic` failed `LCK timeout inventory differs`. Its fulfilled system unmute timed out 5.201 seconds after delivery, 460 ms before the final journey snapshot and provider invalidation. The compact [red evidence](../verification/2026-10-22-runtime-lck/post-end-unmute-red/diagnosis.json) preserves the receipt, raw trace, journal, manifest and hashes. The full package remains in the ignored original capture.

This is inside the existing measured journey, not R3 lifecycle behavior. The engine intentionally retained fulfilled CallKit post-end unmute actions and applied its 5.2-second timeout to LCK too. The genuine iPhone LCK trace has no timeout through 5.542 seconds after that fulfilled action. `lck-after` ended and invalidated its manager about 1.5 seconds after the echo, so it did not expose the timer. Removing only the unexpected timeout row in memory makes all ten basic actions and seven snapshots conform; that diagnostic does not change the captured evidence or acceptance result.

**Proposed policy, grounded in the public API:** [fulfill()](https://developer.apple.com/documentation/livecommunicationkit/conversationaction/fulfill()) reports success; [State.complete](https://developer.apple.com/documentation/livecommunicationkit/conversationaction/state-swift.enum) represents successful completion. The local SDK declares those APIs and the default 30-second action deadline. Successful terminal settlement supports removing the artificial CallKit timeout for an already fulfilled LCK echo. The device measurement establishes absence only within its 5.542-second observation window; it does not measure a later expiry or infinite absence.

The runtime now classifies a provider delegate using its owning public framework image, with the exact `/LiveCommunicationKit.framework/LiveCommunicationKit` suffix. It uses no private delegate class name or selector. The API kind is journaled and captured when each pending action is delivered. The `ios-27.0` profile explicitly retains `callkit: timeout` and selects `livecommunicationkit: complete` for fulfilled post-end unmute only. Removing that pending entry makes its queued expiry inert. Failed actions and arbitrary missing-call paths are unchanged; no other deadline, lifecycle or routing policy changes.

**Measured preparation:** the arm64 runtime package compiles. Five host checks compile the exact production classifier with synthetic image fixtures and the exact production typed policy decoder. They reject nil, application/name lookalikes and a wrong framework-directory suffix, while preserving CallKit's configured timeout policy. These are synthetic host controls, not genuine LCK proof. Fourteen LCK offline tests pass, including mutations that remove, change or unbind provider API classification. The [host receipt](../verification/2026-10-22-runtime-lck/post-end-policy-host.json) binds the compiled source excerpts. The unchanged four-case native acceptance will also require the genuine framework/provider API inventory; its action, deadline, timeout, state, audio and receipt gates remain strict.

## Fresh local acceptance

**Measured green:** clean committed source `f106e733ae39b1ccf2c8d220decfc93b11a062e1` completed one fresh arm64 iOS 27.0 simulator run with all four strict supervisor receipts and conformance results passing. The runtime package is version 0.1.1 with `sourceDirty=false`; Xcode 27.1 build 27A9275 compiled it against simulator iOS 27.0 build 24A434. The profile remains the committed iPhone iOS 27.0 reference, rather than a claim of identical OS builds.

| Case | Actions | Snapshots | Genuine provider API inventory |
| --- | --- | --- | --- |
| basic | 10 | 7 | LCK |
| cx-after | 7 | 6 | LCK, CallKit |
| lck-after | 10 | 6 | CallKit, LCK |
| two-managers | 4 | 4 | LCK, LCK |

Basic's fulfilled unmute has no timeout through its final snapshot at 5.654 seconds, or `done` at 6.719 seconds afterward. Its original ten actions, seven snapshots, state, observer, audio, deadline and ordering checks pass. The [compact green evidence](../verification/2026-10-22-runtime-lck/native-green-f106e73/receipt-binding.json) binds raw traces, journals, receipts, manifest, build/profile metadata and conformance results. Full runtime bytes remain in the ignored original capture.

The runtime SHA256 is `85723b38de653c0946f8acc03fca1a281cf3d877f9274ed206d1ddb343dc1cce`; the profile SHA256 is `a5c2931c42886773ab3070b521e46dfb9dcbacf6761e8759139ed9d5c59d5d4d`. Source-input SHA256 is `b9f175a215226182a65c660cf8cb9c29708ef19b2259e9ebedafec9d0e09bb1b`.

The runner shut down/deleted only owned simulator `7CD99BA1-4BDB-4145-BDA2-3F970A3AE244`. An independent bounded query returned zero in 0.150 seconds with no matching device. Its simulator directory and temporary build directory were absent; the [cleanup record](../verification/2026-10-22-runtime-lck/native-green-f106e73/cleanup-confirmation.json) confirms this separately from the scenario results.

**Pending:** hosted CI on the integrated source. Preserved CallKit timeout behavior still needs the existing full CI conformance suite on this source; the four-case run does not make a new native CallKit timeout measurement. R3 and arbitrary unfulfilled LCK action expiry remain outside this change. Independent spec and standards review reported no actionable findings in the narrow implementation.
