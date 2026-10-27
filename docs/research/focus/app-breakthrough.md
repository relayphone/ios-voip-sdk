# RFC: host-controlled breakthrough for Focus-aware calling

**Proposal, subject to further [device measurements](device-plan.md#contact-and-repeat-follow-up-after-146).** The [iPhone 13 / iOS 27 results](results.md) show different behavior for the two providers. LCK filtered the person-only case and a second call 69 seconds later. CallKit F13 presented a call from a person allowed in Focus while the app was excluded: **one sample**, 1.2 seconds. Confirm it with three samples before promising this behavior. The app allowance presented call UI in all four measured LCK samples; repeat behavior, other handle formats and provider differences need further qualification.

The recommended integration has three parts:

1. Use a user-configured Focus filter to communicate the app-specific policy for each configured Focus. C06 confirmed that the probe read the configured policy with Focus on; delivery and recovery across transitions still need measurement. An absent or stale update is not proof that Focus is off.
2. Where system People allowances are desired, report the real caller through CallKit with the exact E.164 phone-number handle. F13 suggests iOS can apply the People allowance in that configuration, but the finding is provisional and has one sample.
3. Treat allowing the app in Focus as an overriding app-level allowance for the tested cases: it can present calls regardless of the caller's People allowance. Do not combine that setup with a promise that iOS will filter individual callers. System and user controls remain authoritative, and broader behavior needs measurement.

For host-managed screening, the user may explicitly allow the app and enable a separate server policy. The server selects which genuine calls receive a VoIP push, using the host's chosen callers and repeat window; other calls go to the AI or are declined according to the user's choice. A pre-existing silent transcript activity or the app's transcript/history can show the AI conversation.

**The central constraint:** `INFocusStatusCenter` does not expose a global Focus-on switch. Apple says an enabled Focus that allows this app makes the user appear **not focused to that app**. The authorized `false` value is therefore compatible with both “Focus off” and “Focus on, app allowed.” An `INShareFocusStatusIntent` cannot be assumed to resolve that ambiguity. The proposed allowlist and status mechanisms alone cannot implement “screen only while any Focus is on.” Use an explicit host-controlled guard mode, or qualify an opt-in Focus filter for each desired Focus; do not promise automatic global Focus detection. [Apple's Focus status sample](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates), [WWDC22 Focus filters](https://developer.apple.com/videos/play/wwdc2022/10121/).

## User setup

1. Explain the optional feature: “Choose callers who may ring while this app is allowed in a Focus. Other calls can be handled by your AI.” Let the user select the app's VIP/allowed callers, the repeat window and an AI/decline fallback. This is the **app's list**, not the system Focus People list.
2. Request ordinary notification permission before directing the user to the Focus Apps picker. The [device pass](results.md#ios-27-settings-facts-that-affect-the-product) found that picker listed only apps with notification permission. If denied or unavailable, explain that the app may not appear in the picker and offer the existing screening/history flow; do not block unrelated app use.
3. For app-managed breakthrough, guide the user to allow the app in **each Focus** where they want that policy. For system People matching, keep the app excluded and qualify CallKit behavior separately. This is an explicit user choice in Settings, not a programmatic override. The app cannot assume it can read the system's People/App allowlists or verify that a particular Focus includes it. Let the user confirm setup; measure actual presentation separately. [Apple's Focus controls](https://support.apple.com/guide/iphone/allow-or-silence-notifications-for-a-focus-iph21d43af5b/27/ios/27).
4. Separately explain and request shared Focus-status access with `NSFocusStatusUsageDescription` and `INFocusStatusCenter.default.requestAuthorization(completionHandler:)`. This permission is optional. The iOS 27 probe saw raw `isFocused == false` while authorization was not determined and Focus was on: **check authorization before using the value**. Denied, restricted, undetermined, unavailable or nil means `unknown`, never `notFocused`. Apple's sample also requires notification authorization and the Communication Notifications capability for current status; if a prerequisite is unmet, use `unknown`. [Apple's usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfocusstatususagedescription), [authorization API](https://developer.apple.com/documentation/intents/infocusstatuscenter/requestauthorization(completionhandler:)), [Focus-status sample](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates).
5. Offer a clear guard-mode choice. Use a user-configured `SetFocusFilterIntent` for the intended per-Focus policy, subject to measured delivery and recovery. An explicit **always-on selective screening** mode is a fallback when the user accepts screening unlisted calls outside Focus. Neither an absent filter nor an app-relative `false` observation proves that all Focus modes are off. Users should see the active policy and a way to change or disable it.

## Caller identity supplied by the host

These are illustrative Swift contracts, not existing SDK APIs:

```swift
public enum CallerHandleType: String, Codable, Sendable {
  case phoneNumber, email, generic
}
public struct Caller: Codable, Sendable, Equatable {
  public let handleType: CallerHandleType
  public let value: String            // E.164-normalized for phoneNumber
  public let displayName: String?
  public let hostContactID: String?   // opaque ID in the host's own contact store
}
```

The host supplies one validated caller for the actual invitation; the SDK propagates the **same type and value** to LCK `Handle` or CallKit `CXHandle`, and to an appropriately typed `INPersonHandle` when donating a genuine `INStartCallIntent`. Use the host's display name when provided. Keep `hostContactID` opaque and host-scoped: it is **not** automatically an iOS `CNContact` identifier. Supply an iOS contact identifier only when the host actually has the corresponding system identifier and permission. Distinct handles/types remain distinct; never guess identity from a display name, number suffix or an unrelated contact.

Normalize a phone number to an unambiguous E.164 value at the trusted ingress, using the host's country context when necessary. If normalization fails or the caller is withheld, keep it unknown and do not accidentally match a VIP or repeat key. Email/generic values use their own documented host normalization, not E.164. Treat caller ID as a routing signal rather than proof of caller identity: network-supplied numbers can be spoofed. The same stable handle is presented to system calling UI and, where configured, Recents; Apple does not promise a specific Recents grouping or that an `INPerson` donation changes it. [Apple's `CXHandle`](https://developer.apple.com/documentation/callkit/cxhandle), [communication-notification identities](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications), [LCK handles and Recents](https://developer.apple.com/videos/play/wwdc2026/226/).

## SDK Focus and policy sketch

```swift
public enum FocusStatus: String, Codable, Sendable {
  case unknown, focused, notFocused
}
public enum FocusAuthorization: String, Codable, Sendable {
  case unsupported, notDetermined, restricted, denied, authorized
}
public struct FocusObservation: Codable, Sendable {
  public let status: FocusStatus
  public let authorization: FocusAuthorization
  public let observedAt: Date
  public let source: Source
  public enum Source: String, Codable, Sendable { case foregroundSample, shareIntent }
}
public protocol FocusStatusProviding: Sendable {
  func current() async -> FocusObservation
  func updates() -> AsyncStream<FocusObservation>
}
public struct HostCallPolicy: Codable, Sendable {
  public let version: String
  public let allowedCallers: [Caller]
  public let repeatWindowSeconds: Int? // nil disables; default suggestion: 180
  public let unlisted: UnlistedRoute   // screenWithAI or decline
}
public enum UnlistedRoute: String, Codable, Sendable { case screenWithAI, decline }
public protocol FocusPolicyHooks: Sendable {
  func publishFocusObservation(_ observation: FocusObservation) async throws
  func publishPolicy(_ policy: HostCallPolicy) async throws
}
```

`notFocused` means the authorized app-relative Focus status reports not focused; it **does not** certify global Focus is off or that a notification will be delivered. `focused` means that status reports focused. Gate both foreground samples and intent observations on Focus authorization, notification authorization and the Communication Notifications capability; `unknown` includes unmet prerequisites and all missing/unauthorized/stale information. Expose source and age to the host; an async stream is a best-effort delivery of observations, not a guaranteed continuous background subscription. The server also tracks freshness independently; don't silently preserve an old `notFocused` indefinitely. [Apple's `INFocusStatusCenter`](https://developer.apple.com/documentation/intents/infocusstatuscenter).

Use a SiriKit Intents app extension that lists `INShareFocusStatusIntent` in Supported Intents and routes `INExtension.handler(for:)` to an `INShareFocusStatusIntentHandling` handler. Read `intent.focusStatus?.isFocused`, gated by the containing app's authorization and notification prerequisites. Apple's sample specifies Focus and UserNotifications authorization and the Communication Notifications capability for this path; Apple's extension setup also specifies Siri capability for an iOS app with an Intents extension. Record a short versioned observation to an App Group/outbox, then arrange an authenticated background transfer; a successful intent response means the device accepted the update, **not** that the server received it. Do not block the handler on a live network request. [Apple's sample](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates), [Intents extension setup](https://developer.apple.com/documentation/sirikit/creating-an-intents-app-extension), [extension background-transfer guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html).

On app activation and permission changes, resample and reconcile the outbox. Use per-installation sequence numbers and authenticated device/account binding; the server accepts only newer observations for that installation and records its own receipt time. A background intent is an opportunity to update the server, not a promise that every transition, force-quit, offline period or retry arrives on time. Never infer a global Focus state from the absence of an event. Explicitly expire stale observations; a revoked permission or signed-out device becomes `unknown`. Multi-device conflicts require an explicit host policy for which device governs a given destination, rather than last-write-wins across unrelated devices.

`SetFocusFilterIntent` can send a separately versioned, app-specific guard-policy selection when the user configured that Focus. It does not enumerate Focus modes or turn them off; its transition/force-quit delivery and reset behavior must be tested. A missing or stale filter update falls back to the user's chosen guarded behavior, not an assumption that Focus is off. [Apple's Focus filter sample](https://developer.apple.com/documentation/appintents/defining-your-app-s-focus-filter).

## Server routing before PushKit

The backend already owns the incoming LiveKit SIP call and the existing AI/captions path. The host registers an authenticated, versioned policy and explicitly enables its guard. Before sending any VoIP push:

1. Resolve the real, distinct incoming `serverCallID` to the destination account and validate the caller identity. Apply the host's block/deny rules first. A blocked caller never enters a VIP or repeat breakthrough path.
2. Under the enabled guard, match the caller against the host's allowed/VIP set by **exact `(handleType, normalized value)`**. A trusted host contact ID is a useful local reference, not a substitute for validating the incoming handle.
3. If not VIP, check whether a **previous distinct real incoming call** from the exact same normalized handle arrived within the user's configured N seconds. The first call may have been screened or declined. Use server receipt time, atomically deduplicate redelivery by `serverCallID`, and scope history by destination account/line. Withheld/invalid callers cannot become repeat callers. Record both caller-controlled attempts, not generated retries.
4. For a VIP or qualifying repeat, send **one** genuine VoIP push carrying the exact caller. The app immediately reports it through its chosen system provider. User/app allowance and iOS remain authoritative; a push does not guarantee a ring. For other callers, answer using the existing AI or decline on the backend **without a VoIP push**. Apply rate limits and one terminal disposition per call so duplicate events and simultaneous calls cannot cause competing AI/ringing ownership.
5. If the explicit guard is inactive because the user disabled it, normal host calling behavior applies. If guard state, server policy or a required observation is unknown/stale, do **not** broaden to “ring everybody.” Apply the last user-selected guarded policy (VIP/repeats only), or an explicitly chosen all-screen/decline fallback; when no policy is available, default to all-screen/decline. Label the status as uncertain and reconcile later. User settings decide whether an individually allowed caller is eligible during this fallback.

The policy runs **before** sending PushKit. Once an actual VoIP push is delivered, the probe/SDK must honor the system's reporting obligation; a local policy hook must not suppress the required report while waiting for JS or a server decision. This is not a request to send a silent VoIP push for an AI-only call. [Apple's PushKit guidance](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit).

When a fresh, authorized app-relative observation is `focused`, prefer selecting the user-authorized AI-screening route **before** sending a ring push; no push is needed for an AI-only call. Apply the user's configured caller policy and explicit opt-in: monitoring alone does not consent to AI-only routing. A stale or unknown observation is not proof of Focus off; apply the configured guarded fallback above. An authorized `notFocused` is not proof that global Focus is off, especially when the app is allowed.

Repeat breakthrough here classifies **independently arriving real calls** after the user allowed this app and configured a policy. It does not place an automatic callback, retry a filtered report, fabricate a second call, or promise iOS's Allow Repeated Calls applies to the app. The [SDK API rule](sdk-api.md#breakthrough-contract-and-implementation-gate) forbidding an automatic repeat-call API remains intact. A separate, user-initiated take-over starts an outgoing LCK conversation into the existing LiveKit room/SIP call, as described in [Phone integration](phone-app.md#take-over-integration-with-existing-owner-join).

## Answered elsewhere and dismissing a ringing call

The [Phone incident](https://github.com/ziahamza/phone-app/issues/885#issuecomment-6429483597) reports a full-screen CallKit UI remaining for roughly 20–40 seconds after the assistant answered during built-in Do Not Disturb. The operator reports three later runs without that presentation: one of four showed it. The exact allowance state and cause are not established; the [CK-DND rows](device-plan.md#built-in-do-not-disturb-and-answered-elsewhere-follow-up) must test this inconsistency. The ringer was silent, so this is a UI observation, not evidence of audible ringing.

When the server commits an answer by the assistant or another device, it immediately signals each still-ringing device over its authenticated existing call connection, binding the terminal event to the account, `serverCallID`, invitation generation and local system UUID. A running SDK consumes it without waiting for JavaScript, media teardown or the caller to hang up, then reports the matching local system call ended. CallKit uses `CXProvider.reportCall(with:endedAt:reason:)` with `CXCallEndedReason.answeredElsewhere` (iOS 10+). LCK uses `ConversationManager.reportConversationEvent(.conversationEnded(date, .joinedElsewhere), for: conversation)` with `Conversation.EndedReason.joinedElsewhere` (iOS 17.4+). Apple describes these reasons in terms of another device answering/joining; treating a server assistant as the other endpoint is a product interpretation to qualify on device, not an Apple promise. A caller hangup uses `.remoteEnded`, not an invented answer. Ending this **local** system call must not end the assistant's LiveKit SIP call. [CallKit end report](https://developer.apple.com/documentation/callkit/cxprovider/reportcall%28with%3Aendedat%3Areason%3A%29), [CallKit reason](https://developer.apple.com/documentation/callkit/cxcallendedreason/answeredelsewhere), [LCK reason](https://developer.apple.com/documentation/livecommunicationkit/conversation/endedreason/joinedelsewhere).

Use a single serialized, idempotent state transition per invitation: terminal state wins over late local answer/join; duplicate or stale events cannot end a newer invitation. If an end event races the required incoming report, retain it and report the end immediately after successful report completion; if reporting fails, do not invent an active system call. Reject a late owner join server-side when another endpoint already owns the call, while preserving a deliberate, separately authorized take-over flow. Reconcile terminal state on reconnect/relaunch, and record an acknowledgment only after the device invokes the end report; it is not proof that UI disappeared.

**Proposed budget, not an Apple guarantee:** target end-to-visible-dismissal within **2 seconds at p95** from server answer commit, including signal delivery; separately target device receipt to end-report invocation within **100 ms at p95**. Measure actual UI disappearance, clock offset/uncertainty, and missing or censored observations; three samples are discovery, not a defensible p95. Alert on misses and qualify the thresholds with a larger device run. When the event is late or unavailable, the server keeps the assistant as owner and rejects stale joins; on reconnect the SDK applies any pending terminal state. For a user-authorized screened call, an independently configured local ring deadline can end a **still-ringing** local invitation with `.unanswered` if no verified answer signal has arrived, then reconcile; cancel it when the local answer wins. A provisional **10-second maximum from report** is a product option requiring consent and measurement, not a claim that the assistant answered. Do not relabel an already-ended call or resurrect it when a delayed event arrives. If the app is suspended, killed or offline, neither the connection nor watchdog is guaranteed to run, so neither this deadline nor a dismissal SLA can be promised.

Apple directs apps to send subsequent end updates over the established network connection, rather than additional push notifications to cancel a call. Do not send a cancellation-only VoIP push or assume a background push is timely. If no execution opportunity is available, record the unresolved UI risk and reconcile when execution resumes. [Apple's PushKit guidance](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit), [background push limits](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).

## Passive transcript and privacy

AI-only calls need no incoming VoIP push or device media session. The server continues celld captions and updates an already eligible Live Activity using its per-activity token, with no update alert; the app can show the full transcript when opened. Push-to-start requires an alert, so if no activity was foreground/user-intent/pre-armed, use in-app/history fallback rather than promising a new silent surface. Respect consent, token rotation, delivery budgets, stale rendering and existing lock-screen preview settings in the [SDK proposal](sdk-api.md#silent-live-activity-building-block).

Suggested onboarding/privacy text, to be finalized by the host:

> If you allow this app in a Focus, it can ring for people you choose and for repeat calls within your chosen time window. Your other calls can be answered by your AI or declined. To apply this policy, the service stores the caller handles you select, recent call times, your policy and the app-relative Focus status you choose to share. A shared status may be unavailable or delayed. You can change the policy, turn sharing off and request deletion in settings. A transcript may be shown on your Lock Screen only if you enable previews.

Identify any third-party AI processor, its data sharing, retention and deletion path; explain those before enabling AI screening. Send only the caller identifiers and observations needed for the feature, protect them in transit and at rest, avoid raw handles/tokens in routine logs, and bound repeat-history retention to the configured window plus operationally justified reconciliation. This is an engineering proposal, not a claim of App Review approval. Apple's [App Review Guidelines 5.1.1–5.1.2](https://developer.apple.com/app-store/review/guidelines/#privacy) address purpose, consent, minimization, sharing and deletion.

## Qualification before promising the feature

| Measurement | Required evidence |
| --- | --- |
| System breakthrough | Three-sample CallKit/LCK person-only, Contacts Only, Everyone, Favorites, handle-format and repeat on/off rows in the [device plan](device-plan.md#contact-and-repeat-follow-up-after-146). Preserve the three-minute pair window and report independent outcomes. |
| Built-in DND and end | Run the three-sample [CK-DND rows](device-plan.md#built-in-do-not-disturb-and-answered-elsewhere-follow-up); distinguish initial/AI-requested invitations, visible UI, server commit, signal delivery, native end-report and UI disappearance. Test filtered, late/lost, duplicate and report-race cases without claiming a delivery SLA. |
| Status truth table | Focus off/on × app allowed/excluded × authorized/denied/not determined/sharing off. Record both raw status and authorization; specifically confirm whether an allowed app sees `false` in Focus. Never claim `notFocused` means global Focus off. |
| Intent delivery | Toggle configured Focus with app foreground, suspended, OS-killed and separately user force-quit; online/offline and locked/unlocked. Record device transition, intent execution, outbox write and server acknowledgment with clocks/offsets, latency distribution, missing events and relaunch reconciliation. Apple gives no delivery SLA. |
| Guard signal | Test a user-configured Focus filter on enable/disable, switching between two configured Focuses, switching to an unconfigured Focus and removal; verify stale/unknown fallback without falsely claiming global off. Compare explicit always-on guard. |
| Stale, revoke and multi-device | Partition network, reorder/deduplicate events, revoke Focus sharing, deny notifications, sign out and restore another device. Confirm per-device sequence/account scope and that stale data cannot widen ringing to unlisted callers. |
| Identity and repeat | Same E.164 number in host/system contacts, national input normalized at trusted ingress, generic/unknown caller, duplicate `serverCallID`, two genuine calls inside/outside N, blocked/VIP precedence and spoofed/invalid cases. Only distinct real calls count. |
| Onboarding/privacy | Notification permission before Focus app picker, separate Focus-sharing permission, opt-in wording and actual revocation/deletion behavior. Verify previews default private and third-party AI disclosures match the deployed service. |
| Presentation | Pre-existing activity continuity and current token generation, silent updates/staleness, no activity available, AI ownership/take-over and history. Treat APNs acceptance as transport acknowledgment, not rendered content. |

An implementation should remain gated until the host chooses its guard-mode UX and the relevant measurements meet its freshness/latency requirements. The current [one-sample results](results.md) and this RFC do not qualify that behavior.
