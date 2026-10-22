# A7 process owner core preparation — October 22, 2026

**Proposed acceptance target:** every SDK creation path claims one process owner
before constructing its only LCK manager. Native Swift and Expo use the same
public `VoIPApplication.start` entry; the shared getter and separate client
configuration entry are removed.

This small branch retains the original foundation commit `68911b0` and merges
main `ef5a1f6` normally. A forward scope reduction removes the foundation's
optional foreign-provider diagnostics, SwiftPM trait/tools change and plugin
opt-in. Those remain on the separate M2 integration stack; this branch carries
no M2/audio ancestry. Existing main packaging and Debug diagnostics are kept.
The original foundation evidence remains recoverable from commit `68911b0`;
current-source evidence belongs to the focused core receipt.

The process claim uses a canonical selector as an associated-object key on
`NSProcessInfo.processInfo` under a brief synchronization block, with no callback
under that block. Each Swift SDK image supplies its immutable module identity
and UUID token. Objective-C class/symbol coalescing cannot merge those identities.
The losing SDK fails before its manager is constructed. Static duplicate symbols
can already fail loudly at link time.

`VoIPApplication.current` and its complete client are published before one-shot
launch setup. Repeated configuration is checked, and an identical reentrant
start sees that same owner. Expo's duplicate-linkage rejection is represented in
the public TypeScript error union, guard and runtime control.

## Evidence and pending work

**Measured:** the [focused receipt](../verification/2026-10-22-sdk-process-owner-core/host-checks.json)
binds 54 inputs and nine verification entries. The real two-SDK host harness
passes eleven groups, including both SDK load orders, concurrent claims, real
static duplicate-symbol failure, invalid-first configuration, conflicting
configuration and reentrant published ownership with exactly-once setup. LCK
and PushKit construction/observation remain explicit facades.

The genuine SwiftPM Release `iphoneos` library build passed; ten product hashes
were recorded before removing only its owned DerivedData. Four existing manager
region-isolation warning lines remain in the compiler log. The new process
helper also compiles for watchOS 10.4. TypeScript typecheck, eleven runtime
controls, formatting, five device-exclusion controls and the M1/contract host
gates pass. Independent SPEC and STANDARDS reviews cleared the frozen scope.

No simulator, physical device, APNs, hosted CI, push, pull request or publication
has been used. This does not measure duplicate linkage in a shipping app or
native calling behavior. The final A0.1 correction must be merged forward and
qualified before publication.

When main is merged into the M2 stack later, preserve M2's optional diagnostic
fields/flags by intent: this branch's forward scope reduction removes those
foundation additions solely from the core acceptance target.
