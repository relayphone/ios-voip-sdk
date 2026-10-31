# Changelog

Changes not yet released are recorded below. Public API changes include migration guidance.

## Unreleased

### Added

- The `VoIPCore` library holds the values of the new call core: `Call`,
  `CallID`, `Handle` (phone numbers must be E.164), `Party`, `CallStatus` with
  `PreviewReason` and `EndReason`, `Action`, `ServerEvent`, `PresentationPolicy`,
  `CallEvent` and `VoIPConfiguration` with `Deadlines`. It has no system framework dependencies.

- `VoIPClient` runs the call core on the `VoIPActor` global actor. Start it once with
  `start(framework:media:push:audio:configuration:clock:)`, observe `calls` and `isAudioActive`,
  subscribe with `events()`, and drive calls with `request(_:)`, `confirmPlaced(_:)`,
  `report(_:)` and `receive(_:for:eventID:)`. It reports a VoIP push's call before the push
  callback returns, recognises repeated pushes and server events by event ID and call ID, and
  remembers ended calls and early server events for `VoIPConfiguration.retention`.
- The seams for calling-framework adapters and the app's media: `CallingFramework` with
  `FrameworkEvent`, `CallMedia`, `PushSource` with `VoIPPush` and `PushCompletion`, `ActionID`
  and `deviceUUID(for:)`. `VoIPConfiguration` adds `maximumCalls`, `supportedHandleTypes`,
  `includesCallsInRecents`, `ringtoneSound`, `iconTemplateImageData` and `retention`, and
  `ActionError` adds `unknownCall` and `refused`.
- `VoIPTesting` adds `FakeCallingFramework`, `FakeMedia` and `FakePushSource`, which run the
  client on the macOS host with `TestClock`.
- The `VoIPLiveCommunicationKit` library's `LiveCommunicationKitAdapter` presents calls with
  LiveCommunicationKit. It reports every handle of every party, maps the SDK's actions and end
  reasons to LiveCommunicationKit's, passes audio activation, action timeouts and resets to the
  SDK, and starts a VoIP push's report before the push callback returns. It never links CallKit.
  `VoIPConfiguration.supportsVideo` (default `false`) tells the system whether calls can have
  video.
- `VoIPActor.assumeIsolated(_:file:line:)` runs a system callback that arrives on
  `VoIPActor.queue`, such as a PushKit callback, on the actor without hopping, and
  stops the app when the callback arrives elsewhere.
- The `VoIPPushKit` library's `PushKitSource` receives VoIP pushes from PushKit on `VoIPActor`,
  with the `mustReport` metadata on iOS 26.4 and later, and finishes each push exactly once,
  within 4 seconds. `init(decode:)` takes the app's decoder for its push payloads, and
  `tokens()` streams the VoIP push token for the app to register with its servers.
- `VoIPPush(defaultFormat:)` decodes the SDK's existing `incomingCall` and `callEnded` push
  payloads, keeping every JSON value in an incoming call's `metadata` object.
- `JSONValue` is a JSON value: `null`, `bool(_:)`, `number(_:)`, `string(_:)`, `array(_:)` or
  `object(_:)`, written with literals. `Call`, `IncomingCall` and `OutgoingCall` carry the app's
  `metadata` as `[String: JSONValue]`.
- The `VoIPSimulator` library's `VoIPSimulator.activate()` starts the simulator runtime in
  Debug simulator builds, before `VoIPClient.start`, so the shipping adapters present calls,
  activate audio and receive VoIP pushes in the iOS Simulator. Elsewhere it does nothing. The
  runtime now attributes a LiveCommunicationKit report entered while a push callback runs to
  that push, as LiveCommunicationKit reports from its own queue.
- `VoIPClient.report(_:)` returns how the call appears on this device: `previewed(_:)` for a
  call preview, including a filtered call that the policy previews, and `notShown` when the
  policy is `none`, instead of `presented`. `PresentationOutcome` adds both cases.
- The `VoIPAudio` library's `AudioSessionAdapter` is the audio session for calls; pass it to
  `VoIPClient.start` as `audio`. Before the SDK completes an answer, start or join, it sets
  `AVAudioSession` to the play-and-record category in voice chat mode with Bluetooth hands-free
  and A2DP, and the speaker by default for calls with video; `AudioSessionConfiguration`
  changes these. It never activates the session. It reads interruptions from
  `didBecomeInactiveNotification` and `resumptionRecommendationNotification` on iOS 27, and
  from `interruptionNotification` before, and passes them and media services resets to the SDK.
  Its `routes`, an observable `AudioRoutes`, list the `AudioRoute`s that calls can use and the
  current one, and `selectRoute(_:)` picks one.
- `VoIPCore` adds the `AudioSession` seam with `AudioSessionEvent`, `AudioInterruptionReason`
  and `AudioSessionError`, and `VoIPClient.start` takes `audio`. When the system interrupts
  active audio, the SDK stops the media and sends `CallEvent.audioInterrupted(_:)`. After a media
  services reset it sends `CallEvent.mediaServicesReset` and configures the session again. Once
  the interruption ends, or after the reset, a call that takes part and isn't on hold ends with
  `CallFailure.audioRecoveryTimedOut` unless the system activates audio within
  `Deadlines.audioRecovery` (5 seconds). A call whose audio session can't be configured ends with
  `CallFailure.audioSession`, or a join returns to its call preview. `CallMedia.deactivate()`
  now follows `activate()` once per activation. Switches over `CallEvent` and `CallFailure` need
  the new cases. See [ADR 0007](docs/adr/0007-sdk-configures-audio-session.md).
- `VoIPTesting` adds `FakeAudioSession`.
- The CocoaPods spec ships the call core as subspecs that mirror the Swift package's products:
  `Core`, `Audio`, `LiveCommunicationKit`, `PushKit`, `Simulator` and `Testing`.
  CocoaPods builds them into the one `IosVoipSDK` module, so code that uses them imports
  `IosVoipSDK`. `pod 'IosVoipSDK'` without a subspec installs `Core`, `LiveCommunicationKit` and
  `PushKit`.
- `Examples/CallExample` is a SwiftUI app that starts `VoIPClient` with the LiveCommunicationKit
  adapter, the PushKit source and the audio session adapter, shows the VoIP push token and the
  audio routes, and reports, answers, mutes and ends a call, with `CallMedia` as a stub. CI
  builds it for the simulator and for devices.
- `VoIPClient.confirmNotPlaced(_:)` tells the SDK that the app couldn't place a call it was
  asked to start or join, after `CallEvent.startRequested(_:)` or `joinRequested(_:)`. The SDK
  fails the start or join in the calling framework at once, without waiting for
  `Deadlines.placement`: an outgoing call ends with `CallFailure.notPlaced`, and a call being
  joined returns to its call preview. An app that ended such a call as a server failure, with
  `receive(.failed, for:eventID:)`, calls `confirmNotPlaced(_:)` instead.

### Changed

- `cksim` is a Swift command-line tool, built from the package's `cksim` product, and no longer
  needs Python. Its commands and options are the same, and shared options may still come before
  the command. Its JSON output sorts keys, and a usage error now exits with status 64. Build the
  standalone runtime with `node tools/build-runtime.ts <output>` (Node.js 24), which replaces
  `scripts/build-runtime.sh`; `CKSIM_BUILD_ARCHS=arm64` becomes `--archs arm64`. The Inspector
  is built with `node tools/build-inspector.ts <output>`.

### Breaking changes

- The old core is removed: the `VoIPSDK` product and its `ConversationClient`,
  `ConversationHandler`, `VoIPApplication`, `PushService`, `PushWire`, `MediaAdapter`,
  `SimulatorSupport`, audio routes, `DialRequest` and `VoIPSystemEntryPoints`, together with
  the Expo module, its config plugin and npm package, the `Integrations/LiveKit` media adapter
  and the Expo example. The call core replaces them. React Native and Expo apps use
  [expo-callkit-telecom](https://github.com/relayphone/expo-callkit-telecom) v2, whose iOS module
  runs on the call core. `pod 'IosVoipSDK'` without a subspec now installs `Core`,
  `LiveCommunicationKit` and `PushKit` instead of the `ExpoModule` subspec, which no longer
  exists.

  The call core keeps each call's state by its `CallID` and performs the user's actions itself,
  then tells the app, so there are no action handlers to register. Only starting or joining a
  call waits for the app, which places it and then calls `confirmPlaced(_:)`, or
  `confirmNotPlaced(_:)` when it can't. Migrate as follows:

  | Old core | Call core |
  | --- | --- |
  | `VoIPApplication.start(configuration:mediaAdapter:audioPolicy:)`, `startFromBundle(_:mediaAdapter:audioPolicy:)` | `VoIPClient.start(framework:media:push:audio:configuration:clock:)` with `LiveCommunicationKitAdapter()` and `PushKitSource()` |
  | `ConversationClient.Configuration` | `VoIPConfiguration`: `maximumConversationGroups` becomes `maximumCalls`, `ringtoneName` becomes `ringtoneSound`, `includesConversationInRecents` becomes `includesCallsInRecents` |
  | `ConversationSnapshot`, `snapshots`, `observeState(_:)` | `Call` and `VoIPClient.calls`, which SwiftUI and Observation track |
  | `observeEvents(_:)`, `ConversationEventContext` | `VoIPClient.events()` and `CallEvent` |
  | `ConversationHandler` and `setConversationHandler(_:)` | `CallEvent.performed(_:_:)` after the SDK performs an action; `CallEvent.startRequested(_:)` and `joinRequested(_:)`, then `confirmPlaced(_:)` or `confirmNotPlaced(_:)` |
  | `startConversation(to:video:metadata:)` | `request(.start(OutgoingCall(id:parties:hasVideo:metadata:)))` |
  | `joinConversation(_:)`, `endConversation(_:)`, `setMuted(_:_:)`, `setHeld(_:_:)`, `playTones(_:_:)` | `request(_:)` with `.answer(_:)` (or `.join(_:)` from a call preview), `.end(_:)`, `.mute(_:muted:)`, `.hold(_:onHold:)` and `.playTones(_:digits:)` |
  | `reportIncomingConversation(_:source:)` with `IncomingCallPayload` | `report(_:)` with `IncomingCall`, which returns a `PresentationOutcome` |
  | `receiveCallEnded(_:)`, `reportConversation(_:report:)` | `receive(_:for:eventID:)` with a `ServerEvent` |
  | `Caller`, `Participant` | `Party` with one or more `Handle`s; phone numbers must be E.164 |
  | `ServerCallID` and the conversation `UUID` | `CallID`; the SDK derives the per-device UUID and never exposes it |
  | `PushService`, `observeToken(_:)` | `PushKitSource` and `tokens()` |
  | `PushWire`, `PushService.receiveRemoteMessage(_:)` | `VoIPPush(defaultFormat:)`, or a decoder passed to `PushKitSource(decode:)`; apply a push from another channel with `report(_:)` or `receive(_:for:eventID:)` |
  | `JSONValue` metadata | `[String: JSONValue]` metadata, which is never `nil`; `int(_:)` and `double(_:)` become `number(_:)` |
  | `MediaAdapter`, `NoMediaAdapter`, `Integrations/LiveKit` | Your own `CallMedia` |
  | `observeAudioRoutes(_:)`, `selectAudioRoute(_:)`, `AudioRoutesSnapshot` | `AudioSessionAdapter.routes` and `selectRoute(_:)` in `VoIPAudio` |
  | `AudioActivationPolicy` | `Deadlines.audioActivation` and `audioRecovery` |
  | `SimulatorSupport.activateIfNeeded()` | `VoIPSimulator.activate()` |
  | `pod 'IosVoipSDK'` (`ExpoModule`) and `import IosVoipSDK` | The `Core`, `Audio`, `LiveCommunicationKit`, `PushKit` and `Simulator` subspecs, still imported as `IosVoipSDK` |
  | The Expo module from `github:relayphone/ios-voip-sdk` | expo-callkit-telecom v2 |

  The call core doesn't yet handle `tel:` URLs and `INStartCallIntent`s, or donate calls to Siri
  and Recents. Keep doing these in the app until it does.

- The `VoIPCallKit` library, its `CallKitAdapter` and the `CallKit` CocoaPods subspec are
  removed: LiveCommunicationKit is the SDK's only calling framework. Apps that used them depend
  on `VoIPLiveCommunicationKit`, or the `LiveCommunicationKit` subspec, and start the client with
  `LiveCommunicationKitAdapter()`; the rest of the API is unchanged. A Focus that doesn't allow
  the app now filters its calls even from people the Focus allows, and the SDK reports them as
  filtered calls. See [ADR 0002](docs/adr/0002-one-calling-framework-per-build.md).

- The `VoIPSDKTesting` product is now `VoIPTesting`. Depend on
  `.product(name: "VoIPTesting", package: "ios-voip-sdk")` and `import VoIPTesting`;
  `TestClock` is unchanged.

- The SDK now requires iOS 26, macOS 26 for host tests, and Swift tools 6.4
  (Xcode 27.1) in the Swift 6 language mode. The Swift package, the CocoaPods
  spec and the example app declare iOS 26. Raise your app's deployment target.

- Inspector controls now validate complete runtime responses before awaiting
  journal confirmation. Custom bridges must return the existing runtime identity,
  UUID request/action/transaction identifiers and the operation's complete result
  fields, including `configured: true` for fault acknowledgements. Mismatched
  result kinds or identities are rejected; the flat version-one wire is retained.

- Runtime mailbox requests now reject parameters belonging to other controls,
  duplicate JSON fields and empty fault updates. Custom clients must provide
  ordinary integer tokens for integer fields and distinct UUIDs for multi-call
  controls. Push integers outside the signed/unsigned 64-bit range must be strings;
  floating values must fit a finite Double without underflow. Requests with a valid current
  identity and invalid parameters receive a rejection response; ambiguous or
  foreign identities are discarded. The CLI keeps the existing flat v1 format.

- The Inspector now decodes the same validated session model as the runtime.
  Custom session fixtures must include `controlTransport: "directory-watch-v1"`,
  schema version 1, a positive process ID, nonempty bundle/profile names and a
  run ID of 1–64 ASCII letters, digits, underscores or hyphens. Rebuild the
  Inspector together with the runtime when updating custom integrations.

- Simulator runtime packages no longer include `cksim-notify`, and sessions no
  longer publish a `notification` key. Controls use `directory-watch-v1`; rebuild
  runtime packages and relaunch apps before using the updated CLI with older
  runtime sessions.
