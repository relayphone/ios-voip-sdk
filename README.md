# ios-voip-sdk

A VoIP calling SDK for iOS. It keeps the state of every call, presents calls with
**LiveCommunicationKit**, Apple's successor to CallKit's provider API, or with CallKit, and
receives VoIP pushes with PushKit. Calls also work in the iOS Simulator during development,
without a device.

| Library | What it holds |
| --- | --- |
| `VoIPCore` | `VoIPClient`, the call values and the call state machine. It imports no calling framework. |
| `VoIPAudio` | `AudioSessionAdapter`, which configures the audio session for calls, reports its interruptions and lists its audio routes. |
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
`VoIPLiveCommunicationKit` and `VoIPCallKit`, and usually `VoIPPushKit`, `VoIPAudio` and
`VoIPSimulator`.

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "VoIPCore", package: "ios-voip-sdk"),
    .product(name: "VoIPLiveCommunicationKit", package: "ios-voip-sdk"),
    .product(name: "VoIPPushKit", package: "ios-voip-sdk"),
    .product(name: "VoIPAudio", package: "ios-voip-sdk"),
    .product(name: "VoIPSimulator", package: "ios-voip-sdk"),
  ])
```

### CocoaPods

`pod 'IosVoipSDK'` installs `Core`, `LiveCommunicationKit` and `PushKit`. Name the subspecs to
choose CallKit or to add audio and the simulator:

```ruby
pod 'IosVoipSDK', :git => 'https://github.com/relayphone/ios-voip-sdk.git', :commit => '<revision>',
                  :subspecs => ['LiveCommunicationKit', 'PushKit', 'Audio', 'Simulator']
```

| Subspec                | Swift package library      |
| ---------------------- | -------------------------- |
| `Core`                 | `VoIPCore`                 |
| `Audio`                | `VoIPAudio`                |
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
import VoIPAudio
import VoIPCore
import VoIPLiveCommunicationKit
import VoIPPushKit
import VoIPSimulator

VoIPSimulator.activate()  // Debug simulator builds only; elsewhere it does nothing.
let push = PushKitSource()
let audio = AudioSessionAdapter()
let client = try VoIPClient.start(
  framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: push, audio: audio)
```

`AppMedia` is your real-time transport, such as WebRTC, behind `CallMedia`. The SDK prepares a
call's media before it completes an answer or a start, then starts and stops audio as the system
activates, deactivates or interrupts the audio session:

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

## Audio

`AudioSessionAdapter` sets the audio session to the play-and-record category in voice chat mode
before the SDK completes an answer, start or join, with Bluetooth hands-free and A2DP devices,
and the speaker by default for calls with video. Change these with `AudioSessionConfiguration`.
Only the system activates the session for calls; the adapter never does.

When the system interrupts the audio, for Siri or another app, the SDK stops the media and sends
`audioInterrupted(_:)`. When the system's media services reset, it sends `mediaServicesReset`
and configures the session again; recreate the media's audio objects before the next
`activate()`. Once the interruption ends, or after the reset, a call that takes part and isn't on
hold ends with `audioRecoveryTimedOut` unless the system activates audio again within
`Deadlines.audioRecovery`. [ADR 0007](docs/adr/0007-sdk-configures-audio-session.md) records why.

Show the routes in the call screen from `audio.routes`, and route calls with
`selectRoute(_:)`:

```swift
ForEach(audio.routes.available) { route in
  Button(route.name) { Task { try await audio.selectRoute(route.id) } }
}
```

A device that only plays audio, such as AirPlay or a Bluetooth A2DP speaker, is listed while it's
the current route; offer `AVRoutePickerView` to choose one.

## Example

[`Examples/CallExample`](Examples/CallExample) is a SwiftUI app that puts the quick start
together: it shows the VoIP push token and the audio routes, reports an incoming call, and
answers, mutes and ends it, with a `CallMedia` that does nothing. Open
`Examples/CallExample/CallExample.xcodeproj` and run the `CallExample` scheme on an iOS 27
simulator; it uses the package from this checkout.

## LiveCommunicationKit or CallKit

An app links one calling framework adapter, and `VoIPClient` works the same with either.
Use `VoIPLiveCommunicationKit` unless you need something only CallKit has been measured to do.
LiveCommunicationKit is the default, as Apple's successor to CallKit's provider API.

`VoIPCallKit` is for apps that depend on CallKit's measured behaviour. For example, on an
iPhone 13 with iOS 27.0, a Focus that left the app out but allowed the caller in its People let
a CallKit call ring, where LiveCommunicationKit filtered the call. That was a single sample.
With CallKit, the system presents only the first party's handle, and Recents and Siri open the
app to start a call rather than starting it through the adapter.

Apps distributed in China mainland can't present calls with CallKit, so they need
`VoIPLiveCommunicationKit`. [ADR 0002](docs/adr/0002-one-calling-framework-per-build.md), still
a proposal, records why an app links one adapter per build.

## Testing your app

Tests in your app can add the `VoIPTesting` library product to their test target and import
`VoIPTesting`. `FakeCallingFramework`, `FakeMedia`, `FakePushSource` and `FakeAudioSession` stand
in for the system and the app's media, so a `VoIPClient` started with them and a `TestClock` runs
every call path on the host. `TestClock` conforms to `Clock<Duration>`; use
`waitForSleepers(count:)` to await registration, then `advance(by:)` or `run()` to resume pending
sleeps without waiting for wall time to pass.

## Running the tests

On macOS 26 or later with Xcode 27.1, run the host tests, then every suite on an iOS 27 simulator:

```sh
swift test
xcodebuild test -scheme VoIPSDK-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
```

`swift test` covers the call values, push decoding, the call state machine, the call engine, the
adapters' conversions, the audio session adapter on a fake session and the test clock, as well as
the simulator runtime's policies against the device measurements, `cksim` and the Inspector's
model. The simulator run adds the call journeys, which run the client with the PushKit source on
the simulator runtime acting as the system: a VoIP push, answer, audio, connect and remote end;
decline; answered elsewhere and filtered calls as previews; an outgoing call; and mute, hold and
tones from the call screen, each through both the LiveCommunicationKit and the CallKit adapter. It
also runs the runtime's own tests, which drive CallKit and LiveCommunicationKit calls through the
runtime as the system does.

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
