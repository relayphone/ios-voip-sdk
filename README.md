# ios-voip-sdk

A VoIP calling SDK for iOS built on **LiveCommunicationKit**, Apple's successor to CallKit's provider API. Calls work in the iOS simulator during development, without a device.

| Product                                                                                                                                                        | Status                                                                                                                                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Swift package**: one `ConversationManager`, conversation state, handlers with platform deadlines, commands/reports, PushKit, media adapters and audio routes | Conversation, push and audio APIs are implemented. Plain-simulator journeys, real Swift LiveKit manual-engine cases and device Release exclusions pass in CI.                                              |
| **iOS-only Expo module**: the same Swift sources behind React Native/Expo hooks, commands, reports and a config plugin                                         | The public conversation API and native PushKit startup are implemented. The Expo 58 example and selected LiveKit Release build pass CI; complete Expo healthy/stale media journeys remain open.            |
| **Simulator runtime**: supplies the call service missing from genuine CallKit and LiveCommunicationKit in the simulator                                        | **v0.1 shipped** ([release](https://github.com/relayphone/ios-voip-sdk/releases/tag/v0.1), [docs](docs/simulator-runtime.md)). SDK source builds activate it in-process, with plain-simulator CI coverage. |

See the [M-Stable review checkpoint](docs/progress/2026-10-28-m-stable.md) for delivered changes, CI evidence and remaining M2/M3 and device acceptance gaps. M3 default-calling delivery and M3.5 are not part of the qualified surface.

The API design is [RFC 0001](https://github.com/relayphone/expo-callkit-telecom/pull/10). It is written as a possible v2 of [expo-callkit-telecom](https://github.com/mfairley/expo-callkit-telecom), whose iOS side would then depend on this package's Expo module. This SDK doesn't wait on that: it is built here first.

**Start with [docs/START-HERE.md](docs/START-HERE.md).** It covers decisions, architecture, milestones, evidence and working rules.

## Requirements

- iOS and iPadOS 17.4 or later.
- Build the Swift package and Expo module with the iOS 27 SDK or newer (CI uses Xcode 27.1). One binary handles legacy interruptions on 17.4–26 and the new lifecycle notifications on 27+. The standalone simulator runtime retains its earlier compiler lanes.
- Mac Catalyst waits for an Apple SDK fix: with Xcode 27.1, `ConversationManagerDelegate` conformances fail to link on Catalyst.
- Apple Watch is deferred.

## Example and simulator acceptance

The Swift package exports `SimulatorSupport.activateIfNeeded()`. The Expo module compiles the same Swift and Objective-C sources and supports Apple platforms only. Runtime implementation is guarded out of device builds; activation happens before the SDK creates its sole LCK manager. Activation failure logs a reason and restores genuine framework behavior.

From a clean checkout, run `npm ci`, `npm run build`, then `npm exec --workspace ios-voip-sdk-example -- expo prebuild --platform ios --no-install`. Install the generated iOS project's pods and build its Release scheme to bundle JavaScript. The example uses the public conversation API for incoming reports, join, connected reports, hold, resume and end. Production applications supply their signaling and media; see the [example guide](example/README.md).

**Qualified in CI:** the Expo 58 Release example runs without injection on iOS 27.0, including bootstrap, conversation, contract, system-action and cold-push journeys. Device Release inspection checks that simulator implementation and direct CallKit linkage are excluded. Typed caller identity and answered-elsewhere dismissal are covered by the [current acceptance run](https://github.com/relayphone/ios-voip-sdk/actions/runs/40693437174).

The module's peer ranges retain Expo 55–58 compatibility. The example and development tools pin Expo 58 for its native scene lifecycle. Expo 58 is covered by CI; Expo 55 has historical build evidence, while runtime compatibility with Expo 55–57 remains unqualified.

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
