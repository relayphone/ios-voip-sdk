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

**Proposed diagnostics:** `providerOwnershipLost` is a process-wide event with
an empty payload. It reports a newly observed competing provider through the
ordinary event stream. Coverage is best effort: the monitor observes provider
creation through an already-loaded system class. It never loads CallKit, and
unavailable coverage produces a diagnostic without inventing ownership loss.
Providers created before installation and unsupported creation paths can escape
observation. This is not a guarantee of detecting every action-routing change.

Debug builds enable monitoring by default. Release builds exclude its
implementation unless explicitly compiled in, and configuration defaults off.
SwiftPM consumers can compile support with the `ProviderOwnershipDiagnostics`
package trait (Swift tools 6.1), then set
`ConversationClient.Configuration.providerOwnershipMonitoring` to `true`.
Expo consumers set the config plugin's `providerOwnershipMonitoring: true`;
prebuild writes both the native configuration and the CocoaPods compile flag.
A bare pod consumer can set the `ios-voip-sdk.providerOwnershipMonitoring`
Podfile property to the string `"true"` and enable the native configuration.
Setting only the runtime configuration in an excluded Release build logs that
support is unavailable. Once installed, process-wide creation hooks remain for
the process lifetime.
