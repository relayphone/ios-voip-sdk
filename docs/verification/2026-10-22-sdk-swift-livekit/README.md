# Genuine Swift LiveKit consumer compilation

Measured locally: the actual optional `LiveKitMediaAdapter.swift` compiled without
modification in a SwiftPM consumer against **LiveKit Swift 2.18.0**, Release
`iphoneos`/arm64, with an iOS 17.4 deployment target. No app or simulator was
launched, and no device, signaling or audio engine journey was exercised.

The consumer resolves the real upstream package, with WebRTC 150.7871.03
(normalized by SwiftPM as 150.7871.3) and UniFFI 0.1.9. It uses the SDK's exact
tracked source at `47834d58ad2a086c29d23066c4217d7eb6563fd7`, plus the single
route-notification isolation correction in `19f37c98816ebf5d2937af1b881ae4f07d457f02`.
A frozen source snapshot protects this measurement from concurrent integration
changes. The adapter copy matches the repository bytes exactly.
All 42 final SDK input files also match integrated commit
`1f1bc98e9f4803c86ed6bea460683099d644973e` byte for byte; this is a source-equivalence
check, without another dependency build.

The initial unmodified build exited 65 because `SystemAudioSession` passed an
unused, non-Sendable `Notification` into MainActor isolation. Removing that
payload preserves the existing main-queue route-refresh signal. The follow-up
build exited 0. Both commands and raw log hashes are retained in `receipt.json`;
the original failure has not been relabeled or erased. Independent review cleared
the narrow correction before its commit.

The receipt binds all 42 SDK source files, the consumer manifest/source, exact
package revisions, eight genuine build products and the adapter object. Defined
adapter methods and references to the genuine LiveKit manager plus the shared SDK
audio queue confirm that the iOS adapter body compiled. Binary-product hashes
include the compiled LiveKit object/module and its real WebRTC/UniFFI frameworks.
No contract facade participated in this build. SwiftPM retains each dependency's
language mode; in particular, no global Swift 6 override is applied to UniFFI.

Two existing `ConversationClient.manager` region-isolation warnings remain in the
successful Release build and are listed in the receipt. This result qualifies
this pinned compilation pair; it does not qualify app linking, media behavior,
real activation/interruption delivery, additional dependency versions or CI.

A separate read-only check of all 14 retained Release arm64 Mach-O products found
no direct CallKit load command, CallKit `LC_LINKER_OPTION` autolink entry or
unresolved CX/CallKit symbol. `linkage-receipt.json` binds 42 inspection commands,
20 direct load-library entries and 554 autolink entries, including the genuine
WebRTC/UniFFI frameworks and both consumer objects. This inspects those products
with the default package traits; it does not qualify final app linkage,
linker-added settings, other dependencies or transitive system frameworks.

The disposable consumer and raw products remain under the ignored qualification
output directory. The manifest and small consumer are embedded in the receipt.
To reproduce the full sequence, archive the recorded SDK revision and copy the
adapter bytes into the consumer. Run package resolution and the first recorded
build against that unmodified SDK snapshot. Apply the recorded single-file
correction, then repeat the same build command for the successful follow-up.
Both `-derivedDataPath` and
`-clonedSourcePackagesDirPath` should use fresh task-owned directories.
