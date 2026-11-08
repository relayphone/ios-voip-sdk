# WebRTC headers

Declarations for the few WebRTC classes this module calls, exposed to Swift as the private
`VoIPConversationsWebRTC` module.

The pod doesn't depend on a WebRTC pod. These protocols declare the selectors the Swift code
calls, without referencing a WebRTC class symbol at link time. `WebRTCClass` resolves each class
at runtime, trying the `LK` prefix first and then the unprefixed name. The inline helpers send
Objective-C messages to the resolved class without requiring it to adopt these private protocols.

`@livekit/react-native-webrtc` 144.0.0 uses WebRTC-SDK 144.7559.01 with unprefixed classes;
144.2.0 uses LiveKitWebRTC 144.7559.15 with `LKRTCAudioSession` and
`LKRTCAudioSessionConfiguration`. If a required class is absent, media preparation throws and
the SDK reports its existing media failure. With `mediaAdapter: "none"`, the module doesn't
reference these protocols and the app needn't link WebRTC.

Keep these in sync with the upstream headers when adding calls. WebRTC declarations are under
WebRTC's BSD license (https://webrtc.googlesource.com/src/+/main/LICENSE).
