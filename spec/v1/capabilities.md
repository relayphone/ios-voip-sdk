# Capability availability

[The catalog](../capabilities.json) records platform conditions for version 1. Each feature has
one row with separate `ios` and `android` condition lists. Android conditions may narrow the
actual backend to `legacy` or `transactional` and set inclusive API bounds. The default backend
and an explicit compatibility override can choose different paths on the same API level.
iOS has one condition per feature. Android conditions have disjoint scopes.
A row with `requires` describes evidence and
prerequisites an implementation must satisfy. A row with `unavailable` gives a known blocker.
Absent coverage leaves behavior unknown. The catalog defines acceptance criteria for the
[platform paths](../../docs/architecture.md#system-and-media-adapters) in the accepted design.

The runtime publishes `{feature, availability}`. `available` means the implemented and qualified
adapter can attempt the feature under the current call, policy, permission and provider conditions.
An attempt can still fail. `unavailable(reason)` preserves the known blocker, such as
`unsupportedPlatform`, `requiresMediaProvider` or `unqualified`. Use `unknown` for missing runtime
evidence and re-evaluate when prerequisites change. If the capability check rejects a v0 action
as unsupported, return `unsupported(feature)` before calling its effect port. Lifecycle and
permission checks retain their own typed errors.

Qualify capability behavior per SDK build, OS/API, backend, device or emulator profile, and evidence
kind. A source description or a successful request acknowledgement alone leaves applied behavior
unqualified. Android system-initiated video and app or service video requests have separate
conditions. Android full-screen intent applies to notifications and can be unavailable while
ordinary presentation works. The `push` capability covers adapter availability. Consult push
health for registration and delivery observations.
