# Changelog

## Unreleased

### Breaking changes

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
