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

**Source-only forward preparation, not native acceptance:** reviewed M2 parent
`0743f14486bba8437c66c2221a3f38be5b1828d8` is normally merged into the prepared
A5 branch. The five joins preserve both system-control and incoming-report build
inputs, all six native push-entry cases and four M2 cases, the M1
backend-connection marker, and the corrected manual connection button.
The SDK client, handler, audio implementation,
application owner and deadline profile match that parent exactly. The incoming
intake correction is now present. The parent's recorded iOS 27 audio-lifecycle
native red remains unresolved; this forward changes no audio policy or gate.

**Measured affected host checks only:** the seven-case checker passes 62
synthetic controls; CLI mailbox, external launch and Foundation consumption pass
20, 21 and 20 controls respectively. M0/M1/native-contract/M2 gate controls pass
9/17/23/27 groups. SDK/example TypeScript, JS controls, syntax and formatting
checks pass. A broader actionlint invocation rejects the unchanged M2 workflow's
custom `xcode-27` runner label; that preparation result is retained, and the
changed M0 workflow passes its scoped lint. The frozen local receipts remain in
`discovery/out/a5-m2-forward-0743/`; these are host results, not call journeys.

**Pending:** finish independent review of this forward, then build once and
capture all seven cases on one assigned throwaway simulator,
replay the strict source/product-bound gates, and record the actual receipts.
No A5 simulator, device, APNs/key, push, PR or publication action has occurred.
The initial native pass may expose framework behavior; retain any red capture
and do not repair logs, fabricate SDK state or weaken case checks.

## Ordered-core source checkpoint

**Proposed source-only forward:** M2 checkpoint
`65eea31a5e3d318d67481a6be2a3d89a53cacbd8` is normally forwarded after A5
`004c85257fbad477d1e15c820fd19edb0655d908`. The sole content conflict combines
the new stubbed M1 container-capture control with all existing A5 workflow
checks. Source binding includes that control, and conditional backend connection
in the native contract fixture remains intact. Shipping SDK, runtime, CLI,
media, example and packaging inputs are unchanged from the preceding A5 commit.

**Measured source preparation only:** six pure Python/stubbed commands pass:
4 container-capture, 9 M0, 17 M1, 23 native-contract, 27 M2 gate groups, and 62
logical system controls. Their local receipt is
`discovery/out/a5-m2-forward-65ee/receipt.json`; 221 verification inputs stayed
unchanged and all 100 protected shipping inputs match the preceding A5 commit.
The earlier host receipts remain historical. The M2 parent's three-executable
host mute check and actual SDK Debug contract typecheck remain held and
unqualified here. All seven
system cases, the selected-provider no-pending-action reset boundary, the staged
launch guard and the six native push-entry build inputs remain present. Native
A5 acceptance remains pending and the recorded audio27 red remains unresolved.

**M2 host-scope update, documentation only:** the [phase-2
receipt](../verification/2026-10-22-m2-corrections/ordered-core-phase2.json)
records both held M2 checks completed on `65eea31a`, preserving the first Debug
capture as incomplete. This supersedes only the held M2 entry above; A5 native
acceptance remains pending and the audio27 red remains unresolved.

## Audio transport and authority source forward

**Measured source preparation only:** normal merge `15d801b5` forwards reviewed
M2 source `efbe4da6` into A5 `e7ddf086`. The source inventory includes both A5's
system/CLI/D5 evidence and M2's original silent-engine and completed no-I/O device
packets. The SDK, runtime, CLI, media, example and packaging inputs remain
byte-identical across an expanded explicit 104-file protection map. The changed
modern native fixture and its gates come from M2; they are acceptance inputs.

**Measured pure controls:** one affected round passes 189 logical controls:
container capture 4, M0 9, M1 17, native contracts 23, M2 28, lifecycle authority
22, original physical packet 10, completed no-I/O packet 14 and system cases 62.
The [source-bound receipt](../verification/2026-10-22-a5-audio-transport-forward/source-only.json)
records the 247-input source map, command results and expanded protection map.
Seven system cases, four M1 contracts, six PushKit cases and all four M2 cases
remain separate, with both legacy and modern audio paths required.

**Pending:** all seven A5 simulator journeys require fresh qualification on this
forward. No compiler, simulator, device, audio, dependency installation, CI run or
publication was performed for this source-only preparation. The completed
physical no-I/O packet proves its ordinary API/notification transport scope; the
original silent-engine run remains red with its cause unknown. Neither packet
qualifies LCK interruptions or the new native authority journey. Selected-provider
reset still requires no pending action; R3 remains deferred.

## Reviewed M2 CI-fix source forward

**Measured source preparation only:** normal merge `7207c6f8` forwards M2
`158afe4c` into A5 `50f2de171`. All 27 existing A5 delta paths and the shared
source inventory remain byte-identical. Of the explicit 104 protected inputs,
103 remain unchanged; the sole intentional change sets the CocoaPods header
namespace in `IosVoipSDK.podspec`. The other inherited source changes fix Bash
3.2 preflight argument handling and remove a 50 ms upper-bound assertion from
the host main-thread wait-refusal control.

The [forward receipt](../verification/2026-10-22-a5-audio-transport-forward/m2-ci-fix-forward.json)
binds the four changed sources and their parent receipts. It carries the exact
eight Bash/environment control groups and actual CocoaPods in-memory model;
consumer compilation remains pending. PR #40's refusal control retains its
source-only status. No unchanged 189-control round was repeated: its earlier
results remain historical, and this forward has a new source digest.

**Pending actual qualification:** original PR #39 SDK run `39853274996` remains
red at `50f2de171`, before native journeys or the pod-built device Release check.
Its API-bound artifact and duplicate-header failure are preserved. All seven A5
journeys, current pod-built Release exclusion and current M2 native lanes require
fresh CI on the corrected source. No local compiler, native, simulator, device,
audio, dependency installation or manual CI rerun was used for this forward.
