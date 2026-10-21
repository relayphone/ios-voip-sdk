# Genuine CallKit on macOS (Mac Catalyst), October 21, 2026

**Question:** can genuine CallKit on a Mac act as a second reference for the simulator runtime, next to the iPhone?

## SDK availability (macOS 27.0 SDK)

| Framework | Native macOS (AppKit) | Mac Catalyst |
| --- | --- | --- |
| CallKit: `CXProvider`, `CXCallController`, `CXCallObserver` | `API_UNAVAILABLE(macos)` | Available (13.0+) |
| LiveCommunicationKit | Every type is `@available(macOS, unavailable)` | Available (17.4+) |

Apple's own documentation lists CallKit and LiveCommunicationKit for **Mac Catalyst only**, not native macOS. A native AppKit app, including React Native for macOS, can use neither. `callservicesd` does run on macOS, from `TelephonyUtilities.framework`.

## Measurement

The probe is the same `../main.swift` and `../providers.swift`, built as a sandboxed Mac Catalyst app, on macOS 27.0.1 (26A434).

### Rejected until LaunchServices knows the app

The first runs were built ad hoc, then with the team identity and no profile, then with a development provisioning profile (this Mac is registered in team 85A9MS6428). Every outgoing request failed `unentitled` (1), and every incoming report failed with `CXErrorDomain` 0.

`callservicesd` explains why (`2026-10-21-callservicesd-unregistered.log`):

- It looks up the app's LaunchServices record and gets -10814 (application not found).
- It then treats the app as having no VoIP background mode and denies creation of a `CXXPCCallSource`.

The app ran from a temporary build folder, which LaunchServices does not register. **Copying it to `~/Applications` and running `lsregister -f` fixes it.** Entitlements and the platform were not the problem.

### Once the app is registered

| Behavior | Mac Catalyst | iPhone 13 (D13/D14) |
| --- | --- | --- |
| Outgoing start | Allowed only with user intent (see the note below). Delivered to the provider, which connects. | Allowed when the probe is launched by `devicectl` |
| App mute | One `CXSetMutedCallAction`, **no system echo** | App mute plus a system echo 10–17 ms later |
| Ending a muted call | A system unmute arrives after the end, then **times out at its 5 s deadline** (5.3 s) | Same (5.0–5.9 s) |
| Audio callbacks after start | **No** `didActivate` or `didDeactivate` | `didActivate`, then `didDeactivate` |
| Invalidating the newest provider | Requests fail with `unknownCallProvider` (2) after about **11.7 s**, with no fallback | Same, about 10.6 s |
| Reporting from the invalidated provider | Revives it (`providerDidBegin`) | Same |
| Incoming report while a Focus is active | Filtered with `filteredByDoNotDisturb` (3) | Same (the phone's Focus) |

**Note on user intent.** `callservicesd` rejects outgoing starts whose user intent it can't validate, with `invalidAction` (6) ("user intent could not be validated"). In `single`, a start 1.3 s after launching with `open` was accepted. In `ab` and `late`, starts at 2.2 s or later were rejected. An unattended reference run therefore needs a UI-driven start, such as an XCUITest click.

**Incoming calls are not yet measured.** A Focus on this Mac still resolves to `silence`.

**Conclusion.** Genuine CallKit works in a registered Mac Catalyst app, so the Mac can serve as an automated *partial* reference for provider and action semantics. It differs from the iPhone in user-intent gating, mute echoes and audio activation, so the iPhone remains the ground truth.

Traces:

- `2026-10-21-macos27-catalyst-providers-*.jsonl`;
- `callservicesd` excerpts: `2026-10-21-callservicesd-*.log`.
