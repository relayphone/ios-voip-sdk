# ios-voip-sdk

A VoIP calling SDK for iOS built on **LiveCommunicationKit**, Apple's successor to CallKit's provider API. Calls work in the iOS simulator during development, without a device.

| Product                                                                                                                                                        | Status                                                                                                                                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Swift package**: one `ConversationManager`, conversation state, handlers with platform deadlines, commands/reports, PushKit, media adapters and audio routes | Conversation, push and audio APIs are implemented. Plain-simulator journeys, real Swift LiveKit manual-engine cases and device Release exclusions pass in CI.                                              |
| **iOS-only Expo module**: the same Swift sources behind React Native/Expo hooks, commands, reports and a config plugin                                         | The public conversation API and native PushKit startup are implemented. The Expo 58 example includes healthy/stale LiveKit runtime journeys and selected Release device exclusions in CI.                  |
| **Simulator runtime**: supplies the call service missing from genuine CallKit and LiveCommunicationKit in the simulator                                        | **v0.1 shipped** ([release](https://github.com/relayphone/ios-voip-sdk/releases/tag/v0.1), [docs](docs/simulator-runtime.md)). SDK source builds activate it in-process, with plain-simulator CI coverage. |

See the [review checkpoint](docs/progress/2026-10-28-m-stable.md) for delivered changes, CI evidence and remaining acceptance gaps. Native [default-calling delivery](Expo/M3-default-calling.md) routes URLs and call intents to `dialRequest`; device Settings/Siri dispatch remains to be measured.

The API design is [RFC 0001](https://github.com/relayphone/expo-callkit-telecom/pull/10). It is written as a possible v2 of [expo-callkit-telecom](https://github.com/mfairley/expo-callkit-telecom), whose iOS side would then depend on this package's Expo module. This SDK doesn't wait on that: it is built here first.

**Start with the [documentation index](docs/README.md).**

## Install

For Swift Package Manager, pin the SDK source revision in your package manifest:

```swift
.package(url: "https://github.com/relayphone/ios-voip-sdk.git", revision: "87a6125c18f9ec7018ac056c67baa06e9dbac07c")
```

Add `.product(name: "VoIPSDK", package: "ios-voip-sdk")` to your target dependencies and use `import VoIPSDK`. This revision pins source; the existing version tags refer to simulator-runtime releases, not SDK releases.

For Expo, install the Git dependency in your app:

```sh
npm install github:relayphone/ios-voip-sdk#main
```

Follow the [Expo setup guide](Expo/README.md) to configure the plugin and rebuild the native app. Git installation builds the TypeScript entry point during package preparation.

## Requirements

- iOS and iPadOS 26 or later.
- Swift 6.4 tools with the Swift 6 language mode. Build the Swift package and Expo module with the iOS 27 SDK or newer (CI uses Xcode 27.1). One binary handles legacy interruptions on iOS 26 and the new lifecycle notifications on 27+. The standalone simulator runtime retains its earlier compiler jobs.
- Mac Catalyst waits for an Apple SDK fix: with Xcode 27.1, `ConversationManagerDelegate` conformances fail to link on Catalyst.
- Apple Watch is deferred.

## Example and simulator acceptance

The Swift package exports `SimulatorSupport.activateIfNeeded()`. The Expo module compiles the same Swift and Objective-C sources and supports Apple platforms only. Runtime implementation is guarded out of device builds; activation happens before the SDK creates its sole LCK manager. Activation failure logs a reason and restores genuine framework behavior.

From a clean checkout, run `npm ci`, `npm run build`, then `npm exec --workspace ios-voip-sdk-example -- expo prebuild --platform ios --no-install`. Install the generated iOS project's pods and build its Release scheme to bundle JavaScript. The example uses the public conversation API for incoming reports, join, connected reports, hold, resume and end. Production applications supply their signaling and media; see the [example guide](example/README.md).

**Qualified in CI:** the Expo 58 Release example runs without injection on iOS 27.0, including bootstrap, conversation, contract, system-action and cold-push journeys. Device Release inspection checks that simulator implementation and direct CallKit linkage are excluded. Typed caller identity and answered-elsewhere dismissal are covered by the [current acceptance run](https://github.com/relayphone/ios-voip-sdk/actions/runs/40693437174).

The module's peer ranges retain Expo 55–58 compatibility. The example and development tools pin Expo 58 for its native scene lifecycle. Expo 58 is covered by CI; Expo 55 has historical build evidence, while runtime compatibility with Expo 55–57 remains unqualified.

## Call core

The `VoIPCore` library is the start of a smaller core that keeps its own state for every
call and treats CallKit and LiveCommunicationKit as presentation surfaces. It holds the call
values, the call state machine and `VoIPClient`, which runs them behind small seams for the
calling framework, the app's media and VoIP pushes. It imports no UIKit, CallKit,
LiveCommunicationKit, PushKit or AVFAudio. Two more libraries plug the system into those seams:
`VoIPLiveCommunicationKit` presents calls with `LiveCommunicationKitAdapter`, and `VoIPPushKit`
receives VoIP pushes and the push token with `PushKitSource`:

```swift
let push = PushKitSource()
let client = try VoIPClient.start(
  framework: LiveCommunicationKitAdapter(), media: media, push: push)
```

Its terms are defined in the [glossary](GLOSSARY.md) and its decisions are recorded in
[docs/adr](docs/adr).

## Testing

Run `swift test` on macOS 26 or later with the Xcode toolchain above. The Swift
Testing suites cover caller validation, push decoding, models, the call state machine,
the call engine and the test clock without a simulator. Native calling and media
acceptance run separately in CI.

Tests in consuming apps can add the `VoIPTesting` library product to their test
target and import `VoIPTesting`. Its `TestClock` conforms to `Clock<Duration>`;
use `waitForSleepers(count:)` to await registration, then `advance(by:)` or `run()`
to resume pending sleeps without waiting for wall time to pass. `FakeCallingFramework`,
`FakeMedia` and `FakePushSource` stand in for the system and the app's media, so a
`VoIPClient` started with them and a `TestClock` runs every call path on the host.

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
