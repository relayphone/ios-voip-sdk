# iOS VoIP SDK for Exact (experimental)

This package runs [Exact](https://github.com/expo/exact)'s `@exact/calls` on iOS through this SDK,
so an Exact app's calls use LiveCommunicationKit and PushKit in place of Exact's CallKit
implementation. The app's code doesn't change: it keeps using `startCall`, `reportIncomingCall`,
`calls` and the call events.

It is experimental. It follows Exact's main branch, which has no stable API, and it isn't released
with the SDK.

## Requirements

- iOS 26 or later: set `host.ios.minimumOS` to `"26.0"` in `app.json`.
- Exact built from the `voip/integration` branch of
  [relayphone/exact](https://github.com/relayphone/exact/tree/voip/integration). It adds what this
  package needs and Exact's main branch doesn't have yet: a way to add a call the platform started
  to the call list, a start in a launch with no scene, and a package's signing entitlements.
- A development provisioning profile for your bundle ID with the Push Notifications capability.

## Install

```sh
npm pack ./exact
```

Add the `.tgz` to the app's `dependencies` beside `@exact/calls`, with `"device.calls"` in its grants:

```json
"dependencies": {
  "@exact/calls": "file:<exact checkout>/packages/calls",
  "@relayphone/exact-voip": "file:relayphone-exact-voip-0.0.0.tgz"
}
```

Exact picks this package on iOS because the app depends on it, and keeps its own implementation on
other platforms.

## VoIP pushes

The package registers for VoIP pushes as the app launches, including a launch with no window, and
reports each push's call before the app's code runs. A push uses the SDK's
[default format](../Sources/VoIPCore/VoIPPush+DefaultFormat.swift). Read the device token for your
server from Swift in an app module:

```swift
import ExactPkg_calls

for await token in VoIPCallsModule.pushTokens() { /* send it to your server */ }
```

## What it doesn't do yet

- Exact refuses the `device.calls` grant in production builds until it has a call transport, so this
  package works in development builds only.
- It carries no audio. An app needs its own media transport, such as WebRTC or LiveKit.
