# ios-voip-sdk

A VoIP calling SDK for iOS. It keeps the state of every call, presents calls with
**LiveCommunicationKit**, Apple's successor to CallKit's provider API, and receives VoIP pushes
with PushKit. Calls also work in the iOS Simulator during development, without a device.

| Library | What it holds |
| --- | --- |
| `VoIPCore` | `VoIPClient`, the call values and the call state machine. It imports no calling framework. |
| `VoIPAudio` | `AudioSessionAdapter`, which configures the audio session for calls, reports its interruptions and lists its audio routes. |
| `VoIPFocus` | `CallFocusFilter`, the app's Focus filter, and `FocusFilterStore`, which shares the Focus filter state between the app and its extensions through an App Group. It doesn't depend on `VoIPCore`. |
| `VoIPLiveActivity` | `CallPreviewAttributes`, the type of a call preview's Live Activity, whose JSON the app's servers send ([contract](docs/call-preview-activity.md)). |
| `VoIPLiveCommunicationKit` | `LiveCommunicationKitAdapter`, which presents calls with LiveCommunicationKit. |
| `VoIPPushKit` | `PushKitSource`, which receives VoIP pushes and the VoIP push token. |
| `VoIPNotifications` | `CallNotifier`, which posts a communication notification for each call that Do Not Disturb or a Focus filters, so that the people the Focus allows still reach the user. |
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

Then add the libraries your app uses to its target: `VoIPCore`, `VoIPLiveCommunicationKit`, and
usually `VoIPPushKit`, `VoIPAudio` and `VoIPSimulator`.

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

`pod 'IosVoipSDK'` installs `Core`, `LiveCommunicationKit` and `PushKit`. Name the subspecs to add
audio and the simulator:

```ruby
pod 'IosVoipSDK', :git => 'https://github.com/relayphone/ios-voip-sdk.git', :commit => '<revision>',
                  :subspecs => ['LiveCommunicationKit', 'PushKit', 'Audio', 'Simulator']
```

| Subspec                | Swift package library      |
| ---------------------- | -------------------------- |
| `Core`                 | `VoIPCore`                 |
| `Audio`                | `VoIPAudio`                |
| `Focus`                | `VoIPFocus`                |
| `LiveActivity`         | `VoIPLiveActivity`         |
| `LiveCommunicationKit` | `VoIPLiveCommunicationKit` |
| `PushKit`              | `VoIPPushKit`              |
| `Notifications`        | `VoIPNotifications`        |
| `Simulator`            | `VoIPSimulator`            |
| `Testing`              | `VoIPTesting`              |

Each adapter subspec includes `Core`; `Focus` doesn't need it. CocoaPods builds every subspec into
one module, so import `IosVoipSDK` instead of the libraries' modules.

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
with `client.events()`. Only an outgoing call waits for the app, which places it and confirms.
When the app can't place it, it says so, and the call ends with `CallFailure.notPlaced`:

```swift
for await event in client.events() {
  if case .startRequested(let call) = event {
    do {
      try await server.place(call)
      await client.confirmPlaced(call.id)
    } catch {
      await client.confirmNotPlaced(call.id)
    }
  }
}
```

A stream from `events()` starts when the app subscribes, so it can miss the first events of a
cold launch: the SDK reports the call of the VoIP push that launched the app as soon as PushKit
delivers it. Code that must see every event is a `CallObserver`, passed to `start` as
`observers`, which subscribes in `attach(to:)` before the client attaches the push source.

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

## Focus

When a Focus doesn't allow the app, the system filters its incoming calls, so the app's servers
choose how each call appears on this device: a VoIP push that rings, or a call preview. To know
what the user wants in each Focus, they need the Focus filter state: what the app's Focus filter
last asked for. The `VoIPFocus` library records it.

Declare the app's Focus filter, a `CallFocusFilter`, in an App Intents extension: the system runs
it each time a Focus that has it turns on or off, without launching the app. Its parameters, and
the settings they make, are the app's own. Keep the settings and their store in a file that both
the app and the extension compile:

```swift
import VoIPFocus

struct CallSettings: Codable, Hashable, Sendable {
  var ringing = Ringing.everyone  // Everyone, favorites or nobody.

  static let store = FocusFilterStore<CallSettings>(appGroup: "group.com.example.calls")
}
```

Then declare the filter in the extension only:

```swift
import AppIntents
import VoIPFocus

struct CallsFocusFilter: CallFocusFilter {
  static let title: LocalizedStringResource = "Incoming calls"
  static let store = CallSettings.store

  @Parameter(title: "Ring for", default: .everyone)
  var ringing: Ringing  // `Ringing` conforms to `AppEnum` in the extension.

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "Ring for \(ringing.rawValue)")
  }

  var settings: CallSettings { CallSettings(ringing: ringing) }

  func didRecord(_ state: FocusFilterState<CallSettings>) async {
    await server.updateFocusFilterState(state)
  }
}
```

The filter's `perform()` records the state in `store`, then calls `didRecord(_:)` in the
extension, where the app sends the state to its servers. When a Focus turns off, the system runs
the filter again with every parameter reset to its default, so the state is `active(_:since:)`
with the settings, or `inactive(since:)` when they equal the defaults: make the defaults what the
app does outside a Focus. Until the filter first runs, the state is `unknown`.
[ADR 0008](docs/adr/0008-focus-filter-defaults-are-inactive.md) records why.

Give the app and the extension the same App Group. The app follows the same store, and sends
the state to its servers too, in case the extension didn't reach them:

```swift
for await state in CallSettings.store.states() {
  await server.updateFocusFilterState(state)
}
```

The state says what the filter asked for, not whether a Focus is on: a Focus without the filter
still filters the app's calls. Neither the filter nor the store needs a permission.

## Call notifications

When a Focus doesn't allow the app, the system filters its incoming calls, even from the people
the Focus allows. `CallNotifier`, in `VoIPNotifications`, posts a communication notification for
each such call, which the system shows as coming from the caller: at once for the people the Focus
allows, and quietly in Notification Center for everyone else. It never rings: the notification is
passive or active, with the default sound or none
([ADR 0009](docs/adr/0009-call-notifications-never-ring.md)).

Give the app:

- the Communication Notifications capability, which is the
  `com.apple.developer.usernotifications.communication` entitlement;
- `INStartCallIntent` in the `NSUserActivityTypes` array of its Info.plist;
- the user's permission for notifications, which the app asks for. The SDK never asks.

Then pass a notifier to `start` as an observer:

```swift
import VoIPNotifications

let notifier = CallNotifier()
let client = try VoIPClient.start(
  framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: push, observers: [notifier])
```

The notifier posts once per call, when the call becomes a call preview because Do Not Disturb or a
Focus filtered it. When the call is joined here, it withdraws the notification. When the call ends
without being joined here, it replaces the notification with a missed-call notification.
`CallNotifier.Options` changes this: `triggers` adds the calls that the presentation policy shows
as call previews, `endedWithoutJoining` keeps or removes the notification instead, and `customize`
localizes the English text or drops a notification.

Add the category with the Join action, and pass the user's responses and the system's requests to
call someone to the notifier:

```swift
UNUserNotificationCenter.current().setNotificationCategories(
  appCategories.union([UserNotificationsAdapter.category()]))

// In the app's UNUserNotificationCenterDelegate:
func userNotificationCenter(
  _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
) async {
  guard let response = CallNotificationResponse(response) else { return }  // Not a call's.
  _ = try? await notifier.handle(response)  // Joins the call if it is live here.
}

// From Recents and Siri:
.onContinueUserActivity("INStartCallIntent") { activity in
  guard let request = StartCallRequest(activity) else { return }
  Task {
    if case .callBack(let party, let hasVideo)? = try? await notifier.handle(request) {
      let call = OutgoingCall(
        id: CallID(rawValue: UUID().uuidString), parties: [party], hasVideo: hasVideo)
      try await client.request(.start(call))
    }
  }
}
```

When a call preview with the party is live here, the notifier joins it and returns `.joining`;
otherwise it returns `.callBack`, and the app calls the party with a Call ID of its own. When the
app's servers send a call notification as an alert push instead, a notification service extension
builds the same content with `UserNotificationsAdapter().content(for:updating:)`. Set the push's
`apns-collapse-id` to the call ID, so that a notification that the app posts later for the call
replaces it.

## Example

[`Examples/CallExample`](Examples/CallExample) is a SwiftUI app that puts the quick start
together: it shows the VoIP push token and the audio routes, reports an incoming call, and
answers, mutes and ends it, with a `CallMedia` that does nothing. Its App Intents extension has
a Focus filter, whose state the app shows. It also previews a call with a call notification,
which joins the call when tapped. Open `Examples/CallExample/CallExample.xcodeproj` and run the
`CallExample` scheme on an iOS 27 simulator; it uses the package from this checkout. The Focus
filter needs a signed build with your team's App Group in place of
`group.com.example.CallExample`, and call notifications need one with the Communication
Notifications capability.

## Why LiveCommunicationKit

The SDK presents calls with LiveCommunicationKit only. Measured on an iPhone 13 running iOS 27.1,
it showed an incoming call about a second sooner than CallKit. Apple asks CallKit apps to move to
it, and unlike CallKit it can be active in apps on the China mainland storefront.

When a Focus doesn't allow the app, LiveCommunicationKit filters an incoming call, even one from a
person the Focus allows, and the SDK reports it as a filtered call. The app can still reach the
user: a call communication notification gets through a Focus for the people it allows (see
[Call notifications](#call-notifications)), and a Live Activity can show the call silently as a
call preview. CarPlay calling is documented only for
CallKit. [ADR 0002](docs/adr/0002-one-calling-framework-per-build.md) records the decision and its
consequences.

## Testing your app

Tests in your app can add the `VoIPTesting` library product to their test target and import
`VoIPTesting`. `FakeCallingFramework`, `FakeMedia`, `FakePushSource` and `FakeAudioSession` stand
in for the system and the app's media, so a `VoIPClient` started with them and a `TestClock` runs
every call path on the host. `FakeCallNotificationCenter` keeps a `CallNotifier`'s notifications
as the system does. `TestClock` conforms to `Clock<Duration>`; use
`waitForSleepers(count:)` to await registration, then `advance(by:)` or `run()` to resume pending
sleeps without waiting for wall time to pass.

## Running the tests

On macOS 26 or later with Xcode 27.1, run the host tests, then every suite on an iOS 27 simulator:

```sh
swift test
xcodebuild test -scheme VoIPSDK-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
```

`swift test` covers the call values, push decoding, the call state machine, the call engine, the
LiveCommunicationKit adapter's conversions, the audio session adapter on a fake session, the Focus
filter and its store, and the test clock, as well as the simulator runtime's policies against the device measurements, `cksim` and the
Inspector's model. The simulator run adds the call journeys, which run the client with the
LiveCommunicationKit adapter and the PushKit source on the simulator runtime acting as the system: a
VoIP push, answer, audio, connect and remote end; decline; answered elsewhere and filtered calls as
previews; an outgoing call; and mute, hold and tones from the call screen. It also runs the
runtime's own tests, which drive CallKit and LiveCommunicationKit calls through the runtime as the
system does.

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
