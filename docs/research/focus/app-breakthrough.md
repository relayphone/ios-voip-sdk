# RFC: host-controlled breakthrough for Focus-aware calling

**Status: proposal, conditional on the [device follow-up](device-plan.md#contact-and-repeat-follow-up-after-146).** No SDK or Phone implementation is included. A single-sample [LCK device pass](results.md) on iPhone 13 / iOS 27 found app allowance presented call UI, while person-only allowance and a second call 69 seconds later were filtered with code 3. F14's person-aware Communication Notification did not change the LCK report; its own presentation was not independently established. CallKit, three-sample repeats and other handle formats remain unmeasured. Do not generalize that result to all providers or OS versions.

If those measurements persist, let the **host's server** select which genuine incoming calls receive a VoIP push. The user explicitly adds the app to each desired Focus's Allowed Apps list. For a user-enabled guarded policy, real calls from selected callers or repeat callers can ring; the server sends other calls directly to the AI or declines them according to the user's choice. A pre-existing silent transcript activity or the app's transcript/history can show the AI conversation.

**The central constraint:** `INFocusStatusCenter` does not expose a global Focus-on switch. Apple says an enabled Focus that allows this app makes the user appear **not focused to that app**. The authorized `false` value is therefore compatible with both “Focus off” and “Focus on, app allowed.” An `INShareFocusStatusIntent` cannot be assumed to resolve that ambiguity. The proposed allowlist and status mechanisms alone cannot implement “screen only while any Focus is on.” Use an explicit host-controlled guard mode, or qualify an opt-in Focus filter for each desired Focus; do not promise automatic global Focus detection. [Apple's Focus status sample](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates), [WWDC22 Focus filters](https://developer.apple.com/videos/play/wwdc2022/10121/).

## User setup

1. Explain the optional feature: “Choose callers who may ring while this app is allowed in a Focus. Other calls can be handled by your AI.” Let the user select the app's VIP/allowed callers, the repeat window and an AI/decline fallback. This is the **app's list**, not the system Focus People list.
2. Request ordinary notification permission before directing the user to the Focus Apps picker. The [device pass](results.md#ios-27-settings-facts-that-affect-the-product) found that picker listed only apps with notification permission. If denied or unavailable, explain that the app may not appear in the picker and offer the existing screening/history flow; do not block unrelated app use.
3. Guide the user to allow the app in **each Focus** where they want app-managed breakthrough. This is an explicit user choice in Settings, not a programmatic override. The app cannot assume it can read the system's People/App allowlists or verify that a particular Focus includes it. Let the user confirm setup; measure actual presentation separately. [Apple's Focus controls](https://support.apple.com/guide/iphone/allow-or-silence-notifications-for-a-focus-iph21d43af5b/27/ios/27).
4. Separately explain and request shared Focus-status access with `NSFocusStatusUsageDescription` and `INFocusStatusCenter.default.requestAuthorization(completionHandler:)`. This permission is optional. The iOS 27 probe saw raw `isFocused == false` while authorization was not determined and Focus was on: **check authorization before using the value**. Denied, restricted, undetermined, unavailable or nil means `unknown`, never `notFocused`. [Apple's usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfocusstatususagedescription), [authorization API](https://developer.apple.com/documentation/intents/infocusstatuscenter/requestauthorization(completionhandler:)).
5. Offer a clear guard-mode choice. The recommended dependable option is **always-on selective screening**, which also screens unlisted calls outside Focus. A more limited per-Focus mode can use a user-configured `SetFocusFilterIntent` for each desired Focus, subject to measured delivery/recovery behavior. Neither an absent filter nor shared status `false` proves that all Focus modes are off. Users should see the active policy and a way to change or disable it.

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

`notFocused` means the authorized API reports this app's notifications are not silenced; it **does not** certify global Focus is off. `focused` means the authorized app-relative status reports notifications silenced. `unknown` includes all missing/unauthorized/stale information. Expose source and age to the host; an async stream is a best-effort delivery of observations, not a guaranteed continuous background subscription. The server also tracks freshness independently; don't silently preserve an old `notFocused` indefinitely. [Apple's `INFocusStatusCenter`](https://developer.apple.com/documentation/intents/infocusstatuscenter).

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

Repeat breakthrough here classifies **independently arriving real calls** after the user allowed this app and configured a policy. It does not place an automatic callback, retry a filtered report, fabricate a second call, or promise iOS's Allow Repeated Calls applies to the app. The [SDK API rule](sdk-api.md#breakthrough-contract-and-implementation-gate) forbidding an automatic repeat-call API remains intact. A separate, user-initiated take-over starts an outgoing LCK conversation into the existing LiveKit room/SIP call, as described in [Phone integration](phone-app.md#take-over-integration-with-existing-owner-join).

## Passive transcript and privacy

AI-only calls need no incoming VoIP push or device media session. The server continues celld captions and updates an already eligible Live Activity using its per-activity token, with no update alert; the app can show the full transcript when opened. Push-to-start requires an alert, so if no activity was foreground/user-intent/pre-armed, use in-app/history fallback rather than promising a new silent surface. Respect consent, token rotation, delivery budgets, stale rendering and existing lock-screen preview settings in the [SDK proposal](sdk-api.md#silent-live-activity-building-block).

Suggested onboarding/privacy text, to be finalized by the host:

> If you allow this app in a Focus, it can ring for people you choose and for repeat calls within your chosen time window. Your other calls can be answered by your AI or declined. To apply this policy, the service stores the caller handles you select, recent call times, your policy and the app-relative Focus status you choose to share. A shared status may be unavailable or delayed. You can change the policy, turn sharing off and request deletion in settings. A transcript may be shown on your Lock Screen only if you enable previews.

Identify any third-party AI processor, its data sharing, retention and deletion path; explain those before enabling AI screening. Send only the caller identifiers and observations needed for the feature, protect them in transit and at rest, avoid raw handles/tokens in routine logs, and bound repeat-history retention to the configured window plus operationally justified reconciliation. This is an engineering proposal, not a claim of App Review approval. Apple's [App Review Guidelines 5.1.1–5.1.2](https://developer.apple.com/app-store/review/guidelines/#privacy) address purpose, consent, minimization, sharing and deletion.

## Qualification before promising the feature

| Measurement | Required evidence |
| --- | --- |
| System breakthrough | Three-sample CallKit/LCK person-only, Contacts Only, Everyone, Favorites, handle-format and repeat on/off rows in the [device plan](device-plan.md#contact-and-repeat-follow-up-after-146). Preserve the three-minute pair window and report independent outcomes. |
| Status truth table | Focus off/on × app allowed/excluded × authorized/denied/not determined/sharing off. Record both raw status and authorization; specifically confirm whether an allowed app sees `false` in Focus. Never claim `notFocused` means global Focus off. |
| Intent delivery | Toggle configured Focus with app foreground, suspended, OS-killed and separately user force-quit; online/offline and locked/unlocked. Record device transition, intent execution, outbox write and server acknowledgment with clocks/offsets, latency distribution, missing events and relaunch reconciliation. Apple gives no delivery SLA. |
| Guard signal | Test a user-configured Focus filter on enable/disable, switching between two configured Focuses, switching to an unconfigured Focus and removal; verify stale/unknown fallback without falsely claiming global off. Compare explicit always-on guard. |
| Stale, revoke and multi-device | Partition network, reorder/deduplicate events, revoke Focus sharing, deny notifications, sign out and restore another device. Confirm per-device sequence/account scope and that stale data cannot widen ringing to unlisted callers. |
| Identity and repeat | Same E.164 number in host/system contacts, national input normalized at trusted ingress, generic/unknown caller, duplicate `serverCallID`, two genuine calls inside/outside N, blocked/VIP precedence and spoofed/invalid cases. Only distinct real calls count. |
| Onboarding/privacy | Notification permission before Focus app picker, separate Focus-sharing permission, opt-in wording and actual revocation/deletion behavior. Verify previews default private and third-party AI disclosures match the deployed service. |
| Presentation | Pre-existing activity continuity and current token generation, silent updates/staleness, no activity available, AI ownership/take-over and history. Treat APNs acceptance as transport acknowledgment, not rendered content. |

An implementation should remain gated until the host chooses its guard-mode UX and the relevant measurements meet its freshness/latency requirements. The current [one-sample results](results.md) and this RFC do not qualify that behavior.
