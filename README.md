# ios-voip-sdk

A VoIP calling SDK for iOS built on **LiveCommunicationKit**, Apple's successor to CallKit's provider API. Calls work in the iOS simulator during development, without a device.

| Product | Status |
| --- | --- |
| **Swift package**: owns the app's only `ConversationManager`, projects system call state, runs a promise/async handler with platform deadlines, handles PushKit (including the iOS 26.4 `mustReport` metadata), media adapters and default-calling-app entry points | M0 acceptance measured locally and in hosted CI. M1 ([#16](https://github.com/ziahamza/ios-voip-sdk/pull/16)) and M2 ([#17](https://github.com/ziahamza/ios-voip-sdk/pull/17)) contain the implementation and evidence; their PR descriptions record acceptance status. M3 pending. |
| **iOS-only Expo module**: the same Swift sources behind a React Native/Expo API (`useConversations()`, a handler, commands, reports, audio routes, push token) with a config plugin | M0 acceptance measured locally and in hosted CI. M1 ([#16](https://github.com/ziahamza/ios-voip-sdk/pull/16)) and M2 ([#17](https://github.com/ziahamza/ios-voip-sdk/pull/17)) contain the implementation and evidence; their PR descriptions record acceptance status. M3 pending. |
| **Simulator runtime**: genuine CallKit and LiveCommunicationKit tear calls down in the iOS simulator; this runtime supplies the missing call service | **v0.1.1 released** ([release](https://github.com/ziahamza/ios-voip-sdk/releases/tag/v0.1.1), [release qualification](docs/runtime-releases.md), [runtime docs](docs/simulator-runtime.md)). M0 qualifies built-in in-process activation. |

The API design is [RFC 0001](https://github.com/ziahamza/expo-callkit-telecom/pull/10). It is written as a possible v2 of [expo-callkit-telecom](https://github.com/mfairley/expo-callkit-telecom), whose iOS side would then depend on this package's Expo module. This SDK doesn't wait on that: it is built here first.

**Start with [docs/START-HERE.md](docs/START-HERE.md).** It covers decisions, architecture, milestones, evidence and working rules.

## Requirements

- iOS and iPadOS 17.4 or later.
- Mac Catalyst waits for an Apple SDK fix: with Xcode 27.1, `ConversationManagerDelegate` conformances fail to link on Catalyst.
- Apple Watch is deferred.

## Example and qualification

The Swift package exports `SimulatorSupport.activateIfNeeded()`. The Expo module compiles the same Swift and Objective-C sources and supports Apple platforms only. Runtime implementation is guarded out of device builds; activation happens before the SDK creates its sole LCK manager. Activation failure logs a reason and restores genuine framework behavior.

From a clean checkout, run `npm ci`, `npm run build`, then `npm exec --workspace ios-voip-sdk-example -- expo prebuild --platform ios --no-install`. Install the generated iOS project's pods and build its Release scheme to bundle JavaScript. The example exercises public conversation commands, reports, handlers, PushKit and hooks; [M1](https://github.com/ziahamza/ios-voip-sdk/pull/16) and [M2](https://github.com/ziahamza/ios-voip-sdk/pull/17) track implementation and current acceptance status.

**Measured M0:** the Expo 58 Release example rings, joins and ends on iOS 27.0 without injection; all three bootstrap cases and device-code exclusion checks pass. Hosted [run 39714935488](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39714935488) passed, and [PR #15](https://github.com/ziahamza/ios-voip-sdk/pull/15) merged at `9852433`. [The M0 handoff](docs/progress/2026-10-22-codex-m0.md) identifies the source-bound evidence and its limits.

The module's peer ranges retain Expo 55–58 compatibility. The example and development tools pin Expo 58 for its native scene lifecycle. Expo 58 is locally qualified; Expo 55 has historical build evidence, while runtime compatibility with Expo 55–57 remains unqualified.

## License

None yet. A license will be added before the beta release. The v0.1 release was published with an MIT license file.
