# SDK process ownership

**Proposed API:** start native Swift integrations with `VoIPApplication.start(...)`
(or its Info.plist convenience `startFromBundle`). Read `.client` from the returned
application. The SDK has no public `ConversationClient.shared`, `configure`, or
separate media-registration step. Pass the adapter atomically with
`VoIPApplication.start(mediaAdapter:audioPolicy:)`. A repeated start requires the
same configuration and audio policy; an explicit adapter must be the same object.
Omitting the adapter on a repeat preserves the selected instance. A conflicting
start throws before constructing another manager or notifying another adapter.

The SDK claims process ownership before constructing its LCK manager. A linked
Swift package and Expo pod cannot each create a manager: the second SDK throws
`ConversationClientError.duplicateSDKLinkage`; Expo commands reject with
`duplicate_sdk_linkage`. The claim lasts for the process lifetime. This protects
SDK creation paths; third-party providers remain subject to Apple's routing rules.

The complete application and client are published before nonblocking adapter
callbacks. An adapter can reenter start with the same arguments and receive the
same published owner. Audio preparation belongs to an actual start/join action.

## Optional foreign-provider diagnostics

Debug defaults to enabled. Device Release defaults to disabled and compiles out
the diagnostic implementation and public monitor declaration. Release diagnostics
require both a build option and `client.providerOwnershipMonitoring = true` in the
application configuration. Explicitly disabling the runtime option also disables
SDK installation in Debug.

For a SwiftPM dependency, enable the nondefault `ProviderOwnershipDiagnostics`
trait, for example `traits: ["ProviderOwnershipDiagnostics"]` on `.package(...)`.
The manifest requires Swift tools 6.1; the Swift language mode remains 6. The trait
sets the Swift compilation flag and the corresponding C/importer flag. It adds no
package dependency or linked framework.

For Expo, set the plugin's `providerOwnershipMonitoring: true`. Prebuild writes a
Boolean into `VoIPSDK` in Info.plist and a matching Podfile.properties selection.
Regenerate the iOS project and pods after changing it. Omit the option to retain
Debug defaults and keep the Release implementation excluded.

When enabled and available, an actual newly observed foreign provider emits the
process-scoped `providerOwnershipLost` SDK event; there is no `conversationId`.
The monitor looks up an already-loaded system provider class. It never loads
CallKit or constructs a provider. An unavailable class, unsupported creation path
or failed installation logs a coverage diagnostic without inventing an ownership
loss event. This diagnostic cannot prevent D13 routing or guarantee detection on
all Apple framework versions.

The typed event and atomic media selection have host/compiler integration
evidence. Native journeys and a fresh pod-built device Release inspection remain
pending; the foundation receipt records its earlier, narrower source.

**Measured host/compiler evidence** and the limits of native qualification are
recorded in the [A7 handoff](progress/2026-10-22-codex-a7-ownership.md).

## Core provenance and cache compatibility

The M2 correction stack merges the focused process-owner core through
`6051601dc725f5cb84c885513afde4d24450f9e0`. That core acceptance target deliberately
left media selection and optional Release diagnostics on the M2 stack. Its scope
reduction does not remove the M2 adapter identity/policy checks, SwiftPM trait,
paired CocoaPods/plugin options or the typed process-scoped ownership event
described above.

The core's A1 cache compatibility repair acquires the host client through the
actual internal factory and one-shot setup, with the real Swift and Foundation
Objective-C process claim. Its source-bound receipt preserves the original local
missing-shared-getter failure and all three passing cache modes separately. Those
are historical host controls with modeled LCK timing. Current merged-source
qualification, native calling and fresh pod-built device Release inspection
remain pending; the [A7 handoff](progress/2026-10-22-codex-a7-ownership.md) records
the separate receipt provenance.
