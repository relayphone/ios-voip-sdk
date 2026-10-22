# A7 SDK process ownership preparation — October 22, 2026

**Proposed behavior:** [the process-ownership guide](../sdk-process-ownership.md)
describes the single launch owner, media selection and optional diagnostics.
This work applies steering A7 while preserving A0's default Release exclusions.
Native call journeys and a pod-built device Release inspection of this integrated
source remain pending; host/compiler checks do not qualify either.

## Implementation

The SDK uses a canonical Objective-C selector as an associated-object key on
`NSProcessInfo.processInfo`, under a brief synchronization block. Each linked
Swift SDK image supplies its module name and its own immutable UUID token. The
same-named Objective-C helper can be coalesced without coalescing those Swift
identities. The first SDK keeps its claim for the process lifetime; a second
linkage fails before its manager is constructed. Static duplicate symbols can
already fail loudly at link time.

`VoIPApplication.start` is the sole public manager-creation entry. The completed
client and application are published before adapter callbacks. The internal
factory claims ownership too, rather than exposing an automatic shared getter.

Provider diagnostics remain compiled out of default device Release. The explicit
SwiftPM trait requires tools 6.1; this is an intentional minimum-tools change from
6.0, with Swift language mode 6 retained. Conditional C settings on the Swift
consumer propagate the header flag to its Clang importer; a Swift `-D` or a flag
on the dependency's C target alone does not do that. Expo writes paired runtime
and CocoaPods compilation selections. Generic diagnostics and actual foreign
creation have distinct callbacks, so failed coverage cannot produce an SDK loss
event. No code loads CallKit for diagnostics.

## Measured foundation evidence and outstanding acceptance

The [source-bound host receipt](../verification/2026-10-22-sdk-a7-foundation/host-checks.json)
records eight verification commands: eight duplicate-linkage/packaging groups,
46 platform groups, 23 actual Expo plugin groups, the M0/M1 gate host controls,
four device-exclusion controls, core host controls, and actual shared Swift
source typechecks for `iphoneos` in default Release and explicitly enabled
diagnostics Release. Both independent SPEC and STANDARDS reviews cleared the
foundation against base `1f44286079b9e56bd2d7d1fcfd712b271dcd7750`.

This is preparation, not complete A7 acceptance. Adapter identity/policy
selection and the typed process-scoped ownership event still need the A4 media
ancestry. The native journeys and fresh pod-built Release app inspection remain
pending after that integration. No simulator or device has been used for A7.
The initial plugin command could not find dependencies in this worktree; its
successful follow-up used an existing locked example dependency directory.
Neither run installed or changed dependencies.

Historical M1 notes describing
`ConversationClient.shared` and pre-creation adapter registration are superseded
by this single-entry API; those historical evidence documents remain intact.
