# Expo relay host checks

Run `python3 discovery/check_expo_bridge.py` from the repository. It compiles the
actual `Expo/apple/ConversationBridge.swift`, production conversation models,
handler contexts and cancellation signals, and the production token store/models
with Swift 6 and warnings as errors. It also compiles the production audio route
snapshot model and checks route replay, null route loss and observer cleanup.
The temporary executable is removed afterwards.
The JSON result binds the compiled production/test sources and checker by SHA-256;
source changes during compilation or execution fail the check.

Only the platform-owning client, push facade and launch owner are test doubles.
Their observation and handler setters provide the boundary needed to drive real
handler closures; they do not implement the relay, continuation settlement or
cancellation policy. Tests cover encoding, precise ISO dates, action success and
rejection, cancellation, handler generations, overlapping module lifetimes,
ownership transfer, stale attachments, destruction and observer cleanup. Pending
invocations have bounded waits; duplicate continuation resumes abort the executable,
and continuation-misuse diagnostics fail the check.

These are host tests. They do not compile `IosVoipSDKModule.swift` against Expo,
construct a native conversation manager, register PushKit, launch an app, or claim
simulator/device acceptance.

Measured: the included `host-receipt.json` records nine passing groups against the
integrated production relay/core from `19c3546ec7196bf140d5c99382a6e866a67cb53b`.
The first compile found a Swift continuation type-inference failure in the relay;
the production author added its explicit `CheckedContinuation<Void, any Error>`
annotation before this passing run. Temporary-copy negative controls confirmed
that removing generation checks or discarding fractional date seconds fails the
tests. Those copies were deleted; this change contains only tests and the host
checker. The source hashes identify the measured implementation even after later
source changes make this receipt historical.
