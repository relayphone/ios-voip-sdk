# SDK process ownership

**Proposed API:** start native Swift integrations with `VoIPApplication.start(...)`
(or its Info.plist convenience `startFromBundle`). Read `.client` from the returned
application. The SDK has no public `ConversationClient.shared`, `configure`, or
separate media-registration step. A repeated start requires the same configuration,
selected adapter identity and audio policy. A conflicting start throws.

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

**Proposed A4 integration:** when enabled and available, an actual newly observed foreign provider emits the
process-scoped `providerOwnershipLost` SDK event; there is no `conversationId`.
The monitor looks up an already-loaded system provider class. It never loads
CallKit or constructs a provider. An unavailable class, unsupported creation path
or failed installation logs a coverage diagnostic without inventing an ownership
loss event. This diagnostic cannot prevent D13 routing or guarantee detection on
all Apple framework versions.

The foundation provides the native conflict callback. The typed SDK event and
adapter identity/policy selection are pending integration with A4; they are not
claimed by the foundation's host evidence.

**Measured host/compiler evidence** and the limits of native qualification are
recorded in the [A7 handoff](progress/2026-10-22-codex-a7-ownership.md).
