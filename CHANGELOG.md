# Changelog

Changes not yet released are recorded below. Public API changes include migration guidance.

## Unreleased

### Added

- The `VoIPCore` library holds the values of the new call core: `Call`,
  `CallID`, `Handle` (phone numbers must be E.164), `Party`, `CallStatus` with
  `PreviewReason` and `EndReason`, `Action`, `ServerEvent`, `PresentationPolicy`,
  `CallEvent` and `VoIPConfiguration` with `Deadlines`. It has no system framework dependencies and
  doesn't present calls yet. The existing `VoIPSDK` product is unchanged.

- `VoIPClient` runs the call core on the `VoIPActor` global actor. Start it once with
  `start(framework:media:push:configuration:clock:)`, observe `calls` and `isAudioActive`,
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

### Breaking changes

- The `VoIPSDKTesting` product is now `VoIPTesting`. Depend on
  `.product(name: "VoIPTesting", package: "ios-voip-sdk")` and `import VoIPTesting`;
  `TestClock` is unchanged.

- The SDK now requires iOS 26, macOS 26 for host tests, and Swift tools 6.4
  (Xcode 27.1) in the Swift 6 language mode. The Swift package, the CocoaPods
  spec and the example app declare iOS 26. Raise your app's deployment target;
  Expo apps set it through `expo-build-properties`.

- `Participant.avatarUrl` is removed from Swift and TypeScript. The SDK never
  read or displayed it; keep avatar URLs in your own contact model.

- Merging is removed. `ConversationClient.mergeConversations(_:_:)`, the Expo
  `mergeConversations` function, `ConversationCapabilities.merge`, the `merge`
  and `unmerge` action kinds and `ConversationActionError.cannotMergeSameConversation`
  no longer exist. Conversations no longer advertise merging to the system, and a
  merge or unmerge action that still arrives fails instead of being fulfilled:
  the SDK cannot mix media, so fulfilling one would report a conference that does
  not exist. Hold and mute are unchanged.

- The process-wide duplicate linkage claim is removed, together with
  `VoIPStartupError.duplicateSDKLinkage` and the Expo `duplicate_sdk_linkage`
  rejection code. Link either the Swift package or the Expo pod in a process,
  not both. Remove switches over the deleted case and code.

- The provider ownership monitor is removed. Delete uses of
  `ConversationClient.Configuration.providerOwnershipMonitoring` and
  `defaultProviderOwnershipMonitoring`, the `ProviderOwnershipDiagnostics`
  package trait, the `ios-voip-sdk.providerOwnershipMonitoring` Podfile property
  and the config plugin's `providerOwnershipMonitoring` option, which is now
  rejected as unsupported. The `providerOwnershipLost` event no longer exists in
  Swift or TypeScript. Its best-effort coverage could not detect every competing
  provider, so it could not be relied on.

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

- `IncomingCallPayload` and `CallEndedPayload` now spell their Swift identity
  properties and initializer labels `eventID` and `serverCallID`. The server ID
  uses `ServerCallID`, including `ConversationEventContext.serverCallID`.
  Restore a backend string with `ServerCallID(rawValue:)` and use `id.rawValue`
  when a string is needed. JSON and Expo retain their existing string values
  and keys (`eventId`/`serverCallId` for transport payloads). Existing identity
  validation, deduplication and termination behavior are unchanged.

- `AudioRoute.id`, the route initializer and `ConversationClient.selectAudioRoute(_:)`
  now use `AudioRoute.ID`. Pass an observed route's `id` directly, or restore a
  serialized ID with `AudioRoute.ID(rawValue:)`; use `id.rawValue` when a string is
  needed. Codable and Expo keep their existing string IDs and snapshot shape.
  Route availability, audio authorization and native selection errors are unchanged.

- The Inspector now decodes the same validated session model as the runtime.
  Custom session fixtures must include `controlTransport: "directory-watch-v1"`,
  schema version 1, a positive process ID, nonempty bundle/profile names and a
  run ID of 1–64 ASCII letters, digits, underscores or hyphens. Rebuild the
  Inspector together with the runtime when updating custom integrations.

- `JSONValue.number(Double)` is now `int(Int64)` or `double(Double)`. Update
  constructors and switches; signed 64-bit integers in metadata retain their
  exact value instead of passing through floating point. JavaScript consumers
  still use JavaScript numbers and their existing precision limits.
- `IncomingCallPayload.startedAt` is now `Date?`. Supply an instant from Swift;
  Codable and Expo continue to use RFC3339 strings, normalized to UTC with
  milliseconds when encoded. Invalid optional timestamps remain absent.
- Push and foreground invitation decoding now share their Codable validation.
  Unknown or receiver-local `callEnded` reasons are rejected instead of being
  silently converted to `remoteEnded`; an absent reason still defaults to
  `remoteEnded`. Required malformed pushes retain their incoming-report fallback.
- Info.plist configuration uses typed property-list decoding. Boolean fields
  require plist booleans, and conversation limits must be positive integers;
  the full native `Int` range is accepted without a floating-point conversion.

- Conversation action/reporting and application startup APIs now use typed throws. Replace catches of
  `ConversationClientError` with the error type for the API you call:
  `VoIPStartupError` for application startup and bundle configuration,
  `ConversationActionError` for outgoing/action requests,
  `IncomingConversationError` for incoming reports, and
  `ConversationReportError` for backend state reports. `PushService.start()`
  throws `PushRegistrationError`; application startup wraps it in
  `VoIPStartupError.pushRegistration`.
  The former `invalidPayload` action failure is now `invalidParticipant`, while
  invalid updated members use `ConversationReportError.invalidMembers`.
  The former `unsupported` failures become `cannotMergeSameConversation` for
  self-merges and `unsupportedEndReason` for backend termination reports.
  A local-end report wraps request failures in `ConversationReportError.action`.
  A pending incoming report interrupted by manager reset now throws the public
  `IncomingConversationError.providerReset`. An unowned duplicate UUID throws
  `alreadyReported`; known owned duplicates still succeed. System cancellation
  maps to `cancelled`. Other native failures expose `systemFailure(domain:code:)`
  instead of leaking an `NSError`, internal error or its user info. Switch on
  these cases instead of downcasting errors from the platform.
  Expo keeps its existing rejection code strings and generic system-failure
  messages; callers using `ConversationErrorCode` need no type migration.

- Simulator runtime packages no longer include `cksim-notify`, and sessions no
  longer publish a `notification` key. Controls use `directory-watch-v1`; rebuild
  runtime packages and relaunch apps before using the updated CLI with older
  runtime sessions.

- `ConversationClient` and `PushService` are Swift classes and no longer inherit
  from `NSObject` or conform to the platform delegate protocols. Native callbacks
  are private implementation details. Use conversation actions and registered
  handlers instead of calling `conversationManager` methods directly. Observe
  `PushService.tokenState` through `observeToken(_:)` instead of injecting push
  tokens or calling the native VoIP push callback. Remote-message forwarding
  through `receiveRemoteMessage(_:)` remains available.
