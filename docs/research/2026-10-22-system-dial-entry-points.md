# System dial entry points: M3

## Verified public APIs

Apple's [default calling app guide](https://developer.apple.com/documentation/callkit/preparing-your-app-to-be-the-default-calling-app)
requires the calling-app entitlement, a `voip` background mode and CallKit or
LiveCommunicationKit. It describes `tel:` delivery for a user-selected default
calling app on iOS/iPadOS 18.2 and later. The
[entitlement is a Boolean](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.calling-app).
Registering a custom `tel` scheme is not part of this implementation.

Apple documents [INStartCallIntent](https://developer.apple.com/documentation/intents/instartcallintent)
as a public intent delivered through `NSUserActivity.interaction`. Its contacts
or call-back record identify the recipient; its
[call capability](https://developer.apple.com/documentation/intents/instartcallintent/callcapability)
indicates audio or video. The installed SDK's public `INStartCallIntent.h`,
`INCallRecord.h`, `INPerson.h` and `INPersonHandle.h` declarations were checked,
and the adapter typechecks at an iOS 17.4 deployment target. Host controls
construct genuine public intent/person/record objects and exercise decoding.
This does not measure delivery by Siri or system Recents. A host that resolves
Siri requests in an extension remains responsible for that resolution; the SDK
consumes the resulting start-call request.

UIKit exposes cold [scene connection options](https://developer.apple.com/documentation/uikit/uiscene/connectionoptions),
warm [scene URL contexts](https://developer.apple.com/documentation/uikit/uiscenedelegate/scene(_:openurlcontexts:)),
and [continued user activities](https://developer.apple.com/documentation/uikit/uiscenedelegate/scene(_:continue:)).
`VoIPSystemEntryPoints` exposes forwarding helpers for custom application/scene
delegates, including every URL context and activity in a cold connection.

## Expo 55 and 58 lifecycle boundary

The public `ExpoAppDelegateSubscriber` and `UIApplicationDelegate` callbacks are
the same in [Expo 55](https://github.com/expo/expo/blob/0cf0c5a69371bf46b796226ab69a20a77a344e91/packages/expo-modules-core/ios/AppDelegates/ExpoAppDelegateSubscriber.swift#L7-L50)
and [Expo 58.0.17](https://github.com/expo/expo/blob/a248d78e3b9260e6f39b320ed25ae65e90acff7d/packages/expo-modules-core/ios/AppDelegates/ExpoAppDelegateSubscriber.swift#L7-L50).
The module uses those public callbacks and its existing subscriber registration.
Neither inspected version provides an `ExpoSceneDelegateSubscriber` API.

Expo 58's [ExpoAppSceneDelegate](https://github.com/expo/expo/blob/a248d78e3b9260e6f39b320ed25ae65e90acff7d/packages/expo/ios/Expo/ExpoAppSceneDelegate.swift#L33-L135)
forwards every cold URL context and user activity after starting React Native,
as well as warm scene callbacks. Its
[SceneEventForwarder](https://github.com/expo/expo/blob/a248d78e3b9260e6f39b320ed25ae65e90acff7d/packages/expo/ios/Expo/SceneEventForwarder.swift#L9-L64)
passes them into the app-delegate subscriber chain on main. Native cold
start-call activities are therefore handled without relying on JS initial-URL
hydration, which only represents the first URL/browsing-web activity.

Expo 55 has the public application callbacks but not that scene forwarder.
Custom scene-based hosts must forward their own cold/warm scene callbacks to
`VoIPSystemEntryPoints`. Expo's [official scene migration guidance](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md)
documents scenes by default in SDK 58 and an opt-in in SDK 57.0.23+, not a
supported SDK 55 scene backport. API compatibility is distinct from qualifying
an Expo 55 app's lifecycle on a newer iOS runtime.

## Proposed integration and measured controls

The process-owned, Foundation-only `DialRequestRouter` retains requests until a
consumer attaches. A new Expo module lifetime retires the previous dial
consumer. Only the newest lifetime can attach; stale generations and teardown
cannot reclaim or remove a newer consumer. Registration identity is stored
before synchronous replay so reentrant teardown leaves undelivered work queued.
No conversation manager or provider is created by dial routing.

JavaScript signals readiness only when its first actual `dialRequest` listener
attaches, after installing the local callback. Its earlier native transport
subscription is insufficient. Removing the final listener detaches the native
consumer. The wire event remains the RFC's `dialRequest` with only `handle` and
`video`; routing presents a request and never starts a call automatically.

Measured host controls cover URI decoding/rejection, public audio/video and
redial intent data, ambiguity rejection, cold FIFO replay, reload ownership,
reentrant detach, native bridge readiness and the actual public JS listener
handshake. Entitlement/config controls execute real Expo mods. Native routing,
Settings selection and `tel:` opening the example are not yet measured; they
remain M3 acceptance work. No simulator/device build, launch or dependency
download occurred during this preparation.

The current Swift core, embedded runtime and Expo sources also typecheck
together at an iOS 17.4 simulator deployment target against actual Expo 58
framework interfaces. The check uses the successful Xcode Clang import flags,
including the React modulemaps, with caches redirected to temporary owned
storage. An earlier standalone invocation omitted that import setup and failed
in the third-party umbrella; it did not reveal an SDK source error. The
[host receipt](../verification/2026-10-22-sdk-m3-host/checks.json) binds current
source hashes, dependency interface hashes and each final command result.
