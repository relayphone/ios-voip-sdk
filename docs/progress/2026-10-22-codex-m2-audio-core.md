# M2 audio core preparation — 2026-10-22

Status: implementation and host/compiler evidence. M2 native acceptance is pending;
this does not claim LiveKit media flow or repair of a device audio-service fault.

## Implementation

The core has no Expo, React Native, WebRTC or LiveKit dependency. The native
`MediaAdapter` protocol is isolated to MainActor and exposes asynchronous
`prepare`, `didActivate(AVAudioSession)` and `didDeactivate(AVAudioSession)` methods,
plus a nonblocking `setSystemAudioAuthorization(Bool)` value update.
An operation queue orders preparation and genuine callbacks without awaiting a
backend from the watchdog. Native adapters must move blocking engine work to
their own serial worker. Completion is neither activation nor engine-running proof.

Register the selected adapter once with
`ConversationClient.registerMediaAdapter(_:activationPolicy:)` before creating
the singleton. `NoMediaAdapter` is the explicit events-only choice; an unregistered
native caller retains an events-only fallback and receives a diagnostic. The Expo
plugin's selected adapter registration is separate work.

`Integrations/LiveKit/LiveKitMediaAdapter.swift` is a concrete typed convenience
binding for native Swift apps, manually included in an app target already using
LiveKit. It is outside both core and Expo source globs; the root manifest gains
no dependency or product. Its private actor uses the existing Swift AudioManager,
with only value arguments crossing actors. The setup README requires preparation
before any room connection. This does not change the RFC API or add JS activation.

One process-wide activation episode covers all LCK `.joined` conversations.
`.joining` is excluded because its signaling handler may still be pending.
An actual activation cancels the episode; hold/end removes demand; a later resume
starts a fresh episode. A second conversation cannot extend an existing deadline.
Missing and failed events are process-wide signals. Failure reports `.failed`
directly to LCK for still-joined affected conversations, independent of JS handlers.
Reset invalidates timers and gates the adapter with `prepare`; it does not invent
an audio deactivation callback. Only real delegate callbacks reach the activation
and deactivation adapter methods.
Authorization is updated synchronously before queueing real callbacks and on reset.
Workers consult that latest authorization before enabling media, so a queued old
activation released after deactivation/reset cannot enable an obsolete window.
This does not preempt engine work already executing.

**Proposed timing:** 10 seconds to `audioActivationMissing`, then one recovery and
5 seconds to `audioActivationFailed` plus clean end. Both intervals are configurable,
finite and positive. Reference-device answer-to-activation measurements have not
yet set these defaults. Scheduling uses monotonic uptime. Final termination does
not await recovery completion, and stale generations cannot affect a later call.

Recovery reapplies `.playAndRecord`/`.voiceChat` (plus Bluetooth HFP on iOS) using
the public AVAudioSession API on a detached worker. It never calls `setActive`,
recreates a manager/provider or fabricates activation. This is best effort:
[Apple's stale-session workaround](https://developer.apple.com/forums/thread/837211)
uses `CXProvider.setConfiguration`; LCK exposes immutable configuration instead.
Swift task cancellation cannot preempt a blocked native API. The controller's
deadline stays independent, but native work completion has no hard-time guarantee.

Routes expose observed input ports plus the current output and the speaker
override, using AVAudioSession raw port type names and opaque input/output IDs.
No unavailable Bluetooth/AirPlay output is invented. Selection requires genuine
activation and a currently known input; the speaker uses the public override API.
Route revisions follow actual snapshots, and an absent current route encodes `null`.
watchOS keeps the protocol/coordinator/models; preferred-input selection is iOS-only.

## Measured checks

- `bash Tests/AudioCore/run.sh`: 21 host groups pass under Swift 6 with warnings as
  errors. Coverage includes suspended recovery, canceled-timer delivery, generation
  changes, multicall/hold/resume, observer reentrancy, ordered adapter operations,
  route projection/selection/errors and explicit-null encoding.
- `bash Tests/AudioCore/run_livekit.sh`: the actual optional Swift adapter body and
  protocol pass host checks with framework/backend facades. Only outer platform
  guards change in temporary copies. Suspended preparation followed by real
  activate/deactivate or reset stays gated; healthy authorization permits media.
- Temporary-copy negative controls reject stale timer handling, recovery blocking
  termination, unordered adapter work, omitted `current: null`, unstable revisions
  and inactive route selection. Temporary copies were removed.
  Removing the optional adapter's authorization guard also rejects at the intended
  stale-enable assertion.
- Existing `Tests/VoIPSDK/run.sh` and `run_push.sh` pass.
- New production audio files typecheck with Swift 6 warnings as errors for iOS
  17.4 using iPhoneOS 27.1 SDK and watchOS 10.4 using WatchOS 27.0 SDK. The complete
  core plus client wiring also typechecks for iOS 17.4 with its public Objective-C
  platform header. These are compiler checks, not linked-app or runtime evidence.
- The optional LiveKit source's actor boundary typechecks against the real
  MediaAdapter protocol plus a temporary exact-surface facade. This detects source
  isolation errors, and does not claim actual LiveKit binary/API qualification.

Remaining acceptance: actual selected adapters and route bridge/plugin wiring,
LiveKit activation/pause/resume/end journeys, and the runtime's `staleAudio` fault
ending cleanly with one recovery. No simulator/device, native app build, dependency
installation or upstream action was performed for this preparation.
