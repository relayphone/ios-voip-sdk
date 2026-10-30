# SDK process ownership

Create the SDK through `VoIPApplication.start(...)`, or its `startFromBundle`
convenience, and read `.client` from the returned owner. Repeated identical
configuration reuses the process owner; conflicting configuration throws
`VoIPStartupError.alreadyConfigured` before a second manager is constructed.

Link one SDK product per process: either the Swift package or the Expo pod.

The complete application and client are published before one-shot launch setup,
so a reentrant start observes the same owner.
