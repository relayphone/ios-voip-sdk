# Proposed SDK API for Focus-aware calling

Proposal for [#124](https://github.com/ziahamza/ios-voip-sdk/issues/124), informed by the [platform findings](README.md). None of the additions below exists yet. Apple API availability and measured limitations are in the README. Existing SDK names are linked to their source; all new signatures are illustrative contracts, not a buildable patch. No SDK source change is part of this lane.

The Phone contract follows [phone-app#885](https://github.com/ziahamza/phone-app/issues/885) and the orchestrator's clarification: numbers use LiveKit SIP ([#458](https://github.com/ziahamza/phone-app/issues/458)), owner join/take-over already exists ([#456](https://github.com/ziahamza/phone-app/issues/456)), and server captions come from celld's SSE stream ([#858](https://github.com/ziahamza/phone-app/issues/858)). Use those services; do not create a second AI or captions pipeline.

## Typed incoming result and native policy

Retain [`ConversationClient.reportIncomingConversation(_:source:)`](../../../Sources/VoIPSDK/ConversationClient.swift) for compatibility. Add a result-returning sibling; the old method throws a typed filtered error for filtered outcomes. It must never return a successful conversation UUID for a failed report.

```swift
public enum IncomingFilterReason: String, Codable, Sendable {
  case focus, blockList, restrictedSharing, protectedCall, sensitiveParticipants
}
public struct IncomingFailure: Error, Codable, Sendable {
  public let domain: String
  public let code: Int
}
public struct FilteredIncomingContext: Codable, Sendable {
  public let invitationID: UUID       // UUID of the rejected incoming report
  public let generation: UUID         // one logical intake generation, not a retry
  public let serverCallID: String     // authenticated stable backend/SIP identity
  public let reason: IncomingFilterReason
  public let failure: IncomingFailure
  public let observedAt: Date
}
public enum IncomingPresentationResult: Sendable {
  case reported(conversationID: UUID)
  case filtered(FilteredIncomingContext)
  case failed(IncomingFailure)
}
public struct IncomingFilteredError: Error, Sendable {
  public let context: FilteredIncomingContext
}
// Proposed addition on the existing @MainActor ConversationClient:
public func reportIncomingConversationResult(
  _ payload: IncomingCallPayload, source: IncomingReportSource
) async -> IncomingPresentationResult

// Installed natively at application launch, before PushKit registration / JS.
public protocol FilteredIncomingHandler: Sendable {
  func didFilter(_ context: FilteredIncomingContext)
}
public enum FocusCallPolicy: String, Codable, Sendable {
  case decline, screenWithAI
}
```

`FilteredIncomingHandler` is a process-lifetime dependency proposed for `VoIPApplication.start`, alongside its existing configuration/media adapter. It runs on a native serial worker after report resolution and intake settlement, independently of MainActor, scene startup and JS. It must synchronously enqueue a small durable outbox record, then return; do not perform blocking HTTP, credentials lookup requiring UI, or AI work inside it. Dispatch its eventual JS event only after this native path. Use only copied `Sendable` values; do not pass LCK objects across actors.

Map `com.apple.CallKit.error.incomingcall` codes 3–7 to the five reasons in order. Inspect a bounded underlying-error chain as [`ConversationSystemErrors`](../../../Sources/VoIPSDK/ConversationClient.swift) already does; preserve unrecognized pairs as `.failed`. Existing code-2 duplicate-report coalescing is not a filtered outcome. Only `.focus` can select `screenWithAI` by default. Code 4 must not send a blocked caller to AI; codes 5–7 have conservative decline/no-screen policy until separately reviewed. An app/backend block always wins over AI screening.

Deduplicate at [`IncomingIntake`](../../../Sources/VoIPSDK/IncomingIntake.swift)'s logical invitation/generation boundary: one terminal result and one native callback, even if a duplicate push or report waiter arrives. Queue outside its lock. Key backend requests by `(serverCallID, action)` so process relaunch/retry cannot create two agents; reject expired invitations and authenticated identity mismatches. Use a persisted policy version, not the availability of JS or shared Focus status, to choose the backend disposition.

### Screening sequence

1. Server retains the SIP call and an explicit timeout/disposition policy. Deliver a genuine VoIP invitation with stable server identity.
2. PushKit's existing private-queue intake enters the native LCK report immediately, honoring `mustReport` metadata where present. Do not await Focus permission, JS, a network request or MainActor before report entry. Preserve existing completion-once and report-start/deadline behavior in [`PushService`](../../../Sources/VoIPSDK/PushService.swift) and [`IncomingReportTransport`](../../../Sources/VoIPSDK/IncomingReportTransport.swift).
3. On success, use the normal incoming conversation/action flow. On code 3, settle the failed incoming presentation and enqueue `decline` or `screenWithAI` through the native hook. Do not fulfill Join, capture audio, or keep a fake ringing LCK conversation for it.
4. A native outbox worker sends an authenticated, bounded request to Phone's backend. The backend atomically accepts AI ownership of the **existing** LiveKit room/SIP call or declines it. “Filtered” and “AI connected” are separate acknowledgments. The backend's own timeout/fallback handles suspension, network loss or missing callback; the measured process survival is not a background execution grant.
5. The backend publishes screening/caption snapshots and updates an already eligible Live Activity. It must not silently push-start a new one; see the start constraint below. The device needs no microphone or media room while AI screens. Failed/denied Live Activity presentation does not cancel backend screening.
6. User take-over starts an outgoing local conversation into that same room. Terminal history records the incoming filtering result and later owner participation separately.

## Focus status and filters

```swift
public enum FocusAuthorization: String, Codable, Sendable {
  case unsupported, notDetermined, restricted, denied, authorized
}
public enum SharedFocusState: String, Codable, Sendable {
  case unknown, notificationsSilenced, notificationsNotSilenced
}
public struct FocusStatusSnapshot: Codable, Sendable {
  public let authorization: FocusAuthorization
  public let state: SharedFocusState
  public let observedAt: Date
}
@MainActor public protocol FocusStatusObserving: AnyObject {
  var current: FocusStatusSnapshot { get }
  func requestAuthorization() async -> FocusStatusSnapshot
  func refresh() async -> FocusStatusSnapshot
  func updates() -> AsyncStream<FocusStatusSnapshot>
}
```

Implement with `INFocusStatusCenter` / optional `INFocusStatus.isFocused` (iOS 15). Map nil, unavailable or revoked access to `unknown`, never false. Prompt only from a user explanation screen with `NSFocusStatusUsageDescription`; receipt of a call must not prompt. Marshal permission completion to MainActor. Refresh at activation/authorization and accept validated `INShareFocusStatusIntent` deliveries from a compatible intents extension through an App Group. The stream reports sampled/delivered observations, not guaranteed background transitions or per-caller eligibility; show its age. No invented KVO/delegate contract.

An optional `SetFocusFilterIntent` (iOS 16) writes the app's `FocusCallPolicy` to shared storage; extension and main app use one versioned policy store. Changes apply to subsequent dispositions, not an already-owned AI call. Do not equate “filter configured” with globally knowing which Focus is active. Neither API disables Focus. Sharing status is optional for screening based on an actual filtered report.

## Silent Live Activity building block

The app owns a SwiftUI/WidgetKit extension and UI; an optional native module owns ActivityKit lifecycle/token observation. The core SDK must remain usable without a widget or ActivityKit. Existing LCK minimum is iOS 17.4; the content-based ActivityKit calls below require iOS 16.2, push-to-start 17.2, and interactive `LiveActivityIntent` 17.0 (see [availability audit](README.md#exact-local-sdk-declarations-and-ios-availability)).

```swift
import ActivityKit
import Foundation

@available(iOS 16.2, *)
public struct FocusTranscriptAttributes: ActivityAttributes {
  public let surfaceID: String        // opaque surface ID; no credentials
  public struct ContentState: Codable, Hashable {
    public let schemaVersion: Int    // 1
    public let sessionID: String?    // nil while user-armed monitoring is idle
    public let revision: Int         // safe integer, monotonic per surface (across calls)
    public let phase: String         // monitoring, screening, takeoverPending, ownerConnected, ended
    public let speaker: String?      // caller, agent
    public let excerpt: String?      // opt-in redacted tail, bounded UTF-8
    public let updatedAt: Int64      // Unix seconds; JSON wire format fixed
  }
}

// Foreground-only entry, unless a separately supported intent start is used.
// A pre-armed monitoring surface can later receive silent server updates.
@MainActor @available(iOS 17.4, *)
func beginVisibleTranscript(surfaceID: String,
                            state: FocusTranscriptAttributes.ContentState) throws
  -> Activity<FocusTranscriptAttributes> {
  try Activity.request(
    attributes: FocusTranscriptAttributes(surfaceID: surfaceID),
    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30)),
    pushType: .token)
}
```

Starting may be denied or unsupported. Return an explicit availability/error state and use the in-app transcript/history fallback. In the widget, render `context.isStale` as “Updates delayed”; never show a stale excerpt as current speech. Default Lock Screen content is “AI is handling a call”; caller identity and transcript require the owner's explicit preview opt-in. Expanded UI may show a short excerpt; compact/minimal Island UI should show state only. iPhone 13 only qualifies Lock Screen presentation.

### Server push-to-update and token handoff

The app cannot sustain captions SSE while suspended and the widget cannot network. Phone's server consumes its existing captions stream and sends ActivityKit **snapshots**, independently of foreground SSE. Apple's [push guide](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications) defines this transport.

Proposed native `TranscriptActivityService` exposes `capabilities()`, `start(sessionID:)`, `armMonitoringSurface()`, `end(surfaceID:)`, and token-registration delivery to a native authenticated sink. For every activity, observe `activity.pushTokenUpdates` as soon as discovered, including existing activities on relaunch (`Activity.activities` / `Activity.activityUpdates`). A token is asynchronous and can rotate. Upsert `{surfaceID, sessionID?, activityID, token, tokenVersion, environment, bundleID, frequentPushesEnabled, previewPolicy}` to an authenticated backend endpoint; version replacements and revoke old tokens. Keep a durable registration outbox. Never log tokens or put them in captions, URLs or Activity attributes. Persist eligibility/consent so relaunch does not accidentally enable previews.

**Start constraint:** Apple requires `aps.alert` for `event: start` pushes. Push-to-start cannot meet an unconditional silent-start promise and is disabled in silent screening mode. Start a call-specific activity while foreground, or let the user invoke a `LiveActivityIntent` to start one. For automatic silent updates during a later call, propose a user-armed monitoring activity: start it before Focus, register its per-activity token with `sessionID: nil`, then let the authenticated backend bind the next eligible call and update mutable `ContentState.sessionID`. Preview consent is fixed by the surface policy. This needs device qualification; it is not continuous monitoring runtime. Activities have an [eight-hour active lifetime](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), can be dismissed/disabled, and must not be covertly renewed. If no surface is available, AI continues with foreground/history fallback. End call-specific surfaces on call completion; an explicitly armed monitor can return to `monitoring` within its original lifetime.

If a separate **alerting** product mode is later approved, register `Activity<FocusTranscriptAttributes>.pushToStartTokenUpdates` scoped to owner/device/environment/attributes type. This is **not** the per-activity update token. After an alert-bearing start, discover the activity, observe `pushTokenUpdates`, and upload the resulting per-activity binding before promising updates. Missing handoff means history fallback. Never omit the required start alert or call arbitrary background `Activity.request` from the filtered hook.

Server contract (proposed endpoint names; APNs credentials stay server-side):

| Input / output | Required behavior |
| --- | --- |
| `PUT /screening/live-activities/{activityID}` | Authenticated owner, surface and optional current-session binding, token/version replacement, sandbox/production separation; repeated request is idempotent. |
| Captions producer | Reuse celld frame IDs; coalesce to the latest redacted excerpt and whole phase snapshot, not one push per token/word or a delta requiring earlier pushes. |
| ActivityKit APNs request | Per-activity token; `apns-push-type: liveactivity`, `apns-topic: <bundle-id>.push-type.liveactivity`; set `apns-priority: 5` explicitly for transcript updates. |
| Payload | `aps.timestamp` (increasing Unix seconds), `event: update`, complete `content-state`, `stale-date`; **no `alert` or sound**. Coalesce within a second rather than sending ambiguous equal timestamps. |
| Size | Reject an encoded APNs body over **4096 bytes**; separately keep attributes plus dynamic state within **4 KB**. Count UTF-8 JSON bytes and escaping, not characters; cap excerpt to 240 UTF-8 bytes initially and prune optional fields. |
| End / revocation | For a call-specific surface, send `event: end` with final state/dismissal date and retire registration. For an armed monitor, unbind the ended session and push a cleared `monitoring` snapshot; preserve its token for later calls within the original lifetime. Revoke registration only when the activity ends/is dismissed, on logout/consent removal or APNs invalid-token response. Reconcile delayed terminal updates on next foreground. |

Size limits are from [Live Activity data constraints](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) and [APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns), not the 5 KB VoIP-push limit.

**Proposed cadence:** priority-5 snapshots at most once per five seconds when visible text changes, phase/terminal changes at the next send opportunity, and a 30-second stale date. These are initial product budgets to measure, not Apple delivery guarantees. Priority 5 can be delayed, grouped or lost. Priority 10 uses a system-managed hourly budget and is not the default; no priority change or alert is allowed solely to defeat throttling. Enable `NSSupportsLiveActivities` and optionally `NSSupportsLiveActivitiesFrequentUpdates` in Info.plist, plus Push Notifications capability. There is no special frequent-updates entitlement. Observe `frequentPushesEnabled` / `frequentPushEnablementUpdates`, send changes to the server, and reduce cadence when disabled.

There is no reliable SDK “remaining ActivityKit budget” counter or per-render acknowledgment. APNs acceptance is not evidence that the screen updated. If throttled, disconnected or budget-limited, retain/coalesce the newest server snapshot, back off rather than loop retries, let the widget go stale, and resync from authoritative history on foreground. Serialize pushes per surface and keep its revision increasing across session bindings; an old call's delayed update must not overwrite a new call. Never keep background SSE/audio alive to maintain the surface. AI handling continues; UI freshness and call ownership are separate.

### React Native / Expo proposal

```typescript
type FocusSnapshot = {
  authorization: 'unsupported' | 'notDetermined' | 'restricted' | 'denied' | 'authorized';
  state: 'unknown' | 'notificationsSilenced' | 'notificationsNotSilenced';
  observedAt: string; // ISO 8601 at JS boundary
};
type ActivityCapability = {
  enabled: boolean; frequentPushesEnabled: boolean;
  pushToStartSupported: boolean; previewEnabled: boolean;
};
interface FocusCallingModule {
  getFocusStatus(): Promise<FocusSnapshot>;
  requestFocusStatusAuthorization(): Promise<FocusSnapshot>;
  getTranscriptActivityCapability(): Promise<ActivityCapability>;
  startTranscriptActivity(sessionID: string): Promise<{ activityID: string; surfaceID: string }>;
  armTranscriptMonitoring(): Promise<{ activityID: string; surfaceID: string }>;
  endTranscriptActivity(surfaceID: string): Promise<void>;
  takeOverScreenedCall(sessionID: string, requestID: string): Promise<{ conversationID: string }>;
  // removable subscriptions; snapshots are also available after JS reload
  addFocusStatusListener(cb: (value: FocusSnapshot) => void): { remove(): void };
  addIncomingPresentationListener(cb: (value: IncomingPresentationEvent) => void): { remove(): void };
}
type IncomingPresentationEvent =
  | { kind: 'reported'; invitationID: string; conversationID: string }
  | { kind: 'filtered'; invitationID: string; serverCallID: string;
      reason: 'focus' | 'blockList' | 'restrictedSharing' | 'protectedCall' | 'sensitiveParticipants';
      domain: string; code: number }
  | { kind: 'failed'; invitationID: string; domain: string; code: number };
```

JS events are observation/replay, never required for policy execution or token upload. Native authenticated registration is the primary token path; expose only registration status to JS. The Expo config plugin would add the usage description, optional widget/intent extension membership, App Group and plist flags/capabilities. Extension signing and previews need a native build; do not imply Expo Go can supply this. Keep policy persisted natively and versioned with the backend; the app's settings service owns changes.

## User take-over: outgoing LCK plus LiveKit join

Propose `@MainActor takeOverScreenedCall(sessionID:requestID:) async throws -> UUID`. A deep link with an opaque session ID opens the app; an optional `LiveActivityIntent` delegates to the same authenticated native route. Do not put access tokens in the URL. Require owner authentication/unlock and explicit user action before capture. This feature **does not answer a ringing incoming conversation or turn Focus off**.

1. Backend validates session/owner, atomically reserves a take-over request and returns a short-lived room join grant for the **existing LiveKit room/SIP call**. It rejects ended calls, wrong owners and competing devices; retries return the same operation.
2. Use the existing [`startConversation(to:video:metadata:)`](../../../Sources/VoIPSDK/ConversationClient.swift) path to create a **new outgoing** SDK conversation UUID, carrying only opaque `sessionID`/request identity in metadata. Its `StartConversationAction` reaches `ConversationHandler.start`; do not issue `JoinConversationAction` against the filtered UUID. The serverCallID remains the backend correlation key, not the new local UUID.
3. In the prepared, cancellation-aware start handler, connect the LiveKit media adapter to that room using the join grant. Respect the existing [LiveKit audio ownership contract](../../../Integrations/LiveKit/README.md): adapter preparation before engine demand, SDK audio-session queue off MainActor, actual capture only after genuine LCK audio activation. Never call `setActive` or invent a second provider.
4. Only after server-confirmed owner media readiness does the backend mute/remove the AI speaker and commit ownership. A fulfilled LCK action or resolved bridge promise alone is insufficient. The surface displays `takeoverPending` until confirmation. Update/end the activity after confirmed owner connection.
5. On timeout, cancellation, permission denial, LCK start failure or room-join failure, fail the local action and release the reservation; the AI continues unless the SIP caller already ended. Reconcile a late success/cancellation atomically server-side, preventing simultaneous human/AI speech or a dropped caller. Clean up local media and end its local conversation if abandoned.

All LCK ownership, action fulfillment and SDK conversation projection stays on MainActor except the existing narrow incoming-report transport. Outbox, captions processing, HTTP and blocking media operations run on dedicated workers/actors as appropriate. A synchronous native hook must not wait for main or JS. MainActor `async` code must not block it. Preserve action cancellation/deadlines and the existing process-singleton model in [`ConversationHandler`](../../../Sources/VoIPSDK/ConversationHandler.swift) and [`VoIPApplication`](../../../Sources/VoIPSDK/VoIPApplication.swift).

## Breakthrough contract and implementation gate

Expose no `forceRing`, `disableFocus` or API that **generates or retries** a call to manufacture a repeated-call breakthrough. A user-authorized host policy may classify separate, genuine incoming calls by exact caller and time window, then send a single VoIP push for an eligible later call when the user has allowed the app; see the [app-breakthrough RFC](app-breakthrough.md). That server decision does not claim iOS's repeat-call rule applies or bypass a Focus setting. Settings may explain user-managed Focus app/person/call allowances. Genuine communication notifications are an opt-in, independently tested path; an AI urgency label is not an entitlement. Any separately justified urgent alert must pass user authorization and the [README's interruption rules](README.md#interruption-levels-and-compliant-breakthrough). Silent transcript mode always omits alerts.

Before implementing: qualify native callback-once and backend deduplication under suspension/relaunch; permission/unknown status; foreground/intent/pre-armed starts and dismissal; any separately enabled alerting push-to-start then update-token handoff; Unicode payload bounds; stale/disabled surfaces; and owner take-over races on the device plan. These gates are proposed follow-up work, not tests run by this docs lane.
