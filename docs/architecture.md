---
status: accepted
---
# SDK architecture

This is the accepted design for [one iOS and Android SDK](adr/0013-one-sdk-for-ios-and-android.md).
Its API sketches are the intended contract, refined by the shared specification. They do not
describe additional capabilities of the current release, which ships the Swift SDK, iOS Expo
binding, simulator tools and an experimental Exact integration.

## Layers

Dependencies point toward the core. Bindings translate contracts and compose adapters; they
do not own calls. One native runtime per app process serves every binding.

| Layer | iOS | Android | Responsibility |
| --- | --- | --- | --- |
| Domain and execution | `VoIPCore`, pure reducer and isolated engine | `:core` pure JVM reducer, `:runtime` coroutine engine | Identity, state, policies, commands, events, deadlines and effects; no UI, Expo or React Native |
| System calls | `VoIPLiveCommunicationKit` | `:system`, Core-Telecom adapter | Admission, system actions, settlement and confirmed system state |
| Push | `VoIPPushKit` | `:push-fcm` | Native launch intake, decoding, deduplication, reporting obligations, registration and health observations |
| Answer authority | `AnswerAuthority`, optional `VoIPHTTPAuthority` | `AnswerAuthority`, optional `:authority-http` | Bounded native ownership claim, reconciliation and release |
| Presentation and audio | `VoIPNotifications`, `VoIPLiveActivity`, `VoIPFocus`, `VoIPAudio` | `:system` notification/service and endpoint adapters | Platform UI, execution lifetime, routing and audio authority |
| Media | `CallMedia`, optional integrations | `CallMedia`, `:media-livekit`, `:media-webrtc` | Preparation, transport, publication gates and release |
| Bindings | SPM, `expo/ios`, `exact/apple` | Maven, `expo/android`, `exact/android` | Typed mapping to the same runtime |
| Testing | `VoIPTesting`, `VoIPSimulator`, optional `MediaTesting` | `:testing`, `:emulator-runtime`, optional media hooks | Deterministic fakes, system qualification and observed media |

Keep the root Swift package and module names. `VoIPCore` uses portable Foundation types and ports,
without UIKit, AVFAudio, LiveCommunicationKit or bindings. The Kotlin core has no Android types,
including `Context`, `Bundle`, `Uri` or Telecom types; neither core inherits a framework's model.

## One domain contract

The normative contract starts in M1a: `spec/domain.md` defines meaning/invariants,
`spec/model.schema.json` serialization/validation, `spec/transitions.json` transition cases,
and `spec/journeys/` behavior. Changes update these together. Swift enums, Kotlin sealed types
and TypeScript unions implement this contract rather than competing specifications.
Shared fixtures align hand-written types with `spec/model.schema.json`, without code generation.
Every valid fixture decodes/re-encodes to identical canonical JSON in Swift, Kotlin and TS;
invalid fixtures fail. Canonical JSON fixes key/value representation while preserving opaque IDs.
TS type fixtures accept every valid case and reject every invalid one through `tsc`, `satisfies`
and `@ts-expect-error`, complemented by runtime value checks. Use existing Swift/TS tools and
Gradle/Kotlin only. M1a adds fixtures/TS round-trips; native gates follow as their types land.

### Entities and identity

- `CallID` is the app's canonical ID for both directions and every device, supplied before placement
  ([ADR 0004](adr/0004-call-id-across-devices.md)). Services propagate it; platform UUIDs stay private.
- `RemoteCallID` is an optional service alias returned later. `bindRemote` atomically binds it
  to an existing call; repeating the same binding succeeds, replacing it or binding it to a
  second live call fails with `remoteIdentityConflict`. Apply buffered alias events in receive
  order, deduplicated. Services assigning their own ID use `bindRemote`; calls are never renamed.
  Invitations to other devices carry the canonical app ID alongside any remote alias.
- `AccountID` and `LineID` select the app's calling identity and displayed line label. Lines share
  admission: one participating call by default, with explicit hold/end-and-answer arbitration,
  rather than independent audio sessions or system capacity.
- A `Party` has an app identity, a discriminated phone/email/opaque handle and display data.
  `Handle.opaque` explicitly supports SIP URIs and short codes without reinterpreting them.
  Metadata is bounded JSON supplied by the app; it never drives SDK control flow or stores credentials.
- `EventID`, `ActionID` and `AttemptID` distinguish server redelivery, user intent and an
  asynchronous attempt. Private system identifiers never substitute for these identities.

Retain bounded deduplication, bindings and terminal outcomes: initially 120 seconds and 256
terminal records, limited by both. Reconcile on launch; disk state alone cannot restore a call.
Services retain canonical IDs through their redelivery window. Credentials stay out of observations.

### State and transitions

Lifecycle is separate from hold, microphone state, media preparation and video. Unholding cannot
invent connection. The connection authority writes `connectedAt` once, preserving it on reconnect.

| Input and precondition | Next lifecycle | Required effect or outcome |
| --- | --- | --- |
| New incoming invitation | `reporting` | Reserve identity and capacity; satisfy the platform's reporting rule |
| Report admitted | `ringing` | Publish actual presentation result; do not claim audibility |
| Filtered or preview policy | `previewing` or `ended` | Typed cause and policy; never retry ringing to bypass filtering |
| App starts outgoing | `placing` | Ask the placement authority; reserve canonical ID before asynchronous work |
| Placement succeeds | `dialing` | Bind optional remote alias; complete system start without claiming connection |
| Answer on a ringing call | `connecting` after authorization and settlement | Native authorization when configured; prepare required media and settle once |
| Join a preview | `placing`, then `connecting` | App places the join; failure returns to the same preview with a typed outcome |
| Authoritative connected report | `connected` when required readiness is met | Record connection once; Android requests active only at this boundary for outgoing calls |
| Transport loss after connection | `reconnecting` | Retain identity and first connection time; arm recovery deadline |
| Transport recovers | `connected` | Cancel recovery generation; preserve hold and mute |
| Hold, mute, tones or video | Lifecycle unchanged | Apply the appropriate native/media effect; publish only confirmed change |
| Local or authoritative remote end | `ending`, then `ended` | Close media gates immediately, cancel attempts and settle pending work once |
| Terminal state receives late work | `ended` | Ignore stale completion; retain original terminal reason |

Transitions cover admission/action races, capacity, reset, interruption and stale generations.
`ending` separates logical end from system removal; media stops even if system removal fails.
Retain that failure as a typed platform diagnostic, never a resurrected call.

The reducer serializes inputs; the first accepted terminal intent wins, local or remote.
Later ends may finish cleanup but cannot rewrite that reason; duplicate End returns its receipt.
Retain pre-admission/pre-binding server events within the configured bound. `answeredElsewhere`
ends participation or starts a preview under policy, never a local Answer or a competing
`remoteAnswered` flag. Disable pre-connect outgoing hold if the system cannot resume dialing
without implying remote answer.

Actions are start, answer, join, end, hold, mute, tones and video requests; connection, parties,
ownership elsewhere and remote termination are facts. Outcomes distinguish admitted, previewed,
filtered, hidden, capacity and failure. End reasons distinguish local decline/hangup, remote end,
unanswered, answered/declined elsewhere, filtered and failed with a required cause. `unanswered`
maps incoming to missed and outgoing to remote no-answer in the system adapter.

### Authority and budgets

[ADR 0003](adr/0003-native-actions-app-informed.md) remains the default: native code performs routine
actions and informs the app without waiting for JS. Outgoing placement and preview joins need
an app placement authority; push reporting never waits for JS.

ADR 0003 is refined by optional **native** `AnswerAuthority`, registered before push intake.
It receives call/line/action/attempt IDs, a monotonic deadline and cancellation; it returns
`allow(ClaimPermit)` or a typed refusal (`answeredElsewhere`, `declinedElsewhere`, `notAllowed`).
JS can select an authority but cannot run killed-app authorization. Hold, mute and End never wait on it.

The optional built-in **native HTTP answer authority** serves Expo-only apps without custom native
code. Typed plugin configuration installs its HTTPS endpoint and credential reference before push
intake. A write-only native API provisions/rotates credentials during onboarding; Answer reads them
from iOS Keychain or encrypted Android storage backed by Keystore, never JS or plugin configuration.
Secrets stay out of observations/logs. Inaccessible storage returns `authorityUnavailable` without
prompting. Match accessibility to locked-device support; qualify pre-first-unlock separately.
[Keychain](https://developer.apple.com/documentation/security/keychain-services), [Keystore](https://developer.android.com/privacy-and-security/keystore),
[Android storage availability](https://developer.android.com/privacy-and-security/direct-boot).

The [HTTP Answer contract](../spec/v1/http-authority.md) defines claim, reconciliation and
release with a single per-action idempotency key and correlated decisions.
An allow response may supply scoped media credentials directly to the selected native `CallMedia`,
without crossing JS, so the built-in media path needs no custom native credential-fetch code.
Network work on the Answer decision spends the same absolute budget. Bounded Release cleanup
never extends system settlement. M3 ships the built-in and custom native authorities.

| Budget | Default | Meaning |
| --- | --- | --- |
| Answer total | 4500 ms | Authorization, required preparation and native settlement together |
| Initial claim | 2500 ms | Maximum initial service claim attempt |
| Reconciliation | 500 ms | Exactly one idempotent authority query after claim timeout |
| Settlement reserve | 500 ms | Reserved within the total for native completion |
| Incoming ring / outgoing no-answer | 45 s | Separate invitation/dial lifetime, bounded by server expiry |
| Media preparation once begun | 5 s | Also bounded by any enclosing action's remaining budget |
| Connection / reconnection | 30 s / 15 s | Starts at the specified connection attempt, not at deferred placement |

Use validated `Duration` policies. At startup reject budgets that do not fit the total and each
adapter's effective deadline; every stage/retry spends the same absolute budget. These defaults
are SDK policies, not OS measurements. Core-Telecom's documented 5-second callback limit cannot
be extended by configuration. [CallsManager reference](https://developer.android.com/reference/kotlin/androidx/core/telecom/CallsManager)

Timeout emits `claimTimedOut` and reconciles once with the same key. A permit within the remaining
budget may recover; a competing owner produces typed refusal; unknown remains `claimTimedOut`.
Discard and release late permits. Settle the system action exactly once, rejecting/disconnecting
on failure. Only the service's single-winner decision authorizes this device to publish media.

Outgoing media prepares during placement or `whenProvided`. The latter admits `dialing`, accepts
later native credentials through `provideMedia`, and has **no placement-to-media deadline**;
separate no-answer/action budgets still apply. Placement can be prompt local approval, followed
by service allocation, `bindRemote` and media supply. Only an explicit connected report requests
connection; activation cannot substitute. Hold an early report in `connecting` under its readiness
budget. M3 changes Swift's eager preparation on iOS and implements Android's equivalent in the cores.

## System and media adapters

Keep Apple framework details in their existing modules. Attach observers/authorities before push
intake and report required calls before PushKit returns. Preview-only delivery uses ActivityKit.
Preserve [audio ownership](adr/0007-sdk-configures-audio-session.md) and
[bounded background work](adr/0011-background-time-after-pushes.md). Filter causes stay observed
or unknown; Android DND never becomes Apple's Focus filter state.

Core-Telecom owns Android admission/control/endpoints. Default to compatibility on API 26–33 and
transactional on 34+, recording the registration compatibility bound in the profile. `addCall`
lasts for the session; control-block entry acknowledges admission and endpoints may arrive later.
App/system Answer share one receipt, preventing recursive callback echoes. The adapter owns
CallStyle and a `phoneCall` foreground service, posting within the five-second admission window,
without an Activity or JS. [Core-Telecom guide](https://developer.android.com/develop/connectivity/telecom/voip-app/telecom)
Declare `MANAGE_OWN_CALLS` and required FGS permissions/types; microphone/camera retain their
while-in-use restrictions. Telecom diagnostics must accept transactional UUIDs and legacy IDs;
unknown or failed observations cannot establish absence of a call.
[Foreground-service requirements](https://developer.android.com/develop/background-work/services/fgs/service-types)

FCM's versioned native decoder accepts forwarded messages/token updates from an existing service,
leaving unrelated messages alone. Validate identity/expiry before admission. High priority allows
limited processing, not unlimited execution; synthetic intake cannot qualify real delivery.
[FCM priority](https://firebase.google.com/docs/cloud-messaging/android-message-priority)

Android admission may coexist with DND silence. Preserve phone/email identity for contact/repeat
rules; labels are not contact matches and duplicates are not repeat calls. Without existing policy
access, caller filtering may remain unknown. Do not request contacts/listener access to infer it.

`CallMedia` prepares transport without microphone publication/playback, applies hold/mute/video
gates and observes connection/packets. Release each prepared attempt once; failed/cancelled
preparation cleans partial resources. Optional ringing prejoin keeps capture/output closed;
authorization promotes/replaces it without overlapping publishers. Prewarm failure may leave
ringing intact; Answer preparation failure is `mediaFailed(stage)`. Activation, connection and
first packets remain separate.
Media adapters leave focus/mode to Telecom, with separate capture/output gates. Distinguish remote
departure, reconnect failure and local release; detach retired observation before release can echo End.

LiveKit uses scoped credentials or a native provider; WebRTC uses app-native signaling/sessions,
without a universal SDP server. Providers are optional and credentials stay out of JS observation.
Application-owned transport uses native audio coordination and typed reports but cannot promise
media before its runtime attaches. Never connect a second JS room for native-owned media.
Core libraries resolve neither LiveKit nor WebRTC by default.
Tones require a registered media/signaling transport; Core-Telecom itself carries no DTMF.

Use observed Core-Telecom endpoint flows and `requestEndpointChange`; do not race them with
direct `AudioManager` route changes. Prefer an existing user choice, then a private route and
the earpiece for audio. Expose unavailable endpoints honestly. On iOS only the system activates
the session. Android translates active/inactive and audio-focus observations into native media
gates. [Endpoint API](https://developer.android.com/reference/androidx/core/telecom/CallControlScope)
Optional Android proximity handling follows observed active audio and private-route state.
Provider network-monitor overrides are explicit opt-ins for constrained networks, with their
handover tradeoff documented and tested; never disable monitoring globally.

Video requests negotiate media and report system changes, confirming state only after observation;
partial application needs rollback/failure. Incoming video never opens capture without permission
and authorization. Core-Telecom 1.1's `requestCallType`/`callTypeFlow` depend on the OS path; expose
per-call capability. iOS has no system video action.
[Core-Telecom release notes](https://developer.android.com/jetpack/androidx/releases/core#core-telecom-1.1.0)

| Android path with Core-Telecom 1.1 | Mid-call video contract |
| --- | --- |
| Legacy API 26–33; newer APIs only with an explicit compatibility override | App/server requests; no genuine mid-call system bridge |
| Transactional API 34 | Unavailable: a successful request may update Core's local type without applying platform video |
| Transactional API 35–36 | App/server requests and system downgrades; unsolicited upgrades are reverted upstream |
| API 37+ | Source-described behavior needs runtime qualification before enabling system upgrades |

Type flows lack request ID/origin: distinguish requested origin from best-effort observation
correlation. Core's speaker fallback can override an older receiver preference; downgrade does
not automatically restore it. Retain route intent and actual outcomes.
[Platform-path constraints](https://github.com/relayphone/expo-callkit-telecom/blob/debc37a13119de76f0f26a31cb7257ad487fe8d7/docs/contracts/android-video.md).
Transactional ends use LOCAL/REMOTE/MISSED/REJECTED; preserve domain `answeredElsewhere` while
mapping to REMOTE. Observe system removal and visible notification removal separately.

### Notifications and timing

Native localized descriptors cover `ringing`, `authorizing`, `dialing`, `connecting`, `connected`,
`held`, `reconnecting`, `ending` and `missed`: title/body, line, tap destination and legal extra
actions. `dialing` says “Calling…” until reported connection. Descriptors/native callbacks work
before JS and can update later. Custom actions use typed registered IDs and validated payloads.

Android starts with a plain FGS Hang Up fallback, retaining it if CallStyle promotion is refused.
Reconcile shedding without repeated ringing; coalesce updates and respect rate limits. One FGS
notification does not make secondary/ending cards eligible. Queued service starts still require
timely promotion if the roster empties. Body taps open the app; Answer uses a direct Activity
intent, avoiding trampolines, while authorization continues. Measure to Activity resume with a
<150 ms acceptance target on the qualified reference device, independently of Answer completion.

Preserve Android's required, system-labelled Answer/Decline/Hang Up buttons. Full-screen denial
retains heads-up/ordinary notification and typed readiness. App descriptors customize SDK-owned
Apple notifications/previews, not arbitrary system call UI text.
[CallStyle](https://developer.android.com/develop/ui/views/notifications/call-style),
[full-screen intent eligibility](https://developer.android.com/about/versions/14/behavior-changes-14#secure-fsi-notifications).

Timing rows cover push/decode, admission, notification, UI resume, claim/reconciliation,
placement, preparation, audio eligibility, activation, connection, first packets and teardown.
Each carries call/action/attempt IDs, stage, boundary, outcome and monotonic clock identity:
Android `elapsedRealtimeNanos`, iOS's observation clock. JS delivery is a separate boundary.
Missing observations remain missing; never subtract different clocks or include credentials.

Push health distinguishes registration/rotation/invalidation, presentation readiness and
delivery evidence. Registration alone does not establish delivery; offline, registration
failure, missing probes and unknown delivery are distinct. Public FCM/APNs APIs do not expose
every transport backoff: report observations rather than inventing retry estimates or causes.
Token generations and service acknowledgements reject stale uploads after rotation.
[FCM token lifecycle](https://firebase.google.com/docs/cloud-messaging/manage-tokens)

## TypeScript API

Keep `expo/src`'s immutable snapshots/events, native actions, placement cancellation and app IDs.
Replace mixed optional state, overloaded Answer/Join, divergent handlers, raw IDs and message-parsed
errors with discriminated types. Hold is independent of connection; failed ends require a cause.
Replace `unhandledAction: "accept"` with explicit placement authority.

Use call terminology, retaining the private `VoIPConversations` registration name. `/react` hooks
share the store; `/types` loads without native code. Every exported member needs native mapping,
behavior tests and a capability entry, including real prewarm diagnostics. Merge/unmerge needs a
specified media mixer and tested adapters before publication.

These sketches define the intended API; supporting record types come from the domain spec.
Free-form strings are display data or opaque identities, never state/action/error selectors.

```ts
type ID<K extends string> = string & { readonly __kind: K };
type CallID = ID<'call'>;
type RemoteCallID = ID<'remoteCall'>;
type EventID = ID<'event'>;
type ActionID = ID<'action'>;
type LineID = ID<'line'>;
type Milliseconds = number & { readonly __kind: 'milliseconds' };
type Result<T, E> = { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };
type Handle = { readonly kind: 'phone'; readonly e164: string }
  | { readonly kind: 'email'; readonly address: string }
  | { readonly kind: 'opaque'; readonly value: string };
type CallError =
  | { readonly kind: 'unknownCall'; readonly callID: CallID }
  | { readonly kind: 'invalidTransition'; readonly state: LifecycleKind }
  | { readonly kind: 'unsupported'; readonly feature: Feature }
  | { readonly kind: 'permissionRequired'; readonly permission: 'microphone' | 'camera' }
  | { readonly kind: 'refused'; readonly reason: RefusalReason }
  | { readonly kind: 'authorityUnavailable'; readonly cause: AuthorityFailure }
  | { readonly kind: 'claimTimedOut'; readonly actionID: ActionID }
  | { readonly kind: 'placementFailed'; readonly cause: PlacementFailure }
  | { readonly kind: 'deadlineExceeded'; readonly stage: TimedStage }
  | { readonly kind: 'mediaFailed'; readonly stage: MediaStage; readonly cause: MediaFailure }
  | { readonly kind: 'remoteIdentityConflict'; readonly remoteID: RemoteCallID }
  | { readonly kind: 'invalidConfiguration'; readonly field: ConfigurationField }
  | { readonly kind: 'systemFailed'; readonly cause: SystemFailure }
  | { readonly kind: 'bridgeUnavailable' };
type EndReason = { readonly kind: 'localDeclined' | 'localEnded' | 'remoteEnded'
    | 'unanswered' | 'answeredElsewhere' | 'declinedElsewhere' }
  | { readonly kind: 'filtered'; readonly cause: FilterCause }
  | { readonly kind: 'failed'; readonly error: CallError };
type Lifecycle =
  | { readonly kind: 'reporting' | 'ringing' | 'placing' | 'dialing' | 'connecting' }
  | { readonly kind: 'previewing'; readonly reason: PreviewReason }
  | { readonly kind: 'connected' | 'reconnecting'; readonly connectedAt: Timestamp }
  | { readonly kind: 'ending'; readonly reason: EndReason }
  | { readonly kind: 'ended'; readonly reason: EndReason; readonly endedAt: Timestamp };
type LifecycleKind = Lifecycle['kind'];
type Call = Readonly<{
  id: CallID; remoteID?: RemoteCallID; line: CallingLine;
  direction: 'incoming' | 'outgoing'; parties: readonly Party[];
  lifecycle: Lifecycle; held: boolean; muted: boolean;
  video: VideoState; media: MediaState; capabilities: CallCapabilities;
}>;
type Action = { readonly kind: 'answer' | 'join' | 'end' }
  | { readonly kind: 'hold'; readonly held: boolean }
  | { readonly kind: 'mute'; readonly muted: boolean }
  | { readonly kind: 'video'; readonly enabled: boolean }
  | { readonly kind: 'tones'; readonly digits: readonly DTMFDigit[] };
type PlacementResult = { readonly kind: 'placed'; readonly remoteID?: RemoteCallID }
  | { readonly kind: 'refused'; readonly reason: RefusalReason };
type AnswerBudget = Readonly<{
  total: Milliseconds; claim: Milliseconds;
  reconciliation: Milliseconds; settlementReserve: Milliseconds;
}>;
type CallingPolicy = Readonly<{
  answer: { kind: 'immediate' } | { kind: 'nativeAuthority';
    authority: ID<'nativeAuthority'>; budget: AnswerBudget }
    | { kind: 'http'; endpoint: HTTPSURL; credential: CredentialRef; budget: AnswerBudget };
  outgoingMedia: { kind: 'duringPlacement' } | { kind: 'whenProvided' };
  connectionAuthority: 'application' | 'nativeMedia';
}>;
type PushHealth = Readonly<{
  registration: { kind: 'registering' | 'invalidated' }
    | { kind: 'registered'; generation: number; token: PushToken }
    | { kind: 'failed'; error: PushRegistrationError };
  delivery: { kind: 'unknown' }
    | { kind: 'observed'; evidence: DeliveryEvidence; at: Timestamp }
    | { kind: 'degraded'; reason: PushHealthIssue; evidence: DeliveryEvidence };
}>;
```

`CallingLine` includes account, line and label. `VideoState` separates confirmed type, capture
gate and pending change. `MediaState` separates owner, preparation/activation/release and transport.
Schema variants constrain direction/state and connection history. Constructors validate IDs,
E.164, durations and DTMF; apps do not cast brands. `SystemFailure` is a platform-tagged union,
with optional diagnostic native codes. Bootstrap installs `CallingPolicy` before push intake;
exactly one connection authority reports call progress while native transport stays observable.

```ts
interface CallsClient {
  snapshot(): CallsSnapshot;
  observe(options?: { readonly after: Cursor }): AsyncIterable<Observation>;
  subscribe(listener: (observation: Observation) => void): () => void;
  start(input: StartCall): Promise<Result<Performed, CallError>>;
  perform(id: CallID, action: Action): Promise<Result<Performed, CallError>>;
  bindRemote(id: CallID, remoteID: RemoteCallID): Promise<Result<void, CallError>>;
  receive(event: RemoteEvent): Promise<Result<Received, CallError>>;
  reportIncoming(input: IncomingInvitation): Promise<Result<IncomingOutcome, CallError>>;
  setPlacementHandler(handler: PlacementHandler | null): void;
  audio: AudioAPI;
  permissions: PermissionsAPI;
  push: PushAPI;
  credentials: NativeCredentialWriter;
  platform: { readonly kind: 'ios'; readonly ios: IOSFeatures }
    | { readonly kind: 'android'; readonly android: AndroidFeatures };
}
type PlacementHandler = (request: PlacementRequest, context: {
  readonly signal: AbortSignal; readonly remaining: Milliseconds;
  readonly actionID: ActionID;
}) => Promise<PlacementResult>;
type RemoteEvent = Readonly<{ eventID: EventID; target:
  { readonly kind: 'call'; readonly id: CallID }
  | { readonly kind: 'remote'; readonly id: RemoteCallID }
}> & (
  | { readonly kind: 'connected' }
  | { readonly kind: 'ended'; readonly reason: RemoteEndReason }
  | { readonly kind: 'partiesChanged'; readonly parties: readonly Party[] }
  | { readonly kind: 'videoRequested'; readonly enabled: boolean }
);
```

`StartCall` requires canonical ID, line, parties and initial media intent. `Performed` carries
action ID and completion cursor: placement/native start, authorized native Answer or confirmed
video application, never just queuing or connection. All expected failures resolve as `Result`;
normalize handler exceptions and reject stale generations. Swift/Kotlin supply media through
`provideMedia(CallID, NativeMediaCredentials)`; JS has no media-credential setter.

Observation atomically attaches before hydration, returning an epoch/sequence snapshot followed
by ordered revisions/events with action/attempt correlation. Payloads include `actionPerformed`,
`incomingOutcome`, `claimTimedOut`, `mediaActivated`, `transportConnected`, `videoChanged`, `ended`,
`dialRequested` and `timing`. The app assigns an ID for system dial intent. New epochs/expired
cursors return `resyncRequired` with state; bounded terminal replay requires idempotent handling.
`subscribe(listener)` shares `observe()`'s store, hydration and ordering, with an idempotent
unsubscribe for that listener. `/react` hooks project the same store without another native client.
The [native and JavaScript bridge contract](../spec/bridge.md) defines the transport beneath this API.

`audio` separates requested from observed endpoints; `permissions` separates safe reads from
foreground prompts. `push` distinguishes APNs VoIP/FCM registration and delivery evidence.
`platform.ios` contains Focus/Live Activity features; `platform.android` contains full-screen/FGS
readiness and removal reconciliation. Retain remaining-system-call diagnostics. Common unsupported
operations return `unsupported(feature)`; optional capabilities use typed `available`/`unavailable`,
never null pretending a platform-only feature exists.

### Incoming push while the app is killed

Native startup registers media, custom/HTTP answer authority and presentation before push intake.
It uses the configured budget and completed permission onboarding; push delivery never prompts.

1. PushKit/FCM starts native intake of the canonical call ID, event ID, line and credential reference.
2. Report/adopt the call, present it and optionally prejoin with capture/output closed.
   Android Answer foregrounds the call screen immediately.
3. Native Answer claims/reconciles/prepares/settles within budget; refusal rejects and unknown
   timeout reports `claimTimedOut`. Media opens only with authority and system audio eligibility.
4. Report actual connection. Late JS hydrates state/outcomes without re-answering or another room.

```ts
import { calls } from '@relayphone/ios-voip-sdk'; // Intended API; package name unchanged.

// At JS attachment; the runtime already handled push and Answer natively.
for await (const observation of calls.observe()) {
  switch (observation.kind) {
    case 'snapshot': renderCalls(observation.snapshot.calls); break;
    case 'event': await synchronizeOutcomeIdempotently(observation.event); break;
    case 'resyncRequired': refreshFromService(observation.snapshot); break;
  }
}
```

### Outgoing placement, then media

The app obtains a canonical ID its service will propagate, selects a line and starts. Configure
`whenProvided` media and app-reported connection for this example. Application functions below
are illustrative, not additional SDK methods.

```ts
calls.setPlacementHandler(async (request, { signal, actionID }) => {
  return localDialPolicy.authorize(request, { signal, actionID }); // Prompt local approval.
});
const callID = newAppCallID();
const started = await calls.start({
  id: callID, lineID: selectedLine.id, parties: [alice], video: false,
});
if (!started.ok) {
  showCallError(started.error);
} else {
  const placed = await service.dial({ callID, actionID: started.value.actionID });
  const bound = await calls.bindRemote(callID, placed.remoteID);
  if (!bound.ok) showCallError(bound.error);
  // The native service integration supplies its credential through provideMedia.
  const answered = await service.waitForRemoteAnswer(callID);
  const connected = await calls.receive({
    target: { kind: 'call', id: callID }, eventID: answered.eventID, kind: 'connected',
  });
  if (!connected.ok) showCallError(connected.error);
}
```

The call stays `dialing` with “Calling…” until that report. Media activation alone leaves it
there. The placement promise never waits for a later credential or connection. No-answer expiry
ends with `unanswered`, mapped by direction; local End is idempotent even if a server end races it.

### Mid-call video upgrade

```ts
const permission = await calls.permissions.request({ kind: 'camera' }); // Foreground UI.
if (permission.ok && permission.value.kind === 'granted') {
  const changed = await calls.perform(callID, { kind: 'video', enabled: true });
  if (!changed.ok) showCallError(changed.error);
}
if (!permission.ok) showCallError(permission.error);
// The snapshot/videoChanged event confirms system type; media observations prove frames.
// A later downgrade closes capture before asynchronous unpublish and system cleanup.
await calls.perform(callID, { kind: 'video', enabled: false });
```

Native media checks permission/authority and preserves hold, mute and route intent. Remote video
uses the same operation; unsupported paths fail, and iOS emits no invented system action.
Tests require independent decoded frames and off/end privacy evidence.

## Kotlin standard and distribution

Use Kotlin 2.x, Kotlin DSL, a checked-in Gradle wrapper, Java toolchains and version catalogs in
`gradle/libs.versions.toml`, pinning compatible stable versions. Android uses minSdk 26 and compile
SDK 36+; the JVM core has no Android plugin. Use `kotlinx.coroutines`, StateFlow snapshots, Flow
events and `kotlinx.serialization`, with maintained platform/media libraries over reinvention.

The pure reducer maps `(state, input, instant)` to `Transition(state, effects)` without suspension.
One runtime serializes inputs; async effects return typed inputs with attempt generations. Use
sealed interfaces, immutable/value classes, exhaustive results and injected clocks/delay/durations.
Scope jobs by runtime/call/attempt and join teardown; no global jobs or untyped mutable domain maps.

```kotlin
sealed interface AnswerDecision {
    data class Allow(val permit: ClaimPermit) : AnswerDecision
    data class Refuse(val reason: RefusalReason) : AnswerDecision
}
interface AnswerAuthority {
    suspend fun claim(request: AnswerRequest): AnswerDecision
    suspend fun reconcile(request: AnswerRequest): ClaimState
    suspend fun release(permit: ClaimPermit)
}
```

Match Swift 6 strict concurrency and `Sendable` with coroutine ownership and immutable values;
typed throws with sealed results/errors; Observation/AsyncSequence with StateFlow/Flow.
Swift Testing/injected `Clock` correspond to JUnit 5/`kotlinx-coroutines-test`; AndroidX
instrumentation uses its JUnit runner. Use `Mutex` for small shared state, DocC/KDoc for public
APIs and behavior tests throughout. Untyped framework payloads are decoded at the boundary.

Publish `com.relayphone:voip-sdk` as a small Android facade AAR with transitive dependencies on
`voip-core` (JAR), `voip-runtime`, `voip-system` and optional push/media artifacts. Keep testing and
emulator runtime artifacts in test dependencies. All artifacts and bindings use the repository's
version and tag. Use Gradle's [`maven-publish`](https://docs.gradle.org/current/userguide/publishing_maven.html)
to produce POMs, Gradle metadata, sources and documentation alongside binaries.

| Publication | Benefit | Decision / cost |
| --- | --- | --- |
| GitHub release Maven repository archive | Public, version-pinned, matches current npm asset delivery | Initial delivery: verify, extract and declare a local Maven repository; include all internal transitive artifacts, not a bare AAR |
| Maven Central | Standard dependency resolution without consumer credentials | Stable releases later, after namespace, signing and required POM metadata; [requirements](https://central.sonatype.org/publish/requirements/) |
| GitHub Packages Maven registry | Repository-linked publication | Consumer authentication also applies to public packages; avoid making this mandatory for SDK users; [registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-gradle-registry) |

Verify archive checksums/provenance and smoke-build all internal transitive dependencies from
the extracted repository; external dependencies use Google/Central. Expo ships version-matched
Gradle and Swift sources without another registry/git pin. Exact uses the same tagged artifacts;
packaging must prevent duplicate runtime classes across bindings.

## Repository and CI

```text
Package.swift                    # Root SPM package; existing Swift module names
Sources/                         # Swift core, system adapters and simulator
Tests/                           # Swift behavior and mapping tests
MediaTesting/                    # Optional iOS media test hooks
android/
  settings.gradle.kts
  gradle/libs.versions.toml
  core/                          # Pure JVM domain and runtime
  sdk/                           # Maven entry point and native composition
  system/                        # Telecom, notifications, FGS, endpoints
  push-fcm/
  authority-http/                # Optional native HTTP ownership authority
  media-livekit/
  media-webrtc/
  testing/                       # Deterministic ports and virtual clock
  emulator-runtime/              # Test-only control, journal and faults
  test-app/                      # Instrumentation host, no Expo requirement
expo/
  src/                           # One public API, internal transport, React projections
  ios/
  android/                       # Expo mapping; depends on Android SDK modules
  plugin/                        # Typed per-platform configuration
  example/                       # Both platform consumers
exact/
  apple/                         # @exact/calls mapping to Swift
  android/                       # @exact/calls mapping to Kotlin
spec/
  domain.md
  model.schema.json
  fixtures/                      # Shared valid/invalid model fixtures
  transitions.json
  journeys/                      # One data definition per common journey
  capabilities.json              # Platform conditions and qualification references
tools/conformance/               # TypeScript host runner and platform drivers
docs/
```

Exact maps list operations to the core, with action-keyed echo suppression and native
push-created calls entering its list. Answer is not a connection report. Register dependencies
before push intake. Resolve Exact's production transport and startup limitations before claiming
production support; an empty media adapter or an untested bridge is insufficient.

Use standard GitHub-hosted runners: macOS for Swift/iOS and Linux with KVM for the Android
emulator. Public-repository standard runner compute is free; larger runners are unnecessary.
[Runner capabilities](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

| Gate | Executor | Scope |
| --- | --- | --- |
| Domain and TypeScript | Linux | Canonical fixture round-trips, valid/invalid type fixtures, `tsc`, `node:test`, API and packaging contracts |
| Swift host | macOS | `swift test`, Swift format, fixture round-trips, shared journeys and mapping tests |
| Kotlin host | Linux JVM | Fixture round-trips, JUnit + `kotlinx-coroutines-test`, reducer/fake journeys and Android lint/build checks |
| iOS integration | macOS, one simulator | Runtime, push cold start, native and Expo/Exact journeys, release exclusion |
| Android integration | Linux, one emulator per job | API 26 compatibility and API 34+ transactional coverage; notification, permission and lifecycle instrumentation |
| Media | Matching simulator/emulator jobs | Real provider connection, independent peer, audio/video/privacy oracles |
| Release consumers | Both | Packed npm consumer, extracted Maven repository and SPM/Exact consumer builds |

Run relevant gates and both for shared changes; pin images and cover API 26/34/current stable.
Emulators cannot qualify real Bluetooth/cloud push. Qualify executors, bound setup and distinguish
infrastructure/assertion failures. Keep compact diagnostics and clean up disposable local iOS clones.

## One test kit

`VoIPTesting` and Android `:testing` drive real reducers/engines with virtual time and fake ports,
including delay, timeout, refusal, duplicate/late callbacks, shedding and reset. This host gate
avoids emulator flakiness; StateFlow conflation cannot replace event evidence, and overflow fails.

Versioned journeys define policy/lines, inputs, clock advances, capabilities, state predicates,
ordered events and forbidden effects. For example:

```json
{
  "version": 1,
  "id": "incoming-answer-timeout",
  "requires": ["nativeAnswerAuthority"],
  "steps": [
    { "kind": "incoming", "callID": "call-a", "eventID": "invite-a", "line": "personal" },
    { "kind": "authorityBehavior", "claim": "neverCompletes", "reconcile": "unknown" },
    { "kind": "systemAction", "callID": "call-a", "action": { "kind": "answer" } },
    { "kind": "awaitOutcome", "callID": "call-a", "error": "claimTimedOut" }
  ],
  "expect": { "reconciliationCount": 1, "publishedMicrophones": 0, "settlements": 1 }
}
```

Validate journeys against the schema and run them through both native fakes and platform runtimes.
Host drivers advance virtual time; integration drivers await bounded native observations. Translate
controls, never oracles; assert SDK and independent system evidence. Skips do not count as parity.
Pair positive cases with missing/late/unapplied-action, leakage, stale-ID and observation controls.

Keep the iOS runtime's [measured profiles and enforcement](simulator-runtime.md); Android controls
native intake/faults and real Telecom/notifications. Exclude test controls from production.
Navigation needs genuine SystemUI taps, whose privileges differ from instrumentation sends.
Process death, force-stop and iOS force-quit differ; synthetic launch cannot prove push eligibility.

Reuse the [media contract](media-testing.md), its phase identity, independent peer, capture/output
gates, packet counters, decoded video, teardown and failure controls. State or absent samples
cannot prove media/silence. Qualify Android video limits independently of iOS; keep unmeasured
device behavior visibly unqualified.

### Contract safeguards

These named contracts and behavior tests are release gates, added with their implementations.

| Contract / test | Required rule |
| --- | --- |
| Identity and action contract | Preserve canonical IDs and identical action meanings; distinguish Answer from preview Join. Test duplicate/collision and late-binding paths. |
| Typed boundary round-trips | Decode external data into sealed/discriminated types; run all shared valid/invalid fixtures on every implementation. |
| Capability behavior contract | Export only implemented behavior. Test unsupported media tones, mixing, platform-only members and API 34 transactional video. |
| Observation stages contract | Keep provider acceptance, device receipt, admission, ringing, activation, remote connection, decoded media and physical output distinct. Test each claimed boundary independently. |
| Native lifetime contract | Register dependencies before push intake; test no-JS Answer, handler replacement, recreation, cancellation and stale media-owner completion. |
| Notification update contract | Coalesce unchanged/cosmetic updates, preserve lifecycle alerts, cancel trailing work and check each card's eligibility. Test observed post counts, latest content and shedding. |
| SystemUI navigation contract | Qualify genuine notification taps and Activity recreation; distinguish sender/creator launch privileges from instrumentation sends. |
| Deadline and clock contract | Name each budget, stage and monotonic clock; test deadline boundaries and clock mismatch. Observation allowances never extend product deadlines. |
| Terminal ownership contract | Retain end intent and independent media/system/UI cleanup evidence; test late removal, ID reuse and reconciliation. Missing/failed system observations cannot prove cleanup. |
| Presentation stimulus rule | Cosmetic-refresh tests change only cosmetic data and assert actual listener/post counts; video/type changes need separate real-action tests and failure controls. |
| Single-provider contract | Exactly one runtime/provider per process across native, Expo and Exact. Test duplicate startup and packaged/autolinked coexistence, not only individual bindings. |
| Qualification scope contract | Record API/backend/image/device and evidence kind for each capability. Test real platform identifiers, asynchronous endpoints and audio/video constant conversions; keep synthetic parser fixtures labelled and missing evidence unknown. |

## Parity and requirements

The reference is SDK 0.8.0 and [v2 alpha.18](https://github.com/relayphone/expo-callkit-telecom/releases/tag/v2.0.0-alpha.18).
The grouped inventory below records existing behavior, not a new implementation's pass.
Fill qualification placeholders with platform conditions, tests and release versions before parity;
retired options and declarations without behavior are excluded.

| Capability group | Reference behavior | iOS target | Android target | New qualification |
| --- | --- | --- | --- | --- |
| Intake, identity and state | Native incoming/outgoing, typed caller, duplicate/collision handling, revisioned hydration | Common contract | Common contract | Pending: shared state/capacity/race journeys |
| Placement and connection | Placement cancellation and staged reports; Android outgoing connection independent of media | Deferred-media policy | Deferred-media policy | Pending: late alias/credential, no premature connection |
| Actions, authority and end | Native actions/outcomes, ownership elsewhere, typed ends and retained removal failure | Bounded native authority | Bounded native authority | Pending: refusal/timeout/reconcile, terminal ordering/removal |
| Media and permissions | Native/application media ownership, receive-only prejoin, mute/hold/reconnect; foreground permission requests | CallMedia providers | CallMedia providers | Pending: actual peer audio, privacy and release controls |
| Endpoints, tones and video | Observed endpoints/proximity; media-backed tones; path-dependent video | Explicit capabilities | Explicit OS-dependent capabilities | Pending: route/tones and independently decoded video |
| Presentation and navigation | Apple filtering/previews/notifications; Android CallStyle/FGS, customization and direct Answer/body navigation | Existing Apple policy | Native Android policy | Pending: heads-up Answer to Activity resume <150 ms; DND, fallback, shedding, taps and recreation |
| Platform-only features | Apple Focus, Live Activities, system dial intent; no Android preview/merge implementation | Explicit feature namespaces | Unsupported until implemented | Pending: existing Apple journeys; honest Android capability results |
| Push, readiness and timing | APNs/FCM token lifecycle, expiry/fault intake, native timing; broad delivery health remains unknown | APNs evidence + health | FCM evidence + health | Pending: push-to-ring within platform reporting window; rotation, late JS, probes and readiness |
| Native and Expo distribution | Swift SDK and composed Expo API; Android implementation depends on that binding | Independent SPM + Expo | Independent Maven + Expo | Pending: packaged native/JS consumers |
| Exact and test kit | Exact iOS experiment; simulator, Android instrumentation/fakes and shared media contract | Exact + simulator kit | Exact + emulator kit | Pending: both Exact consumers and one conformance runner |

Generic integration requirements add the following acceptance criteria to that inventory.
Reference-application acceptance targets are Answer-to-Activity-resume <150 ms and native push
receipt to ringing within the platform reporting window. Use profile deadlines, distinguish cloud
send from receipt and permitted ringing from filtering. Earlier Activity-start observations do
not establish resume latency or audible ringing.

| ID | Requirement | Contract / API / configuration | Required test |
| --- | --- | --- | --- |
| R1 | Self-managed Android calls, heads-up/full-screen presentation and prompt Answer navigation | `:system`, notification readiness, direct Activity Answer intent; target <150 ms on reference device | Transactional emulator journey, denied full-screen control, device timing qualification |
| R2 | One device wins Answer; configurable bounded authority | Native `AnswerAuthority`, typed `AnswerBudget`, action idempotency key | Concurrent claims; refusal rejects; no JS dependency |
| R3 | Timeout differs from refusal; reconcile once | `claimTimedOut`, `refused`, one bounded reconciliation and late-permit compensation | Virtual-clock timeout/refusal/late-permit controls on both cores |
| R4 | Outgoing starts at placement; media may follow without a placement-to-media timer | `whenProvided`, native `provideMedia`, explicit `receive(connected)` | Remain dialing before report; delayed credential; no premature active/connected |
| R5 | Bind a remote identity after placement | Stable `CallID`, `bindRemote`, alias dedupe/buffering | Late binding, conflict, duplicate and end-before-binding journeys |
| R6 | Typed authoritative end reasons, strict ordering, idempotent End and direction-aware no-answer | `EndReason`, terminal intent ownership, adapter disconnect mapping | Every reason, local/server races, repeated End, incoming missed/outgoing no-answer |
| R7 | SDK-owned LiveKit credentials, warm subscribe and promotion | Optional native media provider, publication/output gates | Prejoin/promote, stale credentials, failed retirement, no overlapping publication |
| R8 | Activation and connection are separate; private audio default; video never flips implicitly | `MediaState`, audio API, connection authority, explicit video action | Distinct timing/event order, endpoint preservation, audio-only and upgrade |
| R9 | Notification refusal/shedding resilience, plain Hang Up fallback, body navigation and rate limits | Native notification state machine and presentation diagnostics | Refused post, shed notification, fallback, body tap and coalescing controls |
| R10 | App controls notification text and extra actions per state | Native presentation descriptors, legal typed actions and line labels | Dialing text before connected report; required system buttons preserved |
| R11 | Multiple account lines with one active call | `CallingLine`, `AccountID`, `LineID`, common admission policy | Cross-line waiting, hold/end-and-answer, displayed line, capacity rejection |
| R12 | Typed error causes and explicit budgets throughout | `Result`, sealed errors, duration policies, per-stage deadline category | Exhaustive mapping and timeout-vs-refusal contract tests |
| R13 | Push registration, token lifecycle and honest delivery health | `push` registration/delivery unions, token generations, probe evidence | Rotation/invalidation, stale upload, offline, missing probe and unknown backoff |
| R14 | Deterministic system-calling CI on both platforms | `VoIPTesting` and `:testing`, injected clocks and fault ports | Same journeys on hosts; integration qualification remains separate |
| R15 | Per-stage native timing usable by applications | Sequenced timing events, monotonic clock IDs, attempt/action correlation | Required boundaries, clock mismatches, overflow and late JS attachment |

Beyond parity, the shared suite prevents semantic drift, native/JVM use needs no JS runtime,
and typed capability/readiness results make unsupported behavior actionable. Parity does not
require inventing Apple Focus or Live Activities on Android or promising identical system UI.

### RelayPhone migration

One migration covers both platforms: qualify parity, replace the composed dependency, keep
canonical IDs/bind aliases, register native authority/media/presentation and adopt the common
snapshot/event API. Migrate handlers to placement/native Answer, translate typed reports/errors,
forward push/token lifecycle and expose delivery warnings.

Qualify killed-app Answer, deferred media, late binding, cross-line waiting, ownership elsewhere,
timeout/refusal, notification recovery, video and teardown on both platforms. Stage rollout with
whole-build rollback and one system-call owner. Retire the old library only after both pass;
then rename repository/npm and install links together, keeping Swift module names.

## Milestones

Each milestone releases usable artifacts with its tests; incomplete capabilities stay explicit.

| Milestone | Shippable result | Acceptance gate |
| --- | --- | --- |
| M1a. Spec v0 | Identity, lifecycle, actions, end reasons, errors and budgets; schema with valid/invalid fixtures; about eight journeys; host runner skeleton | TS fixture round-trip and type checks, journey decoding and transition validation |
| M1b. Conformance and fakes | Remaining policies/capabilities, native fixture round-trips and deterministic Swift/Kotlin test libraries | Same fixtures and journeys, real reducers, virtual-clock races and failure controls |
| M2. Android native calling | JVM core and Maven SDK with Core-Telecom, FCM intake and media-independent dialing | Host JUnit; API 26/34+ incoming/outgoing/end and notification/readiness instrumentation; archive consumer |
| M3. Native authority and media | Both platforms implement custom and built-in HTTP answer authorities, budgets, aliases, deferred credentials, LiveKit/WebRTC and timing; iOS changes eager preparation for `whenProvided` | Killed-app HTTP Answer without custom native code, secure-store failure, idempotency/timeout/refusal, binding, peer audio and teardown |
| M4. One Expo API | Packed module for both platforms, common TS API, config plugin and React projections | TS type/unit tests; native mapping tests; same JS journeys in simulator/emulator |
| M5. Exact on both platforms | `@exact/calls` implementation using those native artifacts | Exact host startup, push-created calls, action echoes, real media and production capability checks |
| M6. Full parity and migration | Qualified emulator/media kit, completed capability inventory and one migration guide | Shared positive/negative suite, independent Android video calibration and device-only qualification |
| M7. Final names and retirement | Repository/npm rename, final install paths and retirement notice | Clean SPM/Maven/npm/Exact consumers from the release; no duplicate provider/runtime |

M1a starts with eight journeys: incoming Answer/End, deferred outgoing placement/binding, answer
refusal, claim timeout, ownership elsewhere during admission, hold/mute/resume, video change and
local/server end races. Once it lands, Kotlin core work starts alongside M1b's remaining spec.
The call-oriented `Result` API ships as a breaking pre-1.0 release with a migration guide.
