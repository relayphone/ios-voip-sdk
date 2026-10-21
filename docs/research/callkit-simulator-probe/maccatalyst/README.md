# Genuine CallKit on macOS (Mac Catalyst), October 21, 2026

**Question:** can genuine CallKit on a Mac act as a second reference for the simulator runtime, next to the iPhone?

## SDK availability (macOS 27.0 SDK)

| Framework | Native macOS (AppKit) | Mac Catalyst |
| --- | --- | --- |
| CallKit: `CXProvider`, `CXCallController`, `CXCallObserver` | `API_UNAVAILABLE(macos)` | Available (13.0+) |
| LiveCommunicationKit | Every type is `@available(macOS, unavailable)` | Available (17.4+) |

Apple's own documentation lists CallKit and LiveCommunicationKit for **Mac Catalyst only**, not native macOS. A native AppKit app, including React Native for macOS, can use neither. `callservicesd` does run on macOS, from `TelephonyUtilities.framework`.

## Measurement

The probe is the same `../main.swift` and `../providers.swift`, built as Mac Catalyst. It ran on macOS 27.0.1 (26A434), sandboxed, with scenario `PROBE_MODE=providers PROBE_PROVIDERS=single`.

**How it was built:**

1. Build with `xcodebuild -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO`.
2. Sign the app in one of two ways:
   - ad hoc: `codesign --sign - --entitlements mac.entitlements`;
   - with the team's Apple Development identity (TeamIdentifier 85A9MS6428), still without a provisioning profile.

**Results (identical in both cases):**

| Step | Result |
| --- | --- |
| `providerDidBegin` | Arrives |
| Every `CXCallController` request | Fails with `CXErrorCodeRequestTransactionError.unentitled` (1) |
| `reportNewIncomingCall` | Fails with `CXErrorDomain` 0 (unknown) |
| Focus off, and launch through LaunchServices instead of exec | No change |

Traces: `2026-10-21-macos27-catalyst-providers-{single,single-team}.jsonl`.

**Not yet tested: a provisioned build.** It needs an `application-identifier` from a development profile, which requires this Mac to be registered in the team. A Developer ID profile is not bound to devices, so it could also serve CI runners. Until a provisioned run is measured, macOS is not a usable reference.
