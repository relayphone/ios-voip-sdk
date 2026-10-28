# Focus-aware calling: platform findings

Research for [#124](https://github.com/ziahamza/ios-voip-sdk/issues/124), checked 26 October 2026. This is a design input, not an implemented SDK feature; device measurements are in [results](results.md). Companion deliverables: [proposed SDK API](sdk-api.md), [device measurement plan](device-plan.md), [Phone app integration contract](phone-app.md), the first [device results](results.md), and the conditional [host-controlled breakthrough RFC](app-breakthrough.md).

**Recommendation:** report legitimate incoming VoIP calls immediately, accept the system's filtering decision, and let the backend decline or screen a filtered call. Offer an opt-in, silent transcript Live Activity and a user-initiated join into the existing AI call. No public API found here turns Focus off or guarantees that a call, notification or Live Activity will break through.

## Evidence and confidence

| Evidence | Verified result | Boundary |
| --- | --- | --- |
| [Push probe](../callkit-simulator-probe/livecommunicationkit/push/README.md#results), iPhone 13 / iOS 27.0 | LCK incoming report failed after about 2.07 s, `com.apple.CallKit.error.incomingcall`, code 3; process survived, then suspended. Same number 69 s later was also filtered. | One configuration; repeated-calls setting and all app/person combinations were not isolated. Survival does not guarantee background network time. |
| [Multi-call probe](../callkit-simulator-probe/livecommunicationkit/multicall/README.md#results), iOS 27.0 build 24A5355q | A blocked number still produced an incoming banner; reports succeeded in 50–57 ms and on a repeat 66 s later. | Do not rely on the iOS block list to filter LCK calls. App/backend blocking needs its own policy. |
| Apple documentation / WWDC transcripts below | API contracts and user controls. | A documented notification rule is not a measurement of LCK ringing behavior. |
| Local Xcode 27.1, build 27A9275 | Declarations and iOS availability below. | Compile-time availability does not promise device support, entitlement approval or delivery. |

## How Focus decides

[Apple's iPhone guide](https://support.apple.com/guide/iphone/allow-or-silence-notifications-for-a-focus-iph21d43af5b/27/ios/27) describes separate People and Apps controls, Allow Calls From groups, calls from silenced people, and Allow Repeated Calls (at least two calls from the same person within three minutes). Record whether a list means **Allow** or **Silence**; exclusion has opposite meanings in those modes. Emergency Bypass is another user-controlled exception. These settings are not an SDK allowlist that an app can write.

For CallKit, report failure means the system disallowed the incoming call: the provider must not proceed with that device call. See [`CXProvider.reportNewIncomingCall(with:update:completion:)`](https://developer.apple.com/documentation/callkit/cxprovider/reportnewincomingcall(with:update:completion:)) and local `CXProvider.h:86–96`. LCK is integrated with system calling UI ([WWDC26, Create live communication experiences](https://developer.apple.com/videos/play/wwdc2026/226/)); the linked device probe confirms a Focus rejection reaches it through the CallKit error domain. Neither this session nor the inspected LCK interface specifies a complete truth table for Apps versus People versus Allow Calls From. Measure each separately for both providers before promising parity.

Intelligent Breakthrough & Silencing lets Apple Intelligence judge notification importance; it does not provide an app-controlled urgent-call override. It requires [supported Apple Intelligence hardware](https://support.apple.com/en-gb/105112); the iPhone 13 cannot measure it. A supported second device, language/region and enabled setting are required for that follow-up. No guarantee was found that AI urgency classification promotes an LCK incoming call.

**Still to measure:** app-only and person-only allowances; contacts resolved from phone/email versus generic handles; repeated calls with the switch explicitly on/off; silenced-list semantics; CallKit/LCK differences. The observed 69-second retry is a negative result, not evidence that retries bypass Focus. Never generate repeated calls to manufacture breakthrough.

## Communication Notifications

[WWDC21, Send communication and Time Sensitive notifications](https://developer.apple.com/videos/play/wwdc2021/10091/) says communication importance is determined by user decisions. The notification should identify the real caller with `INPerson` and a matching `INPersonHandle`; include a genuine contact identifier when known. Construct `INStartCallIntent` for a call-related notification, donate `INInteraction` with `.incoming`, and use `try content.updating(from: intent)` inside a notification service extension (or the app for a local notification). Enable the Communication Notifications capability and declare supported intents. Outgoing interactions help Siri suggest people; incoming spam must not be donated as outgoing activity.

This supplies person-aware notification treatment under Focus, not permission to ring a separate VoIP call. [`UNNotificationContent.updating(from:)`](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/updating(from:)) returns updated notification content; it does not report an LCK conversation. Use a service extension for ordinary remote notifications with mutable content, not as a substitute for mandatory PushKit reporting. An ordinary communication alert may itself interrupt an allowed person; it is therefore disabled in the proposed silent screening mode. **Measure** notification delivery and call-report result separately, including with the notification absent.

## Interruption levels and compliant breakthrough

The [`UNNotificationInterruptionLevel`](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel) cases are `.passive`, `.active`, `.timeSensitive`, `.critical` (iOS 15). Passive delivery does not alert; active delivery respects Focus. Time Sensitive may pass Focus when the user permits it, and can be disabled. Critical can bypass Focus and the silent switch, but needs Apple's approved critical-alert entitlement and user authorization; see [critical alert authorization](https://developer.apple.com/documentation/usernotifications/unauthorizationoptions/criticalalert). Time Sensitive also requires its capability.

[App Review Guideline 2.5.9](https://developer.apple.com/app-store/review/guidelines/#software-requirements) forbids altering standard switches or native behaviors; its examples include “Volume Up/Down and Ring/Silent switches”. **Product rule:** never use Time Sensitive, Critical, notification sounds, background audio or an alerting Live Activity as a replacement ringer after a filtered call. Legitimate options are the user's Focus allowances, an accurately classified communication notification, a separately justified and authorized urgent notification, or the user opening the app/tapping take-over. None changes Focus programmatically. The default screening surface must remain silent even when an urgency model labels a call important.

## Focus awareness and Focus filters

[`INFocusStatusCenter`](https://developer.apple.com/documentation/intents/infocusstatuscenter) exposes `.default`, `authorizationStatus`, `focusStatus`, and `requestAuthorization(completionHandler:)`. Include [`NSFocusStatusUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfocusstatususagedescription) before access. Shared `INFocusStatus.isFocused` is optional: preserve **unknown** for unavailable/unshared status. It reveals neither a Focus name nor the rules for this caller, and must not gate whether a required VoIP report happens.

For observation, refresh when the app becomes active and after authorization. [`INShareFocusStatusIntentHandling.handle(intent:completion:)`](https://developer.apple.com/documentation/intents/insharefocusstatusintenthandling) is the public intent-delivery hook; a compatible intents extension can forward status through shared storage. The inspected center header contains no delegate or public change-notification API; do not invent `focusStatusDidChange` or promise continuous background observation. **Measure** intent delivery and permission/sharing revocation.

[`SetFocusFilterIntent`](https://developer.apple.com/documentation/appintents/setfocusfilterintent) (iOS 16) configures app-specific behavior when a user-selected Focus filter runs. [WWDC22, Meet Focus filters](https://developer.apple.com/videos/play/wwdc2022/10121/) and [Apple's sample](https://developer.apple.com/documentation/appintents/defining-your-app-s-focus-filter) show extension-based handling and notification filtering. A Phone filter could select “AI screens my calls” and persist that app policy. It cannot enumerate arbitrary Focus configurations, grant a caller breakthrough, or switch Focus off. Shared Focus status and a configured app filter are independent signals.

## Silent transcript Live Activity

[`ActivityKit`](https://developer.apple.com/documentation/activitykit) supplies the state transport; a WidgetKit/SwiftUI extension renders Lock Screen and supported Dynamic Island presentations. The [Live Activity guide](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) says its sandbox cannot access the network and static plus dynamic data must fit within 4 KB. A transcript excerpt belongs here; the full transcript belongs in the app. iPhone 13 has no Dynamic Island: test Lock Screen there and Island elsewhere. Visibility also depends on authorization, lock/privacy settings and system presentation; **Focus-on visibility is a measurement, not a guarantee**.

For a silent **update**, omit `alertConfiguration` locally and `aps.alert` in an ActivityKit update push. Do not attach sound or wake-screen expectations. Alerting updates are a separate, interruptive path; a high APNs transport priority does not by itself authorize an alert. See [`Activity.update(_:alertConfiguration:)`](https://developer.apple.com/documentation/activitykit/activity/update(_:alertconfiguration:)).

The [ActivityKit push guide](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications) specifies per-activity tokens (`pushTokenUpdates`), token rotation, and push-to-start on iOS 17.2+. **Push-to-start requires an `alert` payload**, so it cannot guarantee a silent automatic start after filtering. Foreground creation or a user-invoked `LiveActivityIntent` can establish a surface for later silent updates; a filtered PushKit callback alone cannot authorize background `Activity.request`. A previously user-armed monitoring activity is another design candidate to measure, subject to lifetime limits. No eligible activity means in-app/history fallback, not a forced start.

Updates use `apns-push-type: liveactivity`, topic `<bundle-id>.push-type.liveactivity`, ordered timestamps and whole-state snapshots. Priority 10 consumes an hourly budget; priority 5 avoids that budget but may be delayed. There is no published universal update rate. Excess high-priority updates may be throttled.

**Correction on the “frequent-updates entitlement”:** [`NSSupportsLiveActivitiesFrequentUpdates`](https://developer.apple.com/documentation/bundleresources/information-property-list/nssupportsliveactivitiesfrequentupdates) is an **Info.plist Boolean**, not a special entitlement. Users can disable frequent updates; read `ActivityAuthorizationInfo.frequentPushesEnabled` and its update stream. This does not grant unlimited delivery. Send compact, coalesced snapshots, use `stale-date`, and show “Updates delayed” after expiry. Never escalate priority or add alerts merely to evade throttling. The backend continues screening if presentation stops. **Measure** start eligibility, token handoff, cadence, stale rendering, and off/locked/Focus visibility.

## iOS 26–27: screening versus translation

Apple's [iOS 26 announcement](https://www.apple.com/newsroom/2025/06/apple-elevates-the-iphone-experience-with-ios-26/) describes Phone Call Screening and Live Translation. This is not a contract exposing Apple's screening agent or transcript to third-party VoIP apps. The [LCK updates page](https://developer.apple.com/documentation/updates/livecommunicationkit) and local 27.1 interface expose iOS 26 `SetTranslatingAction`, `fulfill(using:)` and `ConversationManager.Configuration.supportsAudioTranslation`, plus default-dialer/history APIs. CallKit's iOS 26 peer [`CXSetTranslatingCallAction`](https://developer.apple.com/documentation/callkit/cxsettranslatingcallaction) provides system translated captions/transcript when the caller selects translation; its documentation does not expose a raw transcript export API. Local `CXSetTranslatingCallAction.h:19–22` limits it to a connected call and requires Apple's VoiceProcessor for system translation call I/O. Translation is distinct from backend AI answering.

For app-supplied audio, [Speech updates](https://developer.apple.com/documentation/updates/speech) and local interfaces add `SpeechAnalyzer`, `SpeechTranscriber` and `DictationTranscriber` in iOS 26, then `AnalyzerInputConverter`, `AssetInputSequenceProvider` and `CaptureInputSequenceProvider` in iOS 27. [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) requires device/model support checks (`isAvailable` / supported locales and installed assets); `DictationTranscriber` is an alternative on unsupported devices. These APIs analyze audio the app can legitimately supply; they grant neither access to Apple's Phone call audio/transcript nor background execution. They are possible future in-app transcription tools, not a way to transcribe a server AI call while the client is suspended. Phone's existing server captions remain the proposed source. Device/language/assets and audio integration would need qualification before adoption.

**Bounded negative finding:** the inspected LCK interface has no public symbol containing `screening` or `transcript`, and no iOS 27-specific declaration. WWDC26's LCK session covers incoming/outgoing/group conversations, not an AI screening/transcript API. This does not prove absence from every Apple framework. Our proposal therefore uses Phone's server captions and AI, with no dependency on Apple's Phone transcript. Translation availability and system screening interaction still require separate device checks if the product adopts them.

## Exact local SDK declarations and iOS availability

Root inspected: `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/`. Paths below are relative to that root; line locations refer to this installed SDK, not a redistributable copy. Swift interfaces are `Modules/<Framework>.swiftmodule/arm64e-apple-ios.swiftinterface` (Swift 6.4). Header-only APIs were checked in `Headers/`. Availability below is **iOS** only, not every platform listed by Apple.

| Framework / exact public API | iOS availability in this SDK | Local declaration |
| --- | --- | --- |
| Intents: `INPerson`; initializer with `suggestionType:` | Type 10.0; suggestion initializer 15.0 | `Intents.framework/Headers/INPerson.h:23–68` |
| Intents: `INStartCallIntent`; `init(callRecordFilter:callRecordToCallBack:audioRoute:destinationType:contacts:callCapability:)` | Type 13.0; designated initializer 14.0 | `Intents.framework/Headers/INStartCallIntent.h:28–37` |
| Intents: `INFocusStatusCenter`, `INFocusStatusAuthorizationStatus`, `INFocusStatus` | 15.0 | `Intents.framework/Headers/INFocusStatusCenter.h:13–28`, `INFocusStatus.h:12–20` |
| Intents: `INShareFocusStatusIntent`, `INShareFocusStatusIntentHandling.handle(intent:completion:)` | 15.0 | `Intents.framework/Headers/INShareFocusStatusIntent.h:15–49` |
| UserNotifications: `UNNotificationContent.updating(from:)`, `UNNotificationContentProviding`, `UNNotificationInterruptionLevel` | 15.0 | `UserNotifications.framework/Headers/UNNotificationContent.h:16–33,93` |
| ActivityKit: `Activity<Attributes>`, `pushTokenUpdates`, `ActivityAuthorizationInfo.areActivitiesEnabled` | 16.1 | `ActivityKit.framework/Modules/ActivityKit.swiftmodule/arm64e-apple-ios.swiftinterface:36–41,124–126,461–466,542–545` |
| ActivityKit: `ActivityContent<State>`, `request(attributes:content:pushType:)`, `update(_:alertConfiguration:)`, `end(_:dismissalPolicy:)` | 16.2 | Same interface: `49–54,162–167,180–185,403–412` |
| ActivityKit: `frequentPushesEnabled`, `frequentPushEnablementUpdates` | 16.2 | Same interface: `534–551` |
| ActivityKit: `Activity.pushToStartTokenUpdates` | 17.2 | Same interface: `127–133` |
| LiveCommunicationKit: `ConversationManager.reportNewIncomingConversation(uuid:update:)`, `perform(_:)`, `StartConversationAction`, `JoinConversationAction` | 17.4 | `LiveCommunicationKit.framework/Modules/LiveCommunicationKit.swiftmodule/arm64e-apple-ios.swiftinterface:236–268,297–302` |
| LiveCommunicationKit: `SetTranslatingAction`, `fulfill(using:)`, `ConversationManager.Configuration.supportsAudioTranslation` | 26.0 | Same interface: `36–37,279–294` |
| CallKit: `CXProvider.reportNewIncomingCall(with:update:completion:)`, `CXErrorDomainIncomingCall`, `CXErrorCodeIncomingCallError` | Provider / error enum 10.0; individual newer enum cases have no separate annotation here | `CallKit.framework/Headers/CXProvider.h:21,86–96`, `CXError.h:13,25–34` |
| CallKit: `CXSetTranslatingCallAction`, `CXProviderConfiguration.supportsAudioTranslation` | 26.0 | `CallKit.framework/Headers/CXSetTranslatingCallAction.h:19–26`, `CXProviderConfiguration.h:31` |
| AppIntents: `SetFocusFilterIntent`, `invalidateFocusFilterAppContext()` | 16.0 | `AppIntents.framework/Modules/AppIntents.swiftmodule/arm64e-apple-ios.swiftinterface:10899–10910` |
| AppIntents: `LiveActivityIntent` | 17.0 | Same interface: `253–257` |
| Speech (additional transcript survey): `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber` | `@available(anyAppleOS 26, *)` (includes iOS 26) | `Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface:67–70,226–239,344–354` |
| Speech: `AnalyzerInputConverter`, `AssetInputSequenceProvider`, `CaptureInputSequenceProvider` | `@available(anyAppleOS 27, *)` (includes iOS 27) | Same interface: `516–521,670–675,717–724` |

### Incoming-call error codes 3–7

Read the **domain and code together**, including a bounded underlying-error chain. These exact names come from local `CallKit.framework/Headers/CXError.h:25–34`; the domain is `com.apple.CallKit.error.incomingcall`. Apple also documents [`CXErrorCodeIncomingCallError`](https://developer.apple.com/documentation/callkit/cxerrorcodeincomingcallerror). The enum is marked iOS 10.0, but this header does not establish the introduction version of each later case.

| Code | Exact Objective-C constant | Meaning / evidence |
| --- | --- | --- |
| 3 | `CXErrorCodeIncomingCallErrorFilteredByDoNotDisturb` | Filtered by DND/Focus; measured through LCK above. It does not disclose the exact Focus rule. |
| 4 | `CXErrorCodeIncomingCallErrorFilteredByBlockList` | Filtered by block list; named in SDK, **not produced** in the LCK block-list probe. |
| 5 | `CXErrorCodeIncomingCallErrorFilteredDuringRestrictedSharingMode` | Filtered during restricted sharing; exact triggering conditions and LCK propagation unmeasured. |
| 6 | `CXErrorCodeIncomingCallErrorCallIsProtected` | Call is protected; do not reinterpret as Focus or as permission to screen. Device trigger unmeasured. |
| 7 | `CXErrorCodeIncomingCallErrorFilteredBySensitiveParticipants` | Filtered by sensitive participants; exact policy and LCK propagation unmeasured. |

Unknown domain/code pairs remain failures. Do not apply code 7 from `com.apple.CallKit.error.requesttransaction` here: that is a separate transaction/capacity error. Only code 3 is the proposed default AI-screening trigger; block/security-related failures need distinct conservative policy.
