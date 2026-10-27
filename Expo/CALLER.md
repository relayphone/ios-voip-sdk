# Caller identity

Incoming reports and pushes require a typed `Caller`:

```ts
const caller: Caller = {
  handleType: 'phone',
  value: '+1 (202) 555-0123',
  displayName: 'Alice',
  hostContactID: 'host-contact-42',
};
```

Native validation normalizes that number to `+12025550123`. Supply an international `+` country code: the SDK does not guess a region, accept extensions, or infer a phone/email type from a generic value. Email and generic handles retain their case. Empty values/names, controls and malformed phone/email handles reject. Swift initialization and Codable/Expo decoding use the same validation. Pushes with invalid caller data retain the existing required-report fallback policy.

The `incomingCall` envelope, event deduplication and `callEnded` format stay the same. Its caller child now requires `handleType`, `value` and `displayName`; the earlier participant-shaped caller (`id`, `phoneNumber`, `email`) must migrate. `Participant` remains the outgoing/member model.

LCK receives the selected handle type, normalized value and display name; its Recents entry uses that same reported identity when `includesConversationInRecents` is enabled. `hostContactID` is an opaque identifier in the host's contact store. It is preserved in the Caller payload and `INPerson.customIdentifier`; member IDs use the calling address so later metadata-only reports preserve the system handle, with no address-book lookup or Contacts permission.

Swift hosts can build `caller.makeCallInteraction(video:direction:)` or explicitly `try await caller.donateCall(video:direction:)` after a real interaction. These use the same identity in `INPerson` and `INStartCallIntent`. Parsing a push does not donate an interaction. Donation is a system request, not proof that iOS will display a suggestion. The current Expo API exposes the typed incoming caller; these native donation helpers are not yet Expo commands.

Focus breakthrough policy remains deferred to RFC #149. Supplying a caller does not bypass Focus.
