# Changelog

## Unreleased

### Breaking changes

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
