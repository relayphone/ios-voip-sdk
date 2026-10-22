# A8: action and transport contract fidelity

**Implemented preparation; native qualification pending.** This slice builds on
the reviewed handler-rejection bridge change `c1e7dcb`, A3 pending-mute filter and
A2 deadline margin. It addresses the state/report part of steering §A.8. The
[host receipt](../verification/2026-10-22-a8-action-contracts/receipt.json) binds
the source, controls and regression output. This is not full A8 acceptance yet:
the audio-event envelope and actual-client wrapped-duplicate controls remain to
be integrated from their respective owners.

Join/start fulfillment acknowledges signaling. A native incoming `.joined`
conversation projects `connecting` until an explicit transport `connected`
report supplies `connectedAt`. Outgoing Start can remain native `idle`, which
projects `dialing`; a transport `connecting` report advances that projection.
Neither action itself fabricates media/transport connection. The host boundary
preserves that distinction rather than forcing Start into `joined`.

`reportConversation(.ended(.local))` is now `async throws` and awaits the existing
public end command, including its handler and failure. It sends no remote-ended
LCK event. Nonlocal reasons retain their native report mapping. Direct native
`receiveCallEnded(.local)` is refused before event deduplication, including while
an incoming report is suspended. The unchanged wire parser still treats a
peer's `local` or unknown reason as remote on this device.

The example and native unhandled-accept fixture first observe signaling settled
with no pending action and no connection timestamp, then explicitly report the
fixture backend connection. The strict native gate still binds the unique CX
answer settlement to its effective/platform deadlines. The later backend
connection does not inherit the fulfilled action's deadline. The native fixture
also acquires and repeats the single public `VoIPApplication.start` entry with
identical configuration, ready for A7's ownership change.

**Measured host controls:** the actual Client and Handler compile with the
existing LCK-only facade. Seven delayed-mute groups and six report/state groups
pass, covering both directions, delayed/rejected local end, every nonlocal end
mapping, and termination racing an incoming report. The initial behavioral red
rejects the old premature incoming connection. Core, projection, push, relay,
TypeScript and focused native-gate controls pass. No simulator/device was used.

An earlier prototype hit unnecessary-`await` compiler diagnostics against the
old synchronous signature. A later broad host batch exhausted its 180-second
compiler/script budget before its first result; no product cause is inferred.
The completed client runner bounds each compiler/test process and cleans only
its owned process group on timeout. Native integration and hosted acceptance
must still qualify the final combined source.

**Measured host integration:** A1 `4dbe796` and A0 `31e3d8d` are integrated in the
follow-up [receipt](../verification/2026-10-22-a8-action-contracts/integration-receipt.json).
The actual-client suite now has ten contract groups, adding direct/wrapped
duplicate-error acceptance only for a known live conversation, propagation of
wrong-domain/code failures, and rollback/retry after an unreported failure.
These inject representative `NSError` shapes at the framework boundary; they
do not measure genuine LCK error wrapping. The A1 pipeline facade awaits the
async report signature. Both branches' workflow checks remain, and the embedded
simulator JSON exactly matches A2's canonical profile. A0's retained native
device-exclusion evidence keeps its original source identity. The combined
source still needs native acceptance; audio-event context remains with A4.
