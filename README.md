# ios-voip-sdk

A VoIP calling SDK for iOS built on **LiveCommunicationKit**, Apple's successor to CallKit's provider API. Calls work in the iOS simulator during development, without a device.

| Product | Status |
| --- | --- |
| **Swift package**: owns the app's only `ConversationManager`, projects system call state, runs a promise/async handler with platform deadlines, handles PushKit (including the iOS 26.4 `mustReport` metadata), media adapters and default-calling-app entry points | Planned: milestones M0–M3 |
| **iOS-only Expo module**: the same Swift sources behind a React Native/Expo API (`useConversations()`, a handler, commands, reports, audio routes, push token) with a config plugin | Planned: milestones M0–M3 |
| **Simulator runtime**: genuine CallKit and LiveCommunicationKit tear calls down in the iOS simulator; this runtime supplies the missing call service | **v0.1 shipped** ([release](https://github.com/ziahamza/ios-voip-sdk/releases/tag/v0.1), [docs](docs/simulator-runtime.md)). Next, the SDK activates it in-process. |

The API design is [RFC 0001](https://github.com/ziahamza/expo-callkit-telecom/pull/10). It is written as a possible v2 of [expo-callkit-telecom](https://github.com/mfairley/expo-callkit-telecom), whose iOS side would then depend on this package's Expo module. This SDK doesn't wait on that: it is built here first.

**Start with [docs/START-HERE.md](docs/START-HERE.md).** It covers decisions, architecture, milestones, evidence and working rules.

## Requirements

- iOS and iPadOS 17.4 or later.
- Mac Catalyst waits for an Apple SDK fix: with Xcode 27.1, `ConversationManagerDelegate` conformances fail to link on Catalyst.
- Apple Watch is deferred.

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
