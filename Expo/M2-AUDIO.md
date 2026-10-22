# M2 Expo audio integration

**Measured local native acceptance:** the selected existing React Native LiveKit
engine passed active, hold, resume and end, and the stale-audio fault ended cleanly.
[Source-bound M2 receipts](../docs/verification/2026-10-22-sdk-m2/native-green-82c1b8f/README.md)
bind actual availability/running observations to the built and installed product.
Current-head hosted CI and physical-device media remain pending. The host checks
below separately establish bridge behavior and packaging.

Configure one adapter in the iOS-only plugin:

```json
{
  "plugins": [["ios-voip-sdk", { "mediaAdapter": "livekit" }]]
}
```

`webrtc` is the default. `none` keeps native audio events, routes and the watchdog
without linking a media binding. The plugin writes the same selection to
`Info.plist` (`VoIPSDK.mediaAdapter`) and `Podfile.properties.json`
(`ios-voip-sdk.mediaAdapter`). Run prebuild and regenerate pods when changing it;
editing only Info.plist cannot switch compiled backends. The podspec includes
exactly one backend source directory. A mismatched launch setting logs a diagnostic
while required PushKit reporting still starts. The Swift package has no media
dependency; Expo's optional bindings live outside its `Sources/` target.

The plugin always adds `voip` to `UIBackgroundModes`, and adds `audio` for
`webrtc`/`livekit`, preserving all existing modes without duplicating its additions.
Apple requires the audio background mode to continue play-and-record audio when
the app backgrounds or the screen locks. This setting permits background media;
it does not grant microphone permission or activate a session. Native Swift apps
must configure their own `UIBackgroundModes` with `voip` and `audio`, provide an
`NSMicrophoneUsageDescription`, and obtain microphone permission before capture.
Apps selecting `none` still need `audio` if their own integration plays or records
background media. [Apple playAndRecord requirements](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord),
[Apple recording requirements](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record).

`ExpoMediaSupport.startFromBundle()` registers the selected adapter before calling
the core launch owner. An Expo app with a custom early launch hook must use this
wrapper before directly obtaining the SDK client. Adapter preparation configures
external ownership and gates media. Genuine LCK callbacks provide authorization;
JavaScript has no audio activation method. Potentially blocking engine calls run
on a serial Objective-C worker. A separate, nonblocking authorization value lets
queued work reject a stale enable after deactivation/reset. Native calls already
in progress cannot be preempted; completion is not proof of system activation or
successful audio capture/playback.

## Standard WebRTC

`webrtc` adds no WebRTC pod or framework dependency. The app must already link an
implementation of the public `RTCAudioSession` contract: `sharedInstance`,
`useManualAudio`, `isAudioEnabled`, `audioSessionDidActivate:` and
`audioSessionDidDeactivate:`. The declaration-only protocol and typed public
Objective-C class lookup permit a missing implementation to produce a diagnostic
instead of a missing-symbol launch failure. They do not guarantee every fork's
ABI. Preparation sets manual audio and disables media; each genuine callback is
forwarded once, with availability checked against current authorization. There is
no synthetic activation for recovery and no claimed engine-running getter.
[Public WebRTC contract](https://github.com/jitsi/webrtc/blob/9edb2100fc29f847b5d01def716a979daf397901/sdk/objc/components/audio/RTCAudioSession.h),
[upstream static declaration approach](https://github.com/mfairley/expo-callkit-telecom/blob/27030ae/ios/WebRTCHeaders/README.md).

## React Native LiveKit

The selected pod depends on `livekit-react-native-webrtc >=150.1.0,<151.0.0`.
Use the app's existing `@livekit/react-native-webrtc` and compatible
`@livekit/react-native` packages; do not also link standard `react-native-webrtc`
or a second WebRTC fork. Before creating media or using SDK hooks/commands:

```ts
import { registerGlobals } from '@livekit/react-native';

registerGlobals({ autoConfigureAudioSession: false });
```

Do not call an independent `AudioSession.startAudioSession()` for these calls.
The SDK core owns category/mode configuration and LCK owns session activation.
[LiveKit registration switch](https://github.com/livekit/client-sdk-react-native/blob/f72a42f6a788877afe3bf41e10c63d10d21b0db1/src/index.tsx),
[independent session API](https://github.com/livekit/client-sdk-react-native/blob/f72a42f6a788877afe3bf41e10c63d10d21b0db1/ios/LiveKitReactNativeModule.swift).

The private RN helper resolves the current registry's `WebRTCModule` and binds its
existing `audioDeviceModule`; it never creates a peer-connection factory, a
`WebRTCModule`, or Swift LiveKit `AudioManager`. It gates the existing ADM's engine
availability through typed native APIs and preserves its observer/mixer chain.
This is the React Native counterpart of the RFC's LiveKit engine adapter.
[Existing ADM ownership](https://github.com/livekit/react-native-webrtc/blob/9401729b0dab00f96b1c8c44bf2a804c373ab73d/ios/RCTWebRTC/WebRTCModule.m),
[native availability API](https://github.com/livekit/react-native-webrtc/blob/9401729b0dab00f96b1c8c44bf2a804c373ab73d/ios/RCTWebRTC/WebRTCModule%2BRTCAudioDeviceModule.m).

One private `TurboModuleRegistry.get('VoIPSDKMediaRegistry')` asks React Native to
instantiate this helper. It exports no controls. Registry injection precedes the
instance `initialize` callback; lookup is enqueued separately so module creation
cannot block the audio worker, main thread, or watchdog. Invalidation never waits
on lookup/media work. Owner generations discard stale lookup results and prevent
an old RN instance from disabling a newer engine. Late attachment only reapplies
the latest genuine system authorization. It emits no fabricated `audioActivated`.
[Public RN registry seam](https://github.com/facebook/react-native/blob/v0.83.10/packages/react-native/React/Base/RCTBridgeModule.h).

**Source-verified compatibility limit:** this public seam exists in Expo 55's RN
0.83 and the inspected Expo 58/RN 0.88 sources. The plain `RCTBridgeModule` helper
uses stock legacy NativeModule interop in the New Architecture. Builds that
explicitly remove that interop are unsupported; an absent helper logs a clear
integration diagnostic. No Expo 55 native compilation or lifecycle/media
qualification is claimed here.

## Routes and events

```ts
const { routes, current } = useAudioRoutes();
await selectAudioRoute(routes[0].id);
```

Routes have `{ id, name, type }`; `current` is that route object or `null`.
Types retain AVAudioSession port names. Available inputs and current outputs are
projected by the core, including the speaker override; the API does not invent a
list of every possible output. Selection requires genuine active system audio
and a known selectable route. Rejected selection remains a rejected promise.
The revisioned private envelope prevents a delayed initial read overwriting a
newer route event and keeps public hook snapshots stable and immutable.

Audio events, including `audioActivationMissing` and `audioActivationFailed`, are
process-wide. Their `conversationId` is optional; read current conversations to
identify affected calls. The core watchdog provides one finite recovery attempt
and clean end without granting audio authorization. A backend error or permission
flag is not evidence that the system activated audio.

## Host verification

**Measured preparation:** TypeScript build plus twelve offline controls pass;
`python3 discovery/check_expo_bridge.py` passes nine Swift 6 host groups against
the production relay/models, including explicit null route loss and observer
cleanup. `node discovery/check_expo_plugin.cjs` passes 24 real Expo 58 config-mod
groups. `python3 discovery/check_expo_media_config.py` evaluates byte-identical
podspec inputs through installed CocoaPods, checking default and all three source
and dependency selections plus invalid selection rejection. It performs no pod
installation. The actual Swift queued adapter and production Objective-C header
typecheck for iOS 17.4 with Swift 6 and warnings as errors.

`python3 discovery/check_expo_media.py` exercises the production Objective-C
workers with explicit host-only framework facades. Those controls are not native
media qualification. Integrated native evidence belongs in the M2 acceptance
capture and milestone handoff.
