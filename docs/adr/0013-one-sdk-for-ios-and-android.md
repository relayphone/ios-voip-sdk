---
status: accepted
---
# One SDK for iOS and Android

## Context

Calls need the same identity, actions and media lifecycle on every device. Separate repositories
split these contracts across releases; shared TypeScript declarations cannot enforce them.
Build on the existing Swift SDK, bindings and simulator, while designing Android afresh around
Core-Telecom's execution limits and notification responsibilities.

## Decision

This repository becomes the single VoIP SDK for iOS and Android. It contains:

- One domain specification and conformance suite for Swift and Kotlin. The SDK owns state;
  system frameworks are adapters.
- Existing LiveCommunicationKit/PushKit libraries and a fresh Kotlin/Core-Telecom Android SDK
  with a pure JVM core.
- Media through `CallMedia`, with optional LiveKit and WebRTC integrations.
- One TypeScript API and one Expo module for both platforms, released with the native SDKs.
- An implementation of Exact's `@exact/calls` on both platforms, using the same native cores.
- One test kit for system fakes, simulator/emulator runtimes and independent media observations.

Design proceeds from the domain and native cores to the bindings. Android is written afresh;
expo-callkit-telecom v2 is a capability reference, not a source to port. Parity or better must
be demonstrated end to end before that library is retired.

[The accepted architecture](../architecture.md) specifies the boundaries, intended APIs,
requirements, tests and milestones, refined by the shared specification. Bounded native answer
authorization refines [ADR 0003](0003-native-actions-app-informed.md), with an optional built-in
HTTP authority for apps without custom native code. Deferred outgoing media changes the Swift
preparation order too. These are implementation contracts, not claims of shipped capabilities.

## Existing decisions

This supersedes [ADR 0012](0012-react-native-package.md)'s separate Android composition and iOS-only
package scope. Keep its version lockstep, source packaging, native actions and no dead surface.
The domain follows the SDK's model rather than LiveCommunicationKit's conversation objects.

[ADRs 0001](0001-sdk-owns-call-state.md) and [0004](0004-call-id-across-devices.md) apply to both
platforms: keep the canonical app ID; bind remote aliases with `bindRemote`, never rename a call.
Platform UUIDs stay internal. Use LiveCommunicationKit on iOS and Core-Telecom on Android;
Apple presentation, Focus, Live Activity, audio and push decisions retain their platform scope.

## Names and distribution

Keep the Swift package at the repository root and keep its module names. Keep the repository
and npm package names throughout implementation. Only the final migration renames the
repository to `relayphone/voip-sdk` and npm package to `@relayphone/voip-sdk`.

New Android packages may use `com.relayphone.voip` immediately, with
`com.relayphone:voip-sdk` as the public Maven entry point. Each release initially distributes
a complete Maven repository archive alongside the npm tarball; stable releases later use
Maven Central. Native libraries, bindings and archives share one version, and the Expo tarball
ships its version-matched native sources.

## Considered options

- Keep two repositories and compose their packages: retains separate semantics and release gates.
- Port the existing Android binding: carries its API and implementation constraints into a new core.
- Share a Kotlin Multiplatform or C++ engine: introduces another toolchain and changes the Swift
  integration before proving the domain. Share the specification and journeys first.

## Consequences

Common capabilities have one meaning, typed failures and tests on both platforms; platform-only
features stay explicit. Native apps need neither Expo nor Exact. One version identifies compatible
libraries, bindings and tests. Shared types alone cannot replace behavioral conformance.
