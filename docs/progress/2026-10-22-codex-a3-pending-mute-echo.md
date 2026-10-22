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

**Measured host evidence:** the [receipt](../verification/2026-10-22-a3-pending-mute-echo/receipt.json)
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

**Measured A2 integration:** the [follow-up receipt](../verification/2026-10-22-a3-pending-mute-echo/a2-stack-followup.json)
binds the merge of A2 parent `1fd33b4969a5a19dee14b18da354612f9b9534ef`
and the current source inputs. All seven actual-client mute groups pass, with
the app handler held for at least 42.369 ms. Core, push, terminal projection,
report serialization and deadline controls also pass. The timeout fixture now
supplies 1.62 seconds at the LCK boundary, retaining its 0.12-second effective
host budget after A2's production 1.5-second settlement margin. The original
red/green receipt and streams remain unchanged. This follow-up ran on the host;
native LCK delayed-fulfill echo timing remains unmeasured.
