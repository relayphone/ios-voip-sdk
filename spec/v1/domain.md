# Call domain extensions, version 1

These records extend the [v0 call domain](../domain.md) and its identity, lifecycle, result and
budget rules. The v0 schema and catalog keep their paths. Version 1 has its own [schema](model.schema.json),
fixtures and journeys. Both wire versions use `{version, kind, value}`. Read the declared version
before decoding, and load the referenced v0 definitions locally for v1. Unknown versions and shapes
fail. A v1 journey reuses v0 configuration, controls and expectations where their meaning is identical.
The v0 call's media projection remains readable alongside the separate v1 `MediaState` record.

## Native presentation

Resolve localized `PresentationDescriptor` values in native code before intake. Each descriptor
has a lifecycle state, title, body, line label, body-tap target and a list of extra actions. Pending
Answer, confirmed hold and an unanswered incoming end may select `authorizing`, `held` and `missed`
respectively. They are presentation states. Defaults cover missing descriptors. Dialing uses its
own descriptor through placement and media preparation until authoritative progress selects the
next state. The connected descriptor requires confirmed connection.

Body taps open the app, open the call by canonical ID or invoke a registered native target.
Each extra action has a native registration, distinct opaque ID and display title. The registration
defines its allowed presentation states and valid input, and the adapter rechecks that state,
capability and action slots at render and invocation. Stale taps have no effects. Reserved
`answer`, `decline` and `hangUp` buttons remain system-owned. Descriptors customize SDK-owned
surfaces and keep the platform's system call UI under system control.

`NotificationObservation` has a call ID, surface and generation. An acknowledged `posted` row
records the actual descriptor and system buttons. Incoming CallStyle retains Answer/Decline.
Ongoing CallStyle and the service fallback retain Hang Up. `refused(reason)` observes a rejected
post. `shed` observes system removal outside a requested cleanup and `removed` confirms requested
cleanup. Unknown visibility yields no new observation. Posting, audibility and system call admission
are separate. Keep the latest refusal independently of the current visibility. A refused update
may leave a prior notification visible on the same surface and generation.

Keep the plain service fallback while promoting to CallStyle and retain it when promotion is
refused. Shedding triggers reconciliation subject to eligibility and rate limits, without re-ringing.
Coalesce equivalent cosmetic updates. Cancel ineligible queued work. Each lifetime of a given
surface for a call has a new generation. Serialize and correlate updates within that lifetime
and discard old callbacks. A removal observation pertains to its own notification generation.

## Media and audio

`MediaState` tracks owner, attempt, stage, transport, activation, capture/output gates and first
participating packets separately. The stage goes from `unprovided` through preparation or prejoin
to `prepared`, then through `releasing` to `released`. A failed or cancelled preparation retires its
resources. The attempt ID stays attached to cleanup, and stale callbacks cannot publish or end a
new attempt. The application's media owner follows the same gates via native audio coordination.

Optional native prejoin moves from `prejoining` to `prejoined` on provider evidence. Capture and
output remain closed. Prejoin may warm a receive subscription. Its traffic does not count as
participating packets. Failed prejoin can leave the call ringing. After a valid Answer permit and
slot reservation, move through `promoting` to `prepared` on successful reuse. If reuse is unsafe,
retire the prejoin attempt before exposing a replacement attempt's gates. A provider may never
publish for both attempts. The Answer budget and settlement ordering from v0 still apply.

System audio activation, transport readiness, the authoritative call connection and first sent or
received media packets are four independent observations. Open capture and output only with
prepared media, confirmed activation and the applicable authority, permission and policy gates.
Hold, mute, interruptions and teardown close the applicable gates. A first-packet observation
says nothing about a decoded frame or audible output. Keep unknown evidence explicit.

`AudioRoute` separates automatic or explicit endpoint intent from the observed endpoint. Values
identify endpoints by opaque ID and kind. A request acknowledgement does not change the observed
route. Native endpoint observations decide when it becomes active. Keep the user's latest intent
if Telecom or the OS temporarily chooses a fallback. Endpoint absence leaves an unavailable or
unknown observation according to the evidence. Use the active native audio authority to route audio.

## Push and capabilities

[Push intake and health](push.md) specify the native envelope, expiry, registration generations
and independent delivery evidence. [Capability availability](capabilities.md) defines the runtime
result and how to read the platform conditions in [capabilities.json](../capabilities.json).

## Timing events

`TimingEvent` carries stage, boundary, outcome, monotonic clock ID, elapsed microseconds and a
sequence number. `started` is pending, `finished` carries the typed result and `observed` records a
point observation. Derive elapsed values from a native monotonic clock relative to its epoch.
An epoch change creates a new clock ID. Sequence orders events on that clock, including equal
timestamps. Compare elapsed values only within one clock ID. A bridge attachment or JavaScript
delivery records a separate boundary and does not replace native timestamps.

Correlate known event, call, action and attempt IDs. Push intake may precede decoding an ID.
Claim, reconciliation and placement require call and action IDs. Media preparation, prejoin and
first participating packets require call and attempt IDs. Promotion requires all three to
correlate the Answer with its media attempt. Include both action and attempt when a stage belongs
to both. Preserve missing observations and detect lost event ranges.
Never include credentials or derive start, success or platform latency from missing data.
