# WebRTC headers

Declarations for the few WebRTC classes this module calls, exposed to Swift as the private
`VoIPConversationsWebRTC` module.

The pod doesn't depend on a WebRTC pod. These headers let the Swift code compile, and because the
pod is a static framework, the class references resolve when the app links against whichever
WebRTC build it ships: `@livekit/react-native-webrtc`, upstream `react-native-webrtc`, Fishjam,
etc. All of them vend these classes under the same names. With `mediaAdapter: "none"`, the module
doesn't reference them and the app needn't link WebRTC.

Keep these in sync with the upstream headers when adding calls. WebRTC declarations are under
WebRTC's BSD license (https://webrtc.googlesource.com/src/+/main/LICENSE).
