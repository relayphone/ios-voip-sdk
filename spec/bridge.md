# Native and JavaScript calling bridge

This contract applies to the iOS and Android bindings of the call-oriented Expo API.
[The bridge schema](bridge.schema.json) defines the JSON exchanged by those bindings. The
[v0 model](model.schema.json), [v1 model](v1/model.schema.json) and [domain rules](domain.md)
define the embedded records and their invariants. IDs, timestamps, integers and field presence
follow those rules. Compare canonical JSON after decoding and encoding. Omit absent optional
fields. Reject unknown fields, tags and versions.

## Negotiation

Before attachment or commands, JavaScript calls `negotiate(offer)` with
`{kind:"negotiate",versions:[1]}`. The list is nonempty and contains distinct positive safe
integers. Native chooses the highest version it implements from the offer and responds with
`{kind:"negotiated",result:{ok:true,value:{version:1}}}` for version 1. If there is no common
version, native returns `{kind:"negotiated",result:{ok:false,error:{kind:"bridgeUnavailable"}}}`.
The JavaScript binding also checks that the selected version was offered. An incompatible or
missing bridge cannot attach, submit commands or register a placement handler.

The selected version applies to the lifetime of the binding. A replacement native module
requires negotiation again. A runtime epoch change within the same binding keeps the negotiated
version. Bridge version 1 accepts both v0 and v1 independently versioned model records. An
unsupported bridge or model version never falls back to a different decoder.

## Attachment and ordering

The store consumes a synchronous `attach(receive)` that registers the receiver and returns a
`{snapshot,unsubscribe}` pair. Native must make registration and capture atomic on the same
serialization boundary that publishes frames. The binding may receive callbacks during
attachment and buffers them until snapshot hydration finishes. The idempotent `unsubscribe`
releases that receiver. Detaching leaves the native call runtime and its cleanup work active.
The synchronous native `snapshot()` read returns the latest authoritative snapshot from the
same boundary for gap recovery. Both snapshot paths return copied values without starting work.

A cursor is `{epoch,sequence}`. Epoch is an opaque, non-reused ID for a timeline, replaced on
runtime recreation or timeline reset. Sequence is a nonnegative safe integer, starting at 0
before the first frame and advancing by 1 per published frame. If the timeline exhausts the
safe integer range, start a new epoch. Sequence comparisons are within an epoch only. A cursor
identifies one frame and cannot be reused for different content.

Both snapshot paths return `{cursor,calls,completed?,pushHealth?,records?}`.

- `calls` holds v0 call values with unique IDs. Include live calls and retained terminal calls.
  Order the terminal subset from oldest to newest by first terminal intent.
- `completed` names only retained ended calls whose media and system work and other adapter
  operations have all finished. The absence of an ended call ID from this list means its
  adapter work is still pending. A late attachment can see or correlate cleanup work.
- `pushHealth` is the current v1 health value when known. Include no raw push token.
- `records` carries current model records needed to restore projections, including v1 media and
  runtime and call capabilities. Each scoped record refers to an included call. Publish a
  call before its scoped projection records. Hydration applies these records after the base
  calls. A later v0 call update preserves separately observed v1 media until a v1 media update
  or authoritative rehydration.

| Frame kind | Fields besides `kind` and `cursor` | Meaning |
| --- | --- | --- |
| `record` | `record`, optional `correlation` | One v0 or v1 model envelope. Correlation may carry the applicable `callID`, `actionID`, `eventID` and `attemptID`. Include the target call and action ID for action-specific records when those IDs are known. Embedded IDs and correlation agree. |
| `cleanup` | `callID`, `outcome` of `removed` or `failed` | The system removal attempt produced this outcome. This event leaves independent media and other work pending until completion. |
| `actionPerformed` | `receipt` | The confirmed action's original `actionID`, v0 `action` and `origin` of `app`, `system` or `remote`. The action carries the canonical call ID. |
| `terminalCompleted` | `callID` | The ended call's remaining adapter work finished. It may follow system removal or occur without a system removal attempt. |
| `callRemoved` | `callID` | A completed terminal record left native retention. Native applies the monotonic age and count policy in the domain contract. |

Publish a frame only after its effects on the snapshot are readable. Native may replay a
covered frame with the same cursor and content. The store drops duplicate or older frames,
including those covered by attachment hydration. If a frame skips a sequence or introduces a
new epoch, JavaScript reads the authoritative snapshot. Its cursor must include the triggering
frame when the frame's epoch is still current. A reset may return an even newer epoch. A frame
from a retired epoch cannot move JavaScript back to it. The store replaces state, discards the
invalidated journal and emits `resyncRequired` with the recovered snapshot.

`snapshot` and `resyncRequired` are JavaScript observations. Native sends the frame kinds
above. Without a cursor, consumers first receive the current snapshot. `observe({after})`
replays frames strictly after that cursor if the range remains available in the current
epoch. An expired, foreign or future cursor receives `resyncRequired`. The JS replay buffer
is bounded. Native retains terminals across JS attachments and must honor the pending-work
exception to retention. JavaScript may also trim its completed terminal rows by count.

## Commands and replies

Each `command(request)` invocation sends `{kind:"command",operation,input}` and resolves once with
`{kind:"reply",operation,result}`. The invocation correlates the reply, which echoes the same
operation. An operation with no input omits that field. A successful result is
`{ok:true,value}`. A failure is `{ok:false,error}`. An operation that returns void uses
`value:null` on the wire. JavaScript maps it to void.

| Operation | Input | Successful value |
| --- | --- | --- |
| `start` | Canonical `id`, configured `lineID`, nonempty `parties`, initial `video` flag | `{kind:"performed",receipt,cursor}` |
| `perform` | `id` and discriminated `action` | The performed value for Answer, Join, Hold, Mute, Video or Tones. End returns `{kind:"end",cursor,outcome}`, with the v0 `endResult`. |
| `bindRemote` | `id`, `remoteID` | Void, including the same binding repeated |
| `receive` | `eventID`, target by canonical or remote ID, and `connected`, `ended`, `partiesChanged` or `videoRequested` event | `{kind:"applied"}`, `{kind:"buffered"}` or `{kind:"duplicate"}` |
| `reportIncoming` | `callID`, `eventID`, `line`, `party` | An admission decision or `{kind:"duplicate",original:decision}` |
| `permissions.read` | `{kind:"microphone"}` or `{kind:"camera"}` | `granted`, `denied`, `restricted` or `notDetermined` |
| `permissions.request` | Same permission selector | Same status after a foreground request |
| `push.registration` | Omitted | v1 registration or `{kind:"unknown"}` |
| `push.health` | Omitted | v1 health or `{kind:"unknown"}` |
| `audio.routes` | Omitted | `{revision,routes,current}`, with opaque endpoint IDs and a nullable current output |
| `audio.select` | `id` from the available routes | Void on acceptance, with actual output reported by the route observation |

Android emits `audioRoutesChanged` using the same snapshot shape as `audio.routes`. Its revision
advances when the list or current output changes, independently of the call journal cursor.

The matching successful `start` or `perform` reply includes a cursor at or after the
revision that records completion. A performed reply returns the same receipt as the
`actionPerformed` frame. Publish that frame once after the confirmed state becomes readable.
Its origin belongs to the original request, including when an app request shares a pending
system Answer. Remote transport facts do not create action receipts.
Start completes at placement and native start. Answer completes at authorized system
settlement. Hold, Mute and Video complete on confirmation, and Tones completes on confirmation
of the local send. With JavaScript-owned media, the app can forward the performed digits to its
media transport. Queueing work does not complete the action. A repeated local End returns
the original receipt, whereas an End after remote termination returns the original reason with
`alreadyEnded`. A repeated or already-ended End emits no new action frame.

Use the domain rules for buffered events, deduplication and alias conflicts. `reportIncoming`
reports native admission or its observed alternative. A decision includes its canonical
`callID` and is `admitted`, `previewed` with preview reason, `filtered` with filter cause,
`ended` with the terminal reason, `hidden`, `capacity` or `refused` with a typed error.
A duplicate returns the original decision and its call ID, including when the retry supplied
a different call ID. A known event ID cannot
admit another call. Admission alone conveys no evidence of audible ringing.
Permission reads and push reads are safe queries. Only an explicit foreground permission
request may prompt. A request needing a prompt while backgrounded fails with
`permissionRequired` for that permission. Push reads report `unknown` when evidence is
unavailable. Registration and health expose scoped token identifiers, generations and evidence.

Map expected native failures through explicit error tags and fields. Use `unknownCall(callID)`
for a missing call, `invalidTransition(state)` for an ineligible action, `refused(reason)` for
an authority decision, `remoteIdentityConflict(remoteID)` for alias conflicts, and
`unsupported(feature)` for unavailable capabilities. `systemFailed` carries a platform and
typed operation class with an optional numeric native diagnostic code. Use `bridgeUnavailable`
for missing or incompatible bindings. Reject malformed protocol input before side effects.
Do not convert native exception text into an error tag or transmit arbitrary diagnostic strings.
Represent an explicit server failure as `{kind:"failed",error:{kind:"serverFailed"}}`.

## Placement handler

Placement requests are a private control channel on the same binding, separate from the
observation journal. Register its receiver with `attachPlacement(receive)`, which returns an
idempotent unsubscribe, before sending `placement.attach` with `{generation,attached}`.
The positive safe integer generation increases with each registration,
replacement or removal on that binding. An older registration has no effect. This command
acknowledges with void. Detachment or replacement cancels the previous generation's outstanding
placement requests. The native authority still handles incoming Answer independently of JS.

Native requests Start or preview Join with
`{kind:"placementRequested",generation,actionID,request,deadline,remainingMs}`.
The request includes `kind` of `start` or `join`, `origin` of `app` or `system`,
`callID`, `line` and nonempty `parties`. The deadline is a UTC millisecond timestamp for
diagnostics. `remainingMs` is the positive native monotonic budget remaining at dispatch.
The JS handler receives an abort signal and the remaining duration. Transfer delay cannot extend
the native deadline. Native enforces it on its own clock and emits `placementCancelled` with
the same generation and action ID and a typed reason when work is cancelled.

JavaScript submits `placement.settle` with `{generation,actionID,result}`. A successful
handler result is `placed` with an optional remote alias or `refused` with a typed refusal.
A handler exception becomes `placementFailed(handlerFailed)`. Cancellation may report
`placementFailed(cancelled)` while the request is still pending; an aborted request needs no
settlement. Native returns `{kind:"accepted"}` only for the first settlement matching the
binding, generation and action ID of pending work before its deadline. Otherwise it returns
`{kind:"stale"}`. Stale or duplicate settlements never advance a call, bind a remote ID or
repeat a system action. Duplicate request delivery must not invoke the JS handler again.
Cancellation aborts only the matching signal, with replacement fencing callbacks from the
previous generation. Control messages cannot carry credentials or media tokens.

## Conformance

[Valid and invalid fixtures](bridge/fixtures/) contain arrays of individual schema messages.
The TypeScript conformance suite replays them through a fake native transport. Both native
bridge suites must exercise the production codecs and adapter boundary against the same
fixtures, with fake system, media and clock ports where necessary.

| Area | Required assertion on each platform |
| --- | --- |
| Versions and shape | Select the highest common version, reject a missing intersection before effects, round-trip all valid messages canonically, and reject every invalid message. |
| Attachment | Emit a call before attachment and a frame during attachment. Verify the snapshot and subsequent frame order, duplicate suppression, one active receiver per attachment and idempotent unsubscribe. |
| Recovery | Skip a frame and replace the epoch. Verify authoritative snapshots cover the gap, covered frames remain idempotent, and a delayed old-epoch frame cannot regress state. |
| Retention | Detach with both a completed terminal and a pending cleanup. Verify hydration order and counts after reattach, then deliver late cleanup and completion. Verify pressure expires only completed records. |
| Commands | Drive the normal adapter entry points. Correlate completion with the original receipt, origin and confirmed state. Repeat a local End and End an already remote-ended call. Retry an invitation with a different call ID and verify the original decision and identity. Verify server and platform failures retain their typed causes. |
| Queries | Verify permission reads and background requests do not prompt. Verify push results preserve registration, generation and delivery evidence while excluding token and credential values. |
| Placement | Replace or detach a handler with pending work, then deliver its late result and duplicate completions. Advance a virtual clock across the deadline and verify cancellation, stale acknowledgements, and one native settlement only. |
