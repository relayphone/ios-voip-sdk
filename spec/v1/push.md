# Push intake and health

Native PushKit and FCM adapters decode the SDK envelope `{version: 1, kind: "pushEnvelope", value}`.
The native callback supplies the trusted channel (`apnsVoip` or `fcm`). The payload carries the
v0 invitation and explicit `issuedAt` and `expiresAt` times, with an optional opaque `credentialRef`
for native lookup. Keep credentials, native tokens and native diagnostic payloads out of portable
observations. Forward unrelated FCM messages to their existing consumer. Recognized SDK messages
with an unknown version, malformed fields or invalid calendar timestamps are rejected before they
reach call state. Each adapter still owes its platform's required reporting or completion action.

Use UTC millisecond timestamps and enforce `issuedAt <= receivedAt < expiresAt` with the wall time
captured at native receipt. Require `issuedAt < expiresAt`. Use remaining validity to shorten the
incoming ring budget and use the monotonic clock for that budget. Decode and verify eligibility
before recording the `eventID`. Duplicate valid events have no new admission, ringing or
repeated-call effects, even across channels. Preserve the v0 `callID` and bounded deduplication
rules. A duplicate does not extend expiry, and a fresh event cannot replace a live call with the
same ID. Complete required native reporting without waiting for JavaScript, token upload or media.

Registration is scoped by `installationID` and channel. Generations start at 1 and persist across
launches. The first token completes the initial generation. Replacing or invalidating that token
advances the generation. Delivering the same token again for the current registration is
idempotent. A new installation gets a different ID. Match completions of explicit registration
requests to their pending attempt. `registered` means the provider supplied a current token.
`upload` independently records the service acknowledgement or failure. `tokenID` is a synthetic
or native-issued opaque identifier that does not reveal the token.

Authenticate upload for the installation, channel, token and generation. The service atomically
accepts a newer generation, treats an identical generation and token as an idempotent retry, and refuses older
generations or a conflicting token at the same generation. Invalidation fences older generations
at the service once recorded there. The client applies an acknowledgement or failure only to the
current installation, channel, generation and token. A stale response that matches the current
request is `serviceRejected`. An already acknowledged generation is not
downgraded by a late failed retry. Rotation clears outstanding acknowledgement and delivery
evidence for the replaced generation. The service can learn a rotation only when the new state
reaches it. A service acknowledgement confirms registration on the service.

`PushHealth` combines registration, presentation readiness, observed connectivity and delivery
evidence. Keep each independent: the ability to present, service acknowledgement, provider
acceptance and native device receipt describe different boundaries. `observed` requires a
native device receipt or matched probe receipt for the same installation, channel and current
registered generation. Correlate provider callbacks using trusted delivery metadata or a probe's
recorded target. The local token at receipt time cannot establish which generation was addressed.
`degraded` describes a correlated probe that timed out. A result only
describes that observation at its timestamp. A missing probe, missing receipt, stale evidence or
unknown generation leaves delivery `unknown`. Report observed offline connectivity separately.
Unobserved provider backoff and the cause of a missing delivery remain unknown.

The token-rotation journey drives `pushTokenChanged` and `pushUploadCompleted` on fake ports for
a fresh installation. Supply an old acknowledgement after the new token arrives and before its
upload completes. A driver observes real registration and health outputs from the core for each
assertion. An FCM scope in this fake does not qualify the Android transport or cloud delivery.
