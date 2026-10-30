# SDK process ownership

**Proposed API:** create the SDK through `VoIPApplication.start(...)`, or its
`startFromBundle` convenience, and read `.client` from the returned owner.
Repeated identical configuration reuses the process owner; conflicting
configuration throws before a second manager is constructed.

The SDK claims process ownership before constructing its LCK manager. If the
Swift package and Expo pod are both linked, their distinct Swift image tokens
share one Objective-C process gate. The second SDK throws
`ConversationClientError.duplicateSDKLinkage`. Expo commands reject with
`duplicate_sdk_linkage`, which the public `isConversationCommandError` guard
recognizes. The claim remains held for the process lifetime.

The complete application and client are published before one-shot launch setup,
so a reentrant start observes the same owner.
