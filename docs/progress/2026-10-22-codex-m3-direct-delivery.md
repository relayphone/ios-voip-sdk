# M3 A9: direct simulator delivery

**Proposed acceptance, native run pending:** the October 22 steering permits
explicit direct URL and resolved start-call-intent delivery on a simulator.
This branch adds that separate target. It does not qualify default calling
dispatch, Siri, Recents, or an OS-created `NSUserActivity`.

The example subscribes through the actual public `useConversationEvent` hook,
then publishes readiness. After the runner binds its runtime session and PID,
it writes a fixed-schema control into that app's sandbox. The example verifies
run, simulator, PID and mode before delivering two fixed inputs:

1. `tel:+15555550142` through the actual application's public delegate URL
   callback, which Expo forwards to its subscribers. An independent example
   subscriber observes the callback; the SDK subscriber forwards it normally.
2. A publicly constructed, resolved `INStartCallIntent` for a different handle
   and video capability through `VoIPSystemEntryPoints.handle(intent:)`.
   `NSUserActivity.interaction` is readonly, so the fixture does not fabricate
   an activity or claim OS activity delivery.

The first real JS event must complete before the second input is delivered.
The distinct gate requires exactly two matching public events, both accepted
entry points, main-queue/process/run identity, empty conversation snapshots and
zero conversations at readiness/control/event publication. Evidence includes
only input digests. The fixture never calls the private router, creates a
provider or manager, or invokes a conversation command.

**Measured host controls:** 13 direct groups pass, including the actual
Foundation control parser, production URL/intent statements typechecked with
the real entry-point sources against the installed public simulator SDK,
subprocess-boundary runner controls, interruption cleanup and rehashed scalar,
identity, payload, privacy and evidence tampering. The original 19 OS controls,
TypeScript typechecking and workflow lint also pass. This statement-level
typecheck is not a whole Expo example build or a native journey. The
[host receipt](../verification/2026-10-22-sdk-m3-direct/host-checks.json) binds
the working source and command-log hashes; committed-source native acceptance
still requires its own receipt.

Independent SPEC review (r5_spec) and STANDARDS review (root) cleared the
source, evidence bindings and claim scope. Both reviews were read-only and
make no additional native qualification claim.

`run_sdk_m3_direct.py` shares the existing runner's build, install, process,
environment-preservation and owned-cleanup plumbing. It writes an explicit
`sdk-m3-direct` manifest with `directIngressInjectionRequested: true` and uses
`sdk_m3_direct_conformance.py`. It runs no Settings test or OS URL dispatch.
The shared builder still retains its original source-bound UI products; those
products are not evidence of Settings execution in a direct capture. CI now
measures the direct target. The original `run_sdk_m3.py` default and
`sdk_m3_conformance.py` remain the strict OS comparison, with no expected-red
exception. Neither gate can accept the other's labeled evidence.

**Measured original OS red, preserved:** frozen `b0121ba`, hosted iOS 26.5 /
Xcode 26.6, run 39739841564 attempt 2 selected the example in real public
Settings before dispatch. PID 15505, installed bytes, readiness, AX and PNG
bind. Exact OS `simctl openurl` returned 115; no native ingress/public event
arrived, and the unchanged OS gate remained red. The owner stopped the
incomplete supervisor; deletion, inventory absence and sampled environment
preservation pass. [Reading evidence](../verification/2026-10-22-sdk-m3/hosted-os-red-b0121ba/receipt.json)
retains original rows/images and their hashes. Complete products, source
receipts and raw console remain private and hash-bound. This does not establish
a universal simulator limitation or a stable cause for error 115. The earlier
[local iOS 27 red](../verification/2026-10-22-sdk-m3/native-red-d216355/receipt.json)
also remains unchanged.

**Pending:** a committed-source example build and actual direct simulator
capture; independent review of that capture; physical default-calling dispatch.
A0 first and A1–A9 integration remain merge prerequisites. No device, APNs or
simulator action was performed while preparing this branch. The public RFC
API is unchanged, so no RFC deviation comment is introduced by the acceptance
mode change.

**Measured integrated host preparation:** the A9 branch merges the reviewed
A7/A4/A8 integration `47834d58` normally. The three content conflicts retain
the dial listener and generation isolation while preserving typed handler
rejections, the sole `VoIPApplication.start` owner, atomic media selection and
optional conversation identity on audio events. The shared audio queue and
explicit backend connected report remain in the example; its main-thread
category setter remains removed. The direct gate now requires the real owner
label and rejects the obsolete shared-client label.

Seventeen affected host/compiler/build/lint commands pass, including 13 direct
and 19 original OS groups, the real relay, action preparation/deadline/echo
contracts, audio queue/lifecycle/media controls, process ownership and TypeScript.
The [integration receipt](../verification/2026-10-22-sdk-m3-direct/integration-host-checks.json)
binds these source inputs and command logs. Independent SPEC and STANDARDS
reviews clear the resolved integration. The original host receipt and OS red
exports are historical and unchanged. This is not an Expo native build or call
journey: the final A0.1 fix and committed-source simulator capture remain pending.
No push, simulator or device operation was performed for this integration.

**Measured audio consumer followup:** merge `19f37c9` removes the unused
`Notification` payload from the route-refresh closure, preserving the main-queue
refresh and preventing the payload from crossing Swift isolation. The affected
installed-SDK compiler control passes for iphoneos, iphonesimulator, watch
simulator and the Expo wrapper. Its [receipt](../verification/2026-10-22-sdk-m3-direct/audio-consumer-followup.json)
is separate from the earlier A9 host receipt. This is compiler evidence only;
no native build, simulator launch or device action was performed. The genuine
SwiftPM LiveKit consumer check remains evidence of the separately reviewed A4
followup. The A5 manual connected-report button change will arrive separately.

**Measured A5/M2 forward preparation:** this branch normally merges reviewed
A5 `004c85257fbad477d1e15c820fd19edb0655d908`, including corrected M2
`0743f14486bba8437c66c2221a3f38be5b1828d8`. The two example conflicts retain
both system-control and direct dial-request paths. The manual connected report
now remains available while connecting or dialing; the canonical asynchronous
local reports, per-object end handling and explicit backend-connected markers
are inherited unchanged. The shared source inventory retains A5's external
system controls, four M1 contract cases and all six push-entry cases, including
the native main-stall helper and `CKPushLaunch` build input.

The shared M3 runner also removes inherited `SDK_SYSTEM_` child environment
settings before launching either M3 mode, and the system runner removes
inherited M3 child settings before either its warm or cold launch. Mocked
subprocess-boundary controls fail against the exact prior `c45ab865` M3 runner
and `004c8525` system runner, then pass against the combined source. These
controls create no simulator or native process. Sixteen focused
host commands pass at the 238-input working-source digest in the
[forward receipt](../verification/2026-10-22-sdk-m3-direct/forward-004c852-host.json),
including all 13 direct and 19 original OS groups, the inherited gate controls,
TypeScript and Swift parsing. These checks do not qualify an Expo app build or
native journey. The original OS gate and its error-115 RED evidence are
unchanged.

**Still pending:** a committed-source Expo build and direct simulator capture,
independent capture review and physical default-calling dispatch. A0's iOS 27
native audio-interruption acceptance remains unresolved, and physical PushKit
cold-launch measurements remain required before beta. This source-only forward
does not close those gates.

**Measured ordered-source forward preparation:** this branch normally merges
A5 `670e2ea7fe5b362592f7d176d3a4d976edd0caa0`, including provisional M2
source checkpoint `65eea31a5e3d318d67481a6be2a3d89a53cacbd8`. The sole conflict
is the source inventory: its 81 entries retain the new M1 container-capture
checker and all nine M3 paths. The direct URL, typed intent, public JavaScript
listener, both environment guards and original OS gate keep their prior bytes.
All shipping source and example trees are unchanged from `18560017`. The
incoming conditional backend report, four M1 contract cases, six push cases
and seven system journeys remain intact.

Nine pure Python/stub commands pass at the 239-input digest in the
[source-only receipt](../verification/2026-10-22-sdk-m3-direct/forward-670e2ea-source-only.json).
The selected M3 suite runs 18 original OS and 11 direct groups with real
subprocess calls forbidden. It excludes all three controls that invoke Swift.
The four new container-capture groups execute the real shell fragment with
stub simulator tooling. No compiler, app build, simulator, audio, device,
signing or package installation was performed.

**Unqualified:** M2's host-mute fixture and SDK Debug compiler
checks remain held. This source checkpoint provides no replacement result.
A5/A9 native acceptance remains proposed; the iOS 27 audio RED and physical
measurements remain unresolved. Earlier native and compiler receipts retain
their original source scope.
