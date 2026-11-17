# Call domain, version 0

This is the initial executable contract for the [accepted architecture](../docs/architecture.md).
It covers identity, lifecycle, actions, termination, errors and budgets. Platform presentation,
media provider protocols and broader capability policy follow separately; this version does not
claim a platform implementation. JSON Schema uses draft 2020-12, with document `version: 0`.

## Wire format and evolution

`model.schema.json` validates envelopes `{ version, kind, value }` for `call`, `action`,
`endReason`, `error` and `budgets`. Its `journey` and `transitions` definitions validate the
other two document formats. Unknown fields, discriminants and versions fail. Breaking shape or
meaning changes require a new version and explicit reader support; do not silently reinterpret v0.
The host decoder supports the schema's declared subset only and rejects unknown schema keywords.

`fixtures/valid` and `fixtures/invalid` are shared inputs for every implementation. Valid values
must round-trip to identical canonical JSON: objects sorted by their ASCII field names, compact
JSON, array order preserved, safe integer numbers, original strings preserved, no insignificant
whitespace. Model field names are ASCII. Invalid records must fail; no defaulting unknown states.
TypeScript literal witnesses must match every file and compile with positive `satisfies` checks
and negative `@ts-expect-error` checks. Value constraints also require runtime tests. No types are
generated. Swift and Kotlin add these same fixtures as their implementations arrive.

## Identity

`CallID` is the canonical application ID for incoming and outgoing calls on every device.
Wire IDs are exact strings, never platform UUIDs, hashes or normalized handles. They contain
1–256 Unicode code points and at least one character outside the whitespace set in the schema.
Whitespace around a valid ID is preserved. Native/JS APIs may wrap validated strings in ID types.
A service assigning its own ID uses `bindRemote`; a call is never renamed. The alias is unique
among live calls, repeated identical binding succeeds, and replacement/collision returns
`remoteIdentityConflict`. Retain alias-addressed events until binding and deduplicate by `EventID`.

A line contains `accountID`, `id` and display `label`; the line is immutable after admission.
A party has an app ID, display name and a `phone`, `email` or `opaque` handle. Phone is E.164;
opaque explicitly includes SIP URIs and short codes. Handles never replace call identity.
Event, action and attempt IDs occupy separate namespaces. Retain terminal/deduplication metadata
for up to 120 seconds and 256 terminal records, limited by both, without credentials. Runtime
state is authoritative; persisted connected records require reconciliation after process death.

## Lifecycle and invariants

| Lifecycle | Meaning |
| --- | --- |
| `reporting` | Incoming system admission is pending; this is not confirmed ringing. |
| `ringing` | An admitted incoming invitation awaits Answer; filtering may still suppress sound. |
| `previewing` | Follow without ringing or audio; typed reason is filtered, elsewhere or policy. |
| `placing` | Outgoing start or preview Join awaits application placement. |
| `dialing` | Outgoing placement succeeded, without asserting remote answer. |
| `connecting` | Answer/Join settled or authoritative connection is waiting on readiness. |
| `connected` | Authoritative connection and required readiness are confirmed. |
| `reconnecting` | Previously connected transport is recovering. |
| `ending` | Terminal intent owns the call; media gates are closed, system cleanup may remain. |
| `ended` | Logical termination is retained, with reason and UTC millisecond `endedAt`. |

Hold, mute, video, media preparation, audio activation and transport state are independent.
Connected/reconnecting records carry the original UTC millisecond `connectedAt`; hold/recovery
never invent a new first connection time. Timestamp strings must represent actual calendar instants.
Outgoing records cannot report/ring/preview; incoming records cannot dial. `parties` is nonempty.
The runtime retains connection history through hold and teardown even when a projection omits it.
Media preparation, system activation, packets and remote answer are separate observations.

The reducer serializes inputs. `transitions.json` lists trigger/guard/effect cases; it is a contract,
not a runnable substitute for the real engine. For each input, select the first matching rule.
A false guard does not authorize its effects. Unknown/stale work cannot advance the call.
Nonapplicable user actions return typed errors without changing state. Late events after terminal
ownership cannot resurrect the call. Action/attempt generations protect asynchronous completions.

Guards have these meanings: `newCall` means no live identity collision; `newCallAndSlot` additionally
requires a free participation slot for Start; `joinEligible` requires preview Join and that slot.
`noRetainedEnd` means no
accepted end raced admission; `incomingJoin` requires the current attempt's pending preview
placement before participation, rejecting older generations on every asynchronous input;
`answerEligible`
means ringing, no pending Answer and a free participating slot; `notReconciled` means this timed-out
claim has not reconciled; `currentAttempt` rejects cancelled/older attempts;
`authorizedAnswerPending` additionally requires a permit and prepared media;
`authoritativeAndPrepared` requires the configured connection report and preparation;
`mediaNotReady` retains that report; `bufferedConnected` applies it after preparation;
`live` excludes terminal ownership; `aliasAvailable` enforces binding uniqueness;
`supported` requires capability and completed native/media application;
`firstTerminalIntent` owns the first accepted end; `previewPolicy` requires an `answeredElsewhere`
reason and enabled preview policy on that same `remoteEnd` input; otherwise the terminal fallback wins.
`mediaReleased` means owned media cleanup is observed; `always` needs no additional guard.
`outgoingDeferred`/`outgoingEager` select the preparation policy; `outgoingPrepared` and
`preparedJoin` require current successful preparation for their placement origin. `noAnswerPending`
excludes a call whose Answer or authoritative connected report already owns progress.

Effects are ordered requests or observations, not optimistic state. Eager placement waits for
preparation; deferred placement may start without it. `prepareMedia` completion returns
as a new input before any dependent settlement. `settleAction`/`rejectAction` act only on a still
pending receipt, exactly once. `closeMedia` immediately closes gates and cancels preparation;
`requestRemoval` owns independent system cleanup. `publish` exposes confirmed state. Alias drain
preserves receive order. An admission raced by an end must apply that end before any ringing
publication; preview-join failure restores its previous preview and releases only that attempt.
Successful owned media release permits logical `ended` even if platform removal is still pending;
later system removal updates independent cleanup evidence without rewriting terminal state.
Effect names include engine-owned timer work before calling external ports: admission/native
start arm no-answer, placement requests arm placement, and claim requests cancel no-answer and
arm the shared Answer deadline. Preparation arms its bounded attempt; connection/reconnection
have their named timer effects. Leaving a stage cancels its timer generation. Ports do not own
or extend product deadlines, and a cancelled generation cannot affect a later attempt.

## Actions and authority

Start reserves the canonical ID and asks placement; Join applies only to a preview and also asks
placement. Answer applies only to ringing and never asks a JS placement handler. End declines a
ringing call or hangs up a participating call. Hold/mute/video/tones are native-performed actions;
the app is informed after application. Unsupported actions fail explicitly. Pre-connect outgoing
hold cannot imply remote answer. Video changes never implicitly authorize camera capture.

Native Answer authority has `allow`, typed `refuse`, timeout and one bounded reconciliation.
A timeout emits `claimTimedOut`, then reconciles with the same action idempotency key. Allow may
recover within the remaining budget; known refusal stays distinct; unknown fails `claimTimedOut`.
Late permits are released. All paths settle exactly once without waiting for JavaScript.
Refusal rejects system Answer; this version records a failed end with typed `refused` cause.
The optional HTTP authority and secure credential transport are implementation work, not test input.

`whenProvided` starts native dialing after placement; later media credentials have no placement-to-
media deadline. Only an explicit application connected report commits outgoing connection. An early
report waits under the connection budget, never a fresh placement/media-wait timer. Multiple lines
may ring while one call participates. A second Answer needs an available slot; explicit hold/end
of the first call precedes Answer of the waiting call. Native system capacity remains a separate limit.
Outgoing Start/preview Join reserve the slot while `placing`; unheld `dialing`, `connecting`,
`connected` and `reconnecting` retain it. Pending Answer also reserves it while claiming/preparing.
An app request without a slot returns `refused(notAllowed)` before placement/claim, leaving a
waiting incoming call ringing. Reservations are global across lines and released by hold/end or
failed placement/authorization, independently of eventual system removal.

## Termination and errors

The first accepted terminal intent wins, local or remote. Duplicate End returns the original
receipt; later remote ends may finish cleanup but cannot replace the reason. Server-only ends
never fabricate a performed local End. `answeredElsewhere` is the single ownership fact, either
terminal or a preview under policy. A valid end received before admission/binding is retained
within the bounded event window and applied first. Matching duplicate event IDs have no new effects.

Reasons are `localDeclined`, `localEnded`, `remoteEnded`, `unanswered`, `answeredElsewhere`,
`declinedElsewhere`, `filtered(cause)` and `failed(error)`. Failure always includes a typed error.
Map `unanswered` to incoming missed and outgoing remote/no-answer. Transactional Android maps
`answeredElsewhere` to REMOTE, preserving the domain reason; iOS and legacy mappings stay adapters.
Logical terminal intent, media release, system removal and visible notification removal remain
independent evidence. A failed observation is unknown, not successful cleanup or an absent call.

Errors discriminate unknown call, invalid transition, unsupported capability, missing permission,
refusal, unavailable authority, claim timeout, placement failure, stage deadline, media stage/cause,
alias conflict, invalid budget configuration, system failure and bridge availability. Do not parse
messages to select behavior. `RemoteEnd` excludes local reasons and filtering; those belong to
local actions/presentation. Schema-shaped diagnostics never include credentials or raw server text.

## Budgets

All durations are positive safe integer milliseconds, represented as native Duration values.

| Budget | Default | Anchor |
| --- | ---: | --- |
| Answer total / claim / reconciliation / reserve | 4500 / 2500 / 500 / 500 | Original Answer receipt; stages share its absolute deadline |
| Placement | 10000 | Start/Join placement request; also capped by effective system action deadline |
| Incoming ring / outgoing no-answer | 45000 / 45000 | Admission; bounded by service invitation expiry |
| Media preparation | 5000 | Preparation starts, also capped by any enclosing action |
| Audio activation / recovery | 10000 / 5000 | Taking part / end of interruption or reset |
| Connection / reconnection | 30000 / 15000 | Connection attempt / transport loss after connection |

Startup validates each duration, `claim + reconciliation + reserve < total`, and total against
that adapter's effective action deadline. Wire decoding validates allocation without assuming an
Android deadline on iOS. Runtime action deadlines can only shorten these bounds. No retry resets
an anchor. No-answer stops when Answer owns its action; deferred media does not arm preparation
until provided. Host observation allowances never change these product budgets.
