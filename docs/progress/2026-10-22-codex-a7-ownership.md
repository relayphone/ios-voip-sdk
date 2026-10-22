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

This foundation was preparation, not complete A7 acceptance. It left adapter
identity/policy selection and the typed process-scoped ownership event for the
A4 integration below. Native journeys and fresh pod-built Release app inspection
remain pending. No simulator or device has been used for A7.
The initial plugin command could not find dependencies in this worktree; its
successful follow-up used an existing locked example dependency directory.
Neither run installed or changed dependencies.

Historical M1 notes describing
`ConversationClient.shared` and pre-creation adapter registration are superseded
by this single-entry API; those historical evidence documents remain intact.

## A4/A8 integration

**Implemented in the local correction stack:** adapter selection is atomic with
`VoIPApplication.start(mediaAdapter:audioPolicy:)`. The client retains immutable
configuration, adapter and policy; conflicting repeats throw before another
manager or adapter callback. An omitted repeat adapter preserves the selected
object. There is no separate registration step or public shared getter.

The application and client are published before the one-shot `finishLaunch`.
It installs the optional monitor's actual conflict callback and state tracking
before notifying the adapter of initial false authorization. Actual foreign
creation emits typed `providerOwnershipLost` with no invented conversation ID;
coverage diagnostics do not emit ownership loss.

**Measured host/compiler preparation:** the [integrated receipt](../verification/2026-10-22-sdk-a7-integration/host-checks.json)
binds 183 existing SDK/test inputs and 26 verification entries. It includes 14
ownership groups, 46 platform groups, 25 actual plugin groups, seven mute and ten
whole-client contract groups, thirteen TypeScript runtime controls, default and
opt-in device Release typechecks, the native contract fixture typecheck, and the
audio/compiler/gate checks. Factory, launch, emit, client, handler and media
ordering use production sources; framework edges remain explicit host facades.
The old shared acquisitions in fixtures were replaced with a named host owner
that calls the actual internal factory and `finishLaunch`.

Both independent review axes cleared the final integration after one SPEC P2:
the native duplicate-linkage error was missing from the new TypeScript union
and guard. Its positive control failed before the fix and passed afterward.
The example's duplicate main-actor category setter was removed; the SDK's
call-time preparation owns configuration, and the explicit backend connected
report remains after real join completion.

This does not complete native A7/M2 acceptance. Integrated simulator journeys,
fresh pod-built device Release inspection, physical device measurements and
hosted CI remain pending. A0.1's blocked-main report-entry redesign is separate
and unfinished; this receipt does not qualify the inherited push implementation.
