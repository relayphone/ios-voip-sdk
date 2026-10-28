# Optional Expo LiveKit audio

Select `mediaAdapter: "livekit"` in the plugin and regenerate the iOS project/pods.
The native adapter uses the existing React Native WebRTCModule/ADM and observer;
it creates no factory and exports no JavaScript activation control. Its selected
pod pins `@livekit/react-native-webrtc` 150.1.0 (LiveKitWebRTC 150.7871.03).

Before any room/capture, call `registerGlobals({ autoConfigureAudioSession: false })`
from `@livekit/react-native`. Disabling it later cannot undo an existing activation.
Create media demand inside the SDK's prepared start/join handler after checking
cancellation. Native preparation disables automatic session configuration/hooks
and gates availability before the handler. After acceptance, category/mode are
set immediately before fulfillment on the common audio queue. Only genuine
LCK authorization permits the engine. Registry readiness waits are bounded by the
real action's cancellation/deadline. The SDK never calls `setActive`.

The example's `SDK_EXAMPLE_MEDIA_ADAPTER=livekit` variant pins React Native LiveKit
3.1.0, its WebRTC fork 150.1.0 and livekit-client 2.23.0; `none` and standard WebRTC
variants disable this fork's native autolinking. Set the variant for both prebuild
and pod installation. The local-demand fixture requests no Room/server connection.
Facade controls are host policy checks. The dedicated iOS 27.0 runtime job with compiler SDK 27.1 builds the
pinned Release consumer, inspects its Release iphoneos app for CallKit exclusion,
and requires the real ADM to run after genuine LCK join/resume and stop on
hold/end while local demand remains. Both fixed cases are required: healthy uses
a fresh process with no fault; stale waits for the matching fault ACK before
pushing. Its readiness receipt and native marker carry the ACK nonce and host
receipt time; conformance requires that time between app entry and readiness.
The stale case then requires the default 10 s activation and 5 s recovery
watchdogs to deliver scoped native and public JavaScript events and end cleanly.
The fixture measures local demand, availability and running state, not Room
signaling or media quality. Both journeys and Release inspection must pass on the exact change before
qualification; API/facade compilation alone does not satisfy it.

For the prepared iPhone 13 session, this simulator fixture supplies the local
media lifecycle baseline: demand stays live while native authorization starts,
holds, resumes and stops the existing engine. It adds no device measurement path
for natural subsecond cold answer, locked-screen controls, two-way Room/RTP or
Settings/Siri dispatch. Those require real push/system UI delivery and, for
Room/RTP, a connected room and peer. No device result is claimed here.
