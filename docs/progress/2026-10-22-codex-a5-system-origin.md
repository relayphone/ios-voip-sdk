# A5 system-origin acceptance preparation

**Proposed:** seven externally controlled SDK journeys are implemented in the
example, `run_sdk_system.py` and the separate `sdk_system_conformance.py` gate.
The recipe and evidence contract are in [sdk-system-acceptance.md](../sdk-system-acceptance.md).
Existing M1 handler-origin checks remain unchanged.

**Measured, host only:** before the A5 edit, M0/M1/contracts controls passed
7/9/7 groups. After adding the new control seams, the same groups still pass.
The shipping CLI passes 20 synthetic mailbox controls and 21 external-launch
subprocess controls. The actual Foundation envelope consumer passes 20 filesystem
assertions. Python/shell/Swift syntax and TypeScript/Prettier checks pass.
The dedicated checker passes 62 logical system-case and filesystem evidence
controls, including legacy M1's app-origin restriction. None of these results is
a simulator measurement.

**Proposed selected-provider fault boundary:** reset requires no pending runtime
action for that provider. The mute-echo case proves a pending-action reset is
refused; a separate case checks successful reset of a connected call with no
pending action. This is not R3 invalidation of an older provider.

**Source integration, not native acceptance:** A0's bounded PushKit queue and
report-entry rule, A2's actual LCK deadlines, A3's pending app-mute echo fix and
A8's explicit connected semantics are integrated from `f65d171`. The evidence path
inventory retains both the system-control/D5 inputs and the device-release inputs.
Audio/ownership/contracts integration from `47834d5` keeps both system and media
fixtures. The example uses `ExpoMediaSupport` to start the sole `VoIPApplication`
owner, the system and M2 gates check that owner, and system hooks preserve typed
event context. Global callbacks never acquire an invented conversation identifier.
The focused incoming-push build also includes the staged-envelope consumer.

**Pending:** integrate the corrected A0.1 incoming intake before any final
integrated app acceptance. Then build once, capture all seven cases on one assigned throwaway simulator,
replay the strict source/product-bound gates, and record the actual receipts.
No A5 simulator, device, APNs/key, push, PR or publication action has occurred.
The initial native pass may expose framework behavior; retain any red capture
and do not repair logs, fabricate SDK state or weaken case checks.
