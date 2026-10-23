# B: outgoing probe readiness

**Measured CI red:** run `39714051678`, PR head `f853f450`, checked out merge
`26e2bc88`. The 26.3 compiler job used the iOS 26.5 simulator and failed
`two-managers` with `LCK managerStates differs from device`; its other three LCK
cases passed. The 26.6 job passed all four. The compact
[CI receipt](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-runtime-lck/readiness-ci-red.json) binds
the public artifact archives, probe/runtime/profile hashes, supervisor receipt,
checked-out source blobs and exact offline replay results.

This is a probe scheduling race with a real missing `joined` state. In the
failed first outgoing journey, start acceptance returned at 2405 ms, its delegate
performed at 2851 ms, and the fixed two-second checkpoint recorded an idle,
disconnected call at 4473 ms. The probe requested end immediately; both managers
reported `left` at 4504–4505 ms. Its delayed connection report ran at 4540 ms, after
the runtime had removed the call, so the late report correctly had no effect.
Both managers' missing joined callbacks, the observer/snapshot state and audio
journey binding differ from the device. This is not cross-manager callback
ordering variation. Source inspection points to slow synchronous audio
preparation/fulfillment before the delayed report; the individual audio API call
was not separately timed.

**Proposed fix; hosted native acceptance pending:** only the generated simulator
copy changes. It retains the original two-second outgoing delay, then waits for
the requested UUID to be joined in every active manager, each manager's joined
delegate callback to have been logged, and the matching observer call to be
connected and not ended. A small locked callback ledger preserves the public
delegate witness's isolation across SDK versions. The measured `cx-after` case
skips the added wait because its later CX tap fulfills start without reporting
connection; its idle/unconnected snapshot remains the expected result.

The added **ten-second monotonic liveness budget is proposed test infrastructure
policy**, not an Apple timing measurement or a change to an action deadline.
The waiter checks its clock before and after each synchronous readiness
inspection and rejects a result observed after expiry. It cannot preempt a
blocked main actor/native getter; it rejects expiry once execution resumes, and
the existing scenario supervisor retains its outer process bound. An expired
or cancelled wait emits a stage error and exits the probe with status 1 rather
than continuing into an incomplete journey.

The historical `docs/research/callkit-simulator-probe/lck.swift` remains
SHA-256 `2b0e430ff81453258da9782b94e5f770a5e41700ee5a5db98580c8e049b006d3`.
Runtime semantics, device-derived deadlines, profile data and conformance
comparisons are unchanged. A new negative control explicitly rejects a missing
joined callback from either manager.

**Measured preparation:** the focused generated-source assertion failed before
the barrier and passes afterward. A second control rejected the earlier helper
that admitted readiness after its budget. Host controls cover the actual waiter,
callback ledger, cancellation, late readiness, timeout, immutable-source
generation and refusal when a historical anchor changes. The actual generated
probe and its support sources typecheck against the installed iOS SDK in Swift
5 mode; the immutable-input baseline and prepared copy have the same inherited
warning inventory. These compiler checks do not build or launch an application.
The [host receipt](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-runtime-lck/readiness-host.json)
binds final source hashes, checks and compiler-only inputs. No simulator was
created and no native journey was rerun for this preparation.

The final gates pass: three focused readiness groups, fifteen LCK conformance
tests, nine device-oracle tests, five provider-policy groups, ninety-six harness
groups and shell syntax. Independent spec and standards review each found no
remaining actionable issue. The spec review's one-millisecond timeline
correction is reflected above and in the compact CI receipt.

Next: integrate this commit into PR #14 and require fresh hosted native results
from both compiler jobs before claiming the readiness fix accepted.
