# ios-voip-sdk

A VoIP calling SDK for iOS. It keeps the state of every call, presents calls with
**LiveCommunicationKit**, Apple's successor to CallKit's provider API, or with CallKit, and
receives VoIP pushes with PushKit. Calls also work in the iOS Simulator during development,
without a device.

| Library | What it holds |
| --- | --- |
| `VoIPCore` | `VoIPClient`, the call values and the call state machine. It imports no calling framework. |
| `VoIPLiveCommunicationKit` | `LiveCommunicationKitAdapter`, which presents calls with LiveCommunicationKit. The default. |
| `VoIPCallKit` | `CallKitAdapter`, which presents calls with CallKit. |
| `VoIPPushKit` | `PushKitSource`, which receives VoIP pushes and the VoIP push token. |
| `VoIPSimulator` | `VoIPSimulator.activate()`, which presents calls in the iOS Simulator in Debug builds. |
| `VoIPTesting` | Fakes and a test clock that run `VoIPClient` in your tests without the system. |

The [simulator runtime](docs/simulator-runtime.md) beneath `VoIPSimulator` also ships on its own
([v0.1](https://github.com/relayphone/ios-voip-sdk/releases/tag/v0.1)). The SDK's terms are defined
in the [glossary](GLOSSARY.md) and its decisions are recorded in [docs/adr](docs/adr). Start with
the [documentation index](docs/README.md).

**React Native and Expo:** use [expo-callkit-telecom](https://github.com/relayphone/expo-callkit-telecom)
v2, whose iOS module runs on this SDK. This repository no longer ships an Expo module; see the
[changelog](CHANGELOG.md) to migrate from it or from `ConversationClient`.

## Requirements

- iOS and iPadOS 26 or later.
- Xcode 27.1 or later: Swift 6.4 tools in the Swift 6 language mode, with the iOS 27 SDK.
- Mac Catalyst and Apple Watch aren't supported yet.

## Install

There are no SDK releases yet: the existing version tags are simulator runtime releases. Pin a
source revision.

### Swift Package Manager

Add the package to your manifest, or in Xcode with File > Add Package Dependencies:

```swift
.package(url: "https://github.com/relayphone/ios-voip-sdk.git", revision: "<revision>")
```

Then add the libraries your app uses to its target: `VoIPCore`, exactly one of
`VoIPLiveCommunicationKit` and `VoIPCallKit`, and usually `VoIPPushKit` and `VoIPSimulator`.

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "VoIPCore", package: "ios-voip-sdk"),
    .product(name: "VoIPLiveCommunicationKit", package: "ios-voip-sdk"),
    .product(name: "VoIPPushKit", package: "ios-voip-sdk"),
    .product(name: "VoIPSimulator", package: "ios-voip-sdk"),
  ])
```

### CocoaPods

`pod 'IosVoipSDK'` installs `Core`, `LiveCommunicationKit` and `PushKit`. Name the subspecs to
choose CallKit or to add the simulator:

```ruby
pod 'IosVoipSDK', :git => 'https://github.com/relayphone/ios-voip-sdk.git', :commit => '<revision>',
                  :subspecs => ['LiveCommunicationKit', 'PushKit', 'Simulator']
```

| Subspec                | Swift package library      |
| ---------------------- | -------------------------- |
| `Core`                 | `VoIPCore`                 |
| `LiveCommunicationKit` | `VoIPLiveCommunicationKit` |
| `CallKit`              | `VoIPCallKit`              |
| `PushKit`              | `VoIPPushKit`              |
| `Simulator`            | `VoIPSimulator`            |
| `Testing`              | `VoIPTesting`              |

Each adapter subspec includes `Core`. Choose exactly one of `LiveCommunicationKit` and `CallKit`.
CocoaPods builds every subspec into one module, so import `IosVoipSDK` instead of the libraries'
modules.

`VoIPSimulator` can stay in Release builds with either package manager: `activate()` starts the
runtime only in Debug builds for the simulator, and the runtime isn't compiled for devices.

## Quick start

Give the app the Voice over IP background mode, the Audio background mode for its media, and
the Push Notifications capability. Start one client when the app launches, before a VoIP push
can arrive:

```swift
import VoIPCore
import VoIPLiveCommunicationKit
import VoIPPushKit
import VoIPSimulator

VoIPSimulator.activate()  // Debug simulator builds only; elsewhere it does nothing.
let push = PushKitSource()
let client = try VoIPClient.start(
  framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: push)
```

`AppMedia` is your real-time transport, such as WebRTC, behind `CallMedia`. The SDK prepares a
call's media before it completes an answer or a start, then starts and stops audio as the system
activates and deactivates the audio session:

```swift
@VoIPActor
final class AppMedia: CallMedia {
  nonisolated init() {}
  func prepare(_ call: Call) async throws { /* Connect to the call's room. */ }
  func activate() { /* Start the microphone and speaker. */ }
  func deactivate() { /* Stop using the audio session. */ }
}
```

Send the VoIP push token to your servers. It is `nil` after PushKit invalidates it:

```swift
Task {
  for await token in push.tokens() {
    await server.updateVoIPPushToken(token)
  }
}
```

`PushKitSource` decodes pushes in the SDK's default format, described by
`VoIPPush(defaultFormat:)`, or with your own decoder: `PushKitSource(decode:)`. The SDK reports
each push's call before the push callback returns, as Apple requires. Present a call that the
app learns about some other way with `report(_:)`:

```swift
let caller = Party(handle: try Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
let outcome = await client.report(IncomingCall(id: CallID(rawValue: callID), parties: [caller]))
```

The SDK performs the user's actions from the system's call screen itself, then tells the app.
The app requests actions the same way, and passes on what its servers say:

```swift
try await client.request(.answer(call.id))
try await client.request(.mute(call.id, muted: true))
try await client.request(.end(call.id))
await client.receive(.connected, for: call.id, eventID: EventID(rawValue: eventID))
```

Read `client.calls` and `client.isAudioActive` from SwiftUI, and follow everything that happens
with `client.events()`. Only an outgoing call waits for the app, which places it and confirms:

```swift
for await event in client.events() {
  if case .startRequested(let call) = event {
    try await server.place(call)
    await client.confirmPlaced(call.id)
  }
}
```

## Example

[`Examples/CallExample`](Examples/CallExample) is a SwiftUI app that puts the quick start
together: it shows the VoIP push token, reports an incoming call, and answers, mutes and ends it,
with a `CallMedia` that does nothing. Open `Examples/CallExample/CallExample.xcodeproj` and run
the `CallExample` scheme on an iOS 27 simulator; it uses the package from this checkout.

## LiveCommunicationKit or CallKit

An app links one calling framework adapter, and `VoIPClient` works the same with either.
Use `VoIPLiveCommunicationKit` unless you need something only CallKit has been measured to do.
LiveCommunicationKit is the default, as Apple's successor to CallKit's provider API.

`VoIPCallKit` is for apps that depend on CallKit's measured behaviour. For example, on an
iPhone 13 with iOS 27.0, a Focus that left the app out but allowed the caller in its People let
a CallKit call ring, where LiveCommunicationKit filtered the call. That was a single sample; see
[Focus breakthrough](docs/research/focus/app-breakthrough.md). With CallKit, the system
presents only the first party's handle, and Recents and Siri open the app to start a call
rather than starting it through the adapter.

Apps distributed in China mainland can't present calls with CallKit, so they need
`VoIPLiveCommunicationKit`. [ADR 0002](docs/adr/0002-one-calling-framework-per-build.md), still
a proposal, records why an app links one adapter per build.

## Testing

Run `swift test` on macOS 26 or later with Xcode 27.1. The Swift Testing suites cover the call
values, push decoding, the call state machine, the call engine, the adapters' conversions and the
test clock without a simulator.

Tests in your app can add the `VoIPTesting` library product to their test target and import
`VoIPTesting`. `FakeCallingFramework`, `FakeMedia` and `FakePushSource` stand in for the system
and the app's media, so a `VoIPClient` started with them and a `TestClock` runs every call path
on the host. `TestClock` conforms to `Clock<Duration>`; use `waitForSleepers(count:)` to await
registration, then `advance(by:)` or `run()` to resume pending sleeps without waiting for wall
time to pass.

The call journeys run the client with the PushKit source on the simulator runtime, which acts as
the system: a VoIP push, answer, audio, connect and remote end; decline; answered elsewhere and
filtered calls as previews; an outgoing call; and mute, hold and tones from the call screen. Each
journey runs once with the LiveCommunicationKit adapter and once with the CallKit adapter. Run
them, with the CallKit adapter's tests, on an iOS 27 simulator:

```sh
xcodebuild test -scheme VoIPSDK-Package \
  -only-testing:VoIPJourneyTests -only-testing:VoIPCallKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
```

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
