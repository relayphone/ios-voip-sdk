# A3 — pending app mute echo

The system mute filter now compares its value with live, unexpired app-origin
mute entries already owned by the handler coordinator. A matching system action
fulfills without a second handler invocation while application work is pending.
An opposite value continues through the real handler, including when it equals
the old committed mute state. The existing settled-state no-op filter remains.

No separate intent ledger is introduced. Accepted/rejected actions, deadlines,
platform timeouts and manager resets use their existing coordinator cleanup.
An already settled platform action cannot supply pending intent, and a late
handler result cannot settle a new action or overwrite committed state.

**Measured original host evidence:** the [receipt](../verification/2026-10-22-a3-pending-mute-echo/receipt.json)
binds base `3e4b11ad9f316fff549ea73529b278682d85838f`, the production sources,
boundary facades and control inputs. The base client fails the matching-echo
assertion with the app handler held beyond 40 ms. The fix passes seven groups;
the recorded minimum delay is 43.353 ms. The entire actual `ConversationClient`
and actual coordinator/handler compile in Swift 6 with warnings as errors; the
test runner changes only the native compilation/import boundary and substitutes
LCK types. These are host action/handler measurements, not native LCK behavior.

The controls cover delayed matching echo plus opposite-value delivery,
application rejection, coordinator deadline, platform timeout, manager reset,
an already settled platform entry, and conversation isolation. They release
every held continuation and verify that obsolete work cannot settle twice.
Existing core, terminal-projection/report-serialization and push controls pass.
The existing SDK workflow now runs the new host control.

**Proposed physical qualification:** Claude still needs to measure echo timing
with delayed fulfillment on the dedicated phone, as required by
[steering A3](2026-10-22-claude-steering.md). No device/simulator run or new native
echo timing measurement occurred here. A0 release blockers and other steering
items remain separately tracked; this acceptance is A3 host behavior only.

**Measured earlier A2 integration:** the [follow-up receipt](../verification/2026-10-22-a3-pending-mute-echo/a2-stack-followup.json)
binds the merge of A2 parent `1fd33b4969a5a19dee14b18da354612f9b9534ef`
and that capture's source inputs. All seven actual-client mute groups pass, with
the app handler held for at least 42.369 ms. Core, push, terminal projection,
report serialization and deadline controls also pass. The timeout fixture now
supplies 1.62 seconds at the LCK boundary, retaining its 0.12-second effective
host budget after A2's production 1.5-second settlement margin. The original
red/green receipt and streams remain unchanged. This follow-up ran on the host;
native LCK delayed-fulfill echo timing remains unmeasured.

**Measured final parent preparation:** the [integrated receipt](../verification/2026-10-22-a3-pending-mute-echo/final-parent-integration.json)
binds code `334f196b0e74fd685ba2a108b3724d4a073ae9e8`, SDK inputs
`677f5e27a803ffedc0bb0878760d8ed6ba93229af6c985ff4af97c8f11d3c361`
and reviewed parent `257c0cd9776b56843793ec963f0db2fd5fcf5d2b` from PR #25.
Ten focused host/compiler commands pass. The actual-client mute control retains
all seven groups, with a minimum held-handler delay of 41.305 ms. Core/deadline
controls, three whole-client incoming-cache modes, seven M0 gate groups,
15 M1 gate methods, 21 native-contract gate methods and the push-entry host
controls pass. The actual Debug SDK and four-case native contract probe typecheck
for the iOS 17.4 simulator target; this does not link or run an app.

The mute runner compiles the actual client, incoming transport, intake and wire
sources against the parent's shared `IncomingCachePlatform.swift` LCK boundary.
Its old duplicate facade is removed; the original facade remains in historical
commit `509d9a7e7482877c7ca220cd532f56204b734ca3`. The original seven behavioral
assertions are unchanged. The native four-case runner, probe, gates and engine
retain the parent's bytes, including the container cache, preboot host metadata
and native `application` origin. Independent SPEC and STANDARDS reviews are clear.

**Measured historical CI limits:** original SDK run `39761951380` remains red
with exit 142 after nine successful supervisor receipts. Its final contract
journal, source-after snapshot, manifest and aggregate summary are absent, so
all three aggregate gates remain red. The exact failure cause is unproven.
Original runtime run `39761951547` passed both compiler lanes, with nine offline
gate commands replayed per lane, on iOS 26.5 using the `ios-27.0` profile. Those
results bind old head `b44c35a` and test merge `36aabf8`; they do not qualify this
integrated source. Original runs were not retried or relabeled. Fresh native CI
and Claude's physical delayed-fulfill echo measurement remain pending. This
preparation performed no local app, simulator or device run.
