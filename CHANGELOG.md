# Changelog

## Unreleased

### Breaking changes

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

- `ConversationClient` and `PushService` are Swift classes and no longer inherit
  from `NSObject` or conform to the platform delegate protocols. Native callbacks
  are private implementation details. Use conversation actions and registered
  handlers instead of calling `conversationManager` methods directly. Observe
  `PushService.tokenState` through `observeToken(_:)` instead of injecting push
  tokens or calling the native VoIP push callback. Remote-message forwarding
  through `receiveRemoteMessage(_:)` remains available.
