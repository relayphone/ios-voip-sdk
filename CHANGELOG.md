# Changelog

Changes not yet released are recorded below. Public API changes include migration guidance.

## Unreleased

### Breaking changes

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
