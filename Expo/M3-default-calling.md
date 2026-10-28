# Default calling requests

The SDK delivers an outgoing destination as `dialRequest: { handle, video }`.
Your app presents the destination and decides whether to start a conversation.
Receiving a request does not create a conversation or run a signaling handler.

## Expo

Enable the calling-app entitlement in your plugin configuration:

```json
["ios-voip-sdk", { "defaultCallingApp": true }]
```

The option defaults to `false`. The plugin owns
`com.apple.developer.calling-app`: enabling the option sets it to `true`, and
disabling it removes that key. Other entitlements remain intact. The plugin also
preserves existing activity types and adds `INStartCallIntent` for call activities.
It does not add the separate default-dialer entitlement.

Subscribe through the existing public event hook:

```tsx
useConversationEvent('dialRequest', ({ handle, video }) => {
  setProposedCall({ handle, video });
});
```

Expo's application-delegate subscriber forwards `tel:` URLs and
`NSUserActivity` values carrying a resolved `INStartCallIntent`. Requests arriving
before JavaScript or during reload wait in native memory until a public
`dialRequest` listener attaches. Requests drain in arrival order to the current
bridge and remain native until a current public listener acknowledges observation; teardown from an older bridge cannot detach its replacement. The queue
is process-local and does not survive termination. Multiple mounted listeners
receive the event through the current JavaScript runtime.

The example displays the latest destination and audio/video choice. Its automated
simulator journey directly invokes the real application delegate with a fixed
`tel:` URL, then passes a real typed start-call intent through the public SDK entry
point. The public hook reports both deliveries back to the native fixture, which
requires the exact destinations, order, capabilities and zero conversations.
Evidence records destination hashes rather than phone numbers.

## Swift and custom scene delegates

`DialRequestRouter.shared.observe` receives `DialRequest` values. Retain the
returned observer ID and pass it to `removeObserver` when the consumer detaches.
A replacement observer becomes the current consumer and drains queued requests.

Forward application or scene entry points to these `@MainActor` methods:

```swift
VoIPSystemEntryPoints.handle(url: url)
VoIPSystemEntryPoints.handle(userActivity: activity)
VoIPSystemEntryPoints.handle(intent: startCallIntent)
// In scene(_:willConnectTo:options:), for cold scene delivery:
VoIPSystemEntryPoints.handle(connectionOptions: connectionOptions)
```

The URL entry point accepts a nonempty `tel:` destination and decodes percent
escapes. Authority, query, fragment and control-character payloads are rejected.
Intent delivery requires one resolved contact, or one participant in the public
callback call record when contacts are absent. Unresolved or multiple recipients
return `false` so the host can resolve them. Video capability maps to `video: true`.
Unrelated URLs and activities return `false`.

## Acceptance and device work

Direct simulator delivery covers native ingress, the Expo producer and public
JavaScript observation. It does not measure default-app selection or system
Settings/Siri dispatch. Those require the assigned device session, valid signing
and selecting the example under Settings > Apps > Default Apps > Calling. The
example's latest-request display and hashed native observation support that check.
No `telephony:` fallback runs automatically.

Apple documents the [calling-app entitlement and device requirements](https://developer.apple.com/documentation/callkit/preparing-your-app-to-be-the-default-calling-app)
and the [typed call capability](https://developer.apple.com/documentation/intents/instartcallintent/callcapability).
