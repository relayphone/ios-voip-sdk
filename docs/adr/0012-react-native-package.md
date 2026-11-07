---
status: proposed
---
# The SDK ships its own React Native package

## Context
React Native and Expo apps can't use the SDK directly. Today the only binding is the iOS module of
[expo-callkit-telecom](https://github.com/relayphone/expo-callkit-telecom) v2. It wraps the SDK's
CocoaPods subspecs behind a TypeScript "conversations" API, and pins the SDK with a git tag that it
inserts into the app's Podfile. That binding has drifted from the SDK:

- **Identity differs by platform.** On iOS, an incoming conversation's ID is the server's call ID,
  but an outgoing one gets a fresh UUID. On Android, every conversation's ID is a UUIDv5 of the
  server's call ID.
- **The handler means different things per platform.** On iOS, it decides start and join placement,
  and learns of other actions after the SDK performs them. On Android, it decides every action.
- **It duplicates the SDK.** It reimplements audio route listing and selection instead of using
  `AudioSessionAdapter`.
- **Its declarations promise more than it delivers.** It declares events and settings that no
  native code emits or reads.
- **Nothing tests it.** No test drives its iOS module from JavaScript.

Any SDK change can break it unseen. For example, `CallEvent.joinFailed` gained its `JoinFailure`
reason after 0.2.1, and the module stops compiling at the next release.

The SDK's Swift API should have a second real consumer before 1.0 freezes it.

## Decision
The repository publishes an iOS Expo module from `expo/`. Its version always equals the SDK's,
and it's released from the same tag.

**Package contents:**
- **The interface:** the TypeScript conversations API, with its types, runtime, hooks and errors.
  This package is the interface's only definition. It documents iOS-only members as such.
- **The iOS module:** native code built on `VoIPClient`, under the module name
  `VoIPConversations`.
- **A config plugin** for the iOS project settings.
- **An example app.**

**The SDK's own sources.** The package ships the Swift sources of the SDK targets it uses, and its
podspec builds them. Installing the package is enough: no git pin in the Podfile, and no chance of
a version mismatch. Swift apps keep using Swift Package Manager.

**The interface follows the SDK's model, so it follows LiveCommunicationKit's:**
- **Identity.** A conversation's ID is the app's call ID (`CallID.rawValue`), for incoming and
  outgoing conversations alike. Platform identifiers stay internal.
- **The handler.** It decides only what the app must decide: placing a start or a join
  ([ADR 0003](0003-native-actions-app-informed.md)). The SDK performs answer, end, mute, hold and
  tones natively, and the app learns of them from the snapshot and events.
- **Audio routes** come from `AudioSessionAdapter`.
- **Media.** Native media registers through one `CallMedia`-based API. Media options are WebRTC's
  audio session (which LiveKit's React Native SDK also uses) or none.
- **No dead surface.** Events, settings and methods that the native module doesn't implement are
  removed. Transport types stay internal.

**Other platforms implement the same interface.** A cross-platform package depends on this one,
re-exports its API, and registers an Android module named `VoIPConversations` that implements the
same native transport with the same meaning. expo-callkit-telecom v2 is that package for Android
with Core-Telecom.

**Tests:**
- TypeScript unit and type tests.
- Swift tests for the module's mapping.
- Journeys in the simulator, driven from JavaScript in the example app with the SDK's simulator
  runtime, and asserted on the runtime's event journal and the app's own results:
  - an incoming push, answer, hold, end;
  - an outgoing call;
  - joining a preview;
  - a call answered elsewhere;
  - a filtered call.

  They run in CI on one simulator, on changes to `expo/` or the SDK targets the package ships.

## Considered options
- **Keep the binding in expo-callkit-telecom.** That's where it drifted. Every SDK change would
  need a release there before a React Native app could use it, and the SDK's own CI would never
  run its JavaScript.
- **A separate repository for the package.** It would need the same version lockstep, and couldn't
  share CI with the SDK targets it ships.
- **Keep pinning the SDK with a git tag in the Podfile.** That edits the app's Podfile, and lets
  the npm package and the SDK get out of step.

## Consequences
- React Native apps get the SDK's iOS behaviour with one install, and its journeys run in this
  repository's CI.
- A change to the SDK's public API must update the package in the same pull request. The
  compatibility check and the journeys enforce this.
- expo-callkit-telecom v2 keeps the Android implementation and composes this package. Its
  Android module changes to match the identity and handler meaning above.
- The npm package adds a release artifact and a scope. Each release publishes it after the tag.
