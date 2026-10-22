# LiveKit Swift integration

This is an opt-in source binding for an iOS app that already depends on the
LiveKit Swift SDK. Add `LiveKitMediaAdapter.swift` to your **app target** alongside
the `VoIPSDK` and LiveKit products. It is not another package product and is not
compiled by the root package or Expo pod. The core keeps no LiveKit dependency.
The Expo `livekit` adapter instead controls the existing React Native WebRTC ADM;
do not use this file with `@livekit/react-native`.

During native startup, before any room connection or client creation:

```swift
let adapter = LiveKitMediaAdapter()
try await adapter.prepare() // establish external ownership before media can start
try ConversationClient.registerMediaAdapter(adapter)
let calls = ConversationClient.shared
```

Run setup on MainActor and retain the process's single client. SDK preparation is
idempotent and repeats the gate safely. The app still owns room/signaling, tracks,
permissions and media lifetime. Request microphone permission before publishing
audio; restoring input availability can fail if permission has not been granted.
Do not independently activate/deactivate AVAudioSession or restore LiveKit's
automatic configuration while this integration owns it. Only genuine LCK delegate
callbacks release/gate the engine; enabling availability is not proof of audio flow.
The SDK's synchronous authorization update prevents queued stale callbacks from
enabling media after deactivation/reset. Do not invoke that update yourself.

The private actor resolves and uses `AudioManager.shared` inside its own isolation;
no framework object crosses actors and no Sendable assertion is added. Its native
operation can still block: the core watchdog remains independent, and does not
promise to preempt a backend operation.

**Source-verified API target:** LiveKit Swift 2.18.0: nested
`audioSession.isAutomaticConfigurationEnabled`, throwing
`setEngineAvailability(.none/.default)`. [Official availability contract](https://github.com/livekit/client-sdk-swift/blob/2.18.0/Sources/LiveKit/Audio/Manager/AudioManager.swift#L475-L517),
[official external-session setup](https://github.com/livekit/client-sdk-swift/blob/2.18.0/Docs/audio.md#L3-L37).
This preparation has compiler/host evidence for the core; compiling this optional
file against the actual LiveKit binary and measuring its journeys remain follow-up qualification work.
