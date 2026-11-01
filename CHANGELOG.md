# Changelog

Each release's changes are recorded below, newest first, with unreleased changes at the top.
Public API changes include migration guidance.

## Unreleased

## 0.2.0 (2026-11-01)

### Added

- The `VoIPCore` library holds the values of the new call core: `Call`,
  `CallID`, `Handle` (phone numbers must be E.164), `Party`, `CallStatus` with
  `PreviewReason` and `EndReason`, `Action`, `ServerEvent`, `PresentationPolicy`,
  `CallEvent` and `VoIPConfiguration` with `Deadlines`. It has no system framework dependencies.

- `VoIPClient` runs the call core on the `VoIPActor` global actor. Start it once with
  `start(framework:media:push:audio:observers:configuration:clock:)`, observe `calls` and
  `isAudioActive`, subscribe with `events()`, and drive calls with `request(_:)`,
  `confirmPlaced(_:)`, `report(_:)`, `join(_:)` and `receive(_:for:eventID:)`. It reports a VoIP push's call
  before the push callback returns, recognises repeated pushes and server events by event ID and
  call ID, and remembers ended calls and early server events for `VoIPConfiguration.retention`.
  When a push that brings no new call to present, such as a repeated push or a server event,
  must be reported, the SDK reports a throwaway call under a new UUID and ends it at once, even
  when the push concerns a call in progress: the system doesn't count a second report of a call it
  already presents, and terminates the app, as it did after a server event push for a joined call
  in the background. Servers should send VoIP pushes about a call only while it may ring on a
  device, and tell a device about a call it answered or joined, or didn't present because Do Not
  Disturb or a Focus filtered it or it shows as a call preview, over the app's own connection or
  with a regular push. On an iPhone 13 with iOS 27.1 and a Focus on, the system said that
  `callEnded` VoIP pushes for filtered calls needn't be reported while the app was in the
  background, so the SDK reported nothing for them, and the system terminated the app for not
  reporting a call about 8 seconds after such a push, 6 times in four runs. After three
  terminations in 21 minutes, it stopped delivering VoIP pushes to the app, even once the user
  opened it, until the app was reinstalled. The SDK now reports every push that arrives while the
  app isn't active.
- The seams for calling-framework adapters and the app's media: `CallingFramework` with
  `FrameworkEvent`, `CallMedia`, `PushSource` with `VoIPPush` and `PushCompletion`, `ActionID`
  and `deviceUUID(for:)`. `VoIPConfiguration` adds `maximumCalls`, `supportedHandleTypes`,
  `includesCallsInRecents`, `ringtoneSound`, `iconTemplateImageData` and `retention`, and
  `ActionError` adds `unknownCall` and `refused(_:)`. A refusal carries the calling framework's
  error as a `FrameworkError`, with its domain, its code and the errors it wraps, such as the
  call service's `com.apple.CallKit.error.requesttransaction` code, so that the app can tell why
  the system refused; before, the SDK dropped it. Write `ActionError.refused(nil)` for a refusal
  without an error, and match either with `case .refused:`.
- `VoIPTesting` adds `FakeCallingFramework`, `FakeMedia` and `FakePushSource`, which run the
  client on the macOS host with `TestClock`.
- The `VoIPLiveCommunicationKit` library's `LiveCommunicationKitAdapter` presents calls with
  LiveCommunicationKit. It reports every handle of every party, maps the SDK's actions and end
  reasons to LiveCommunicationKit's, passes audio activation, action timeouts and resets to the
  SDK, and starts a VoIP push's report before the push callback returns. The push callback then
  waits until the system answers the report, for at most 3 seconds: on an iPhone 13, the system
  answered reports of calls that a Focus filtered after about 2.1 seconds. It never links CallKit.
  It logs, under the subsystem `VoIPLiveCommunicationKit`, the system's error for every refused
  action and every report that the system didn't present, and how long each report took.
  `VoIPConfiguration.supportsVideo` (default `false`) tells the system whether calls can have
  video.
- `VoIPActor.assumeIsolated(_:file:line:)` runs a system callback that arrives on
  `VoIPActor.queue`, such as a PushKit callback, on the actor without hopping, and
  stops the app when the callback arrives elsewhere.
- The `VoIPPushKit` library's `PushKitSource` receives VoIP pushes from PushKit on `VoIPActor`,
  and finishes each push exactly once, within 4 seconds. On iOS 26.4 and later it reads the
  `mustReport` metadata, but trusts a push that the system says needn't be reported only while
  the app is active: it requires a report for every push that arrives while the app isn't active.
  It follows the app's activity from UIKit's notifications, from when it is created, and counts
  the app as inactive until UIKit says that it became active. It logs, under the subsystem
  `VoIPPushKit`, each push that it requires a report for although the system said it needn't.
  `PushCompletion(systemRequiresReport:appIsActive:finish:)` applies the same rule for other push
  sources, and `FakePushSource.deliver(_:systemRequiresReport:appIsActive:)` delivers a push as
  the PushKit source does. `init(decode:)` takes the app's decoder for its push payloads, and
  `tokens()` streams the VoIP push token for the app to register with its servers. The CocoaPods
  `PushKit` subspec links UIKit.
- `VoIPPush(defaultFormat:)` decodes the SDK's existing `incomingCall` and `callEnded` push
  payloads, keeping every JSON value in an incoming call's `metadata` object.
- `JSONValue` is a JSON value: `null`, `bool(_:)`, `number(_:)`, `string(_:)`, `array(_:)` or
  `object(_:)`, written with literals. `Call`, `IncomingCall` and `OutgoingCall` carry the app's
  `metadata` as `[String: JSONValue]`.
- The `VoIPSimulator` library's `VoIPSimulator.activate()` starts the simulator runtime in
  Debug simulator builds, before `VoIPClient.start`, so the shipping adapters present calls,
  activate audio and receive VoIP pushes in the iOS Simulator. Elsewhere it does nothing. The
  runtime now attributes a LiveCommunicationKit report entered while a push callback runs to
  that push, as LiveCommunicationKit reports from its own queue.
- `VoIPClient.report(_:)` returns how the call appears on this device: `previewed(_:)` for a
  call preview, including a filtered call that the policy previews, and `notShown` when the
  policy is `none`, instead of `presented`. `PresentationOutcome` adds both cases.
- The `VoIPAudio` library's `AudioSessionAdapter` is the audio session for calls; pass it to
  `VoIPClient.start` as `audio`. Before the SDK completes an answer, start or join, it sets
  `AVAudioSession` to the play-and-record category in voice chat mode with Bluetooth hands-free
  and A2DP, and the speaker by default for calls with video; `AudioSessionConfiguration`
  changes these. It never activates the session. It reads interruptions from
  `didBecomeInactiveNotification` and `resumptionRecommendationNotification` on iOS 27, and
  from `interruptionNotification` before, and passes them and media services resets to the SDK.
  Its `routes`, an observable `AudioRoutes`, list the `AudioRoute`s that calls can use and the
  current one, and `selectRoute(_:)` picks one.
- `VoIPCore` adds the `AudioSession` seam with `AudioSessionEvent`, `AudioInterruptionReason`
  and `AudioSessionError`, and `VoIPClient.start` takes `audio`. When the system interrupts
  active audio, the SDK stops the media and sends `CallEvent.audioInterrupted(_:)`. After a media
  services reset it sends `CallEvent.mediaServicesReset` and configures the session again. Once
  the interruption ends, or after the reset, a call that takes part and isn't on hold ends with
  `CallFailure.audioRecoveryTimedOut` unless the system activates audio within
  `Deadlines.audioRecovery` (5 seconds). A call whose audio session can't be configured ends with
  `CallFailure.audioSession`, or a join returns to its call preview. `CallMedia.deactivate()`
  now follows `activate()` once per activation. Switches over `CallEvent` and `CallFailure` need
  the new cases. See [ADR 0007](docs/adr/0007-sdk-configures-audio-session.md).
- `VoIPTesting` adds `FakeAudioSession`.
- The CocoaPods spec ships the call core as subspecs that mirror the Swift package's products:
  `Core`, `Audio`, `LiveCommunicationKit`, `PushKit`, `Simulator` and `Testing`.
  CocoaPods builds them into the one `IosVoipSDK` module, so code that uses them imports
  `IosVoipSDK`. `pod 'IosVoipSDK'` without a subspec installs `Core`, `LiveCommunicationKit` and
  `PushKit`.
- `Examples/CallExample` is a SwiftUI app that starts `VoIPClient` with the LiveCommunicationKit
  adapter, the PushKit source and the audio session adapter, shows the VoIP push token and the
  audio routes, and reports, answers, mutes and ends a call, with `CallMedia` as a stub. It
  handles call events in a `CallObserver`, so that it also handles the call of the VoIP push that
  launched it. CI builds it for the simulator and for devices.
- `VoIPClient.confirmNotPlaced(_:)` tells the SDK that the app couldn't place a call it was
  asked to start or join, after `CallEvent.startRequested(_:)` or `joinRequested(_:)`. The SDK
  fails the start or join in the calling framework at once, without waiting for
  `Deadlines.placement`: an outgoing call ends with `CallFailure.notPlaced`, and a call being
  joined returns to its call preview. An app that ended such a call as a server failure, with
  `receive(.failed, for:eventID:)`, calls `confirmNotPlaced(_:)` instead.
- `CallEvent.joinFailed(_:)` tells observers that joining a call ended before the call took part
  here: the calling framework refused or dropped the join, the app didn't place it, its media or
  audio failed, or the user ended it on the system's call screen. The call returned to its
  preview, and `previewStarted(_:)` follows. Observers learn of a failed join wherever it
  started, so the call notifier can tell the preview from one the user hasn't seen. Switches over
  `CallEvent` need the new case.
- `CallObserver` follows calls from the moment the client starts. Pass observers to
  `VoIPClient.start` as `observers`: the client calls each one's `attach(to:)`, in order, before
  it attaches the calling framework, the audio session and the push source, and keeps them for
  its life. An observer that subscribes to `events()` in `attach(to:)` receives every event,
  including those of the VoIP push that cold-launched the app, which a stream created after
  `start` returns can miss. `observers` defaults to none, so existing calls to `start` don't
  change. `FakePushSource(pending:)` delivers pushes as soon as the client attaches, as PushKit
  delivers the push that cold-launched the app.
- `Deadlines.mediaPreparation` (2 seconds) is how long the SDK holds an answer, start or join
  while `CallMedia.prepare(_:)` runs; when it passes, the call ends with `CallFailure.media`, or a
  call being joined returns to its call preview. Its documentation describes what the user sees
  meanwhile and the system's own limit on actions, and recommends around 15 to 20 seconds for
  media that claims and joins a room over the network after a cold launch.
- The `VoIPFocus` library records the Focus filter state: what the app's Focus filter last asked
  for, `FocusFilterState.unknown`, `inactive(since:)` or `active(_:since:)` with the app's own
  settings type. `FocusFilterStore(appGroup:)` shares it between the app and its extensions
  through the App Group's `UserDefaults`: `record(_:defaults:)` records the settings that the
  filter runs with, inactive when they equal its defaults, since the system resets the filter to
  them when the Focus turns off; `state` reads it, and `states()` follows changes from any
  process through a Darwin notification. Until the filter first runs, or when the state can't be
  read, it is unknown. The state encodes to JSON for the app's servers. The library imports only
  Foundation and AppIntents and doesn't depend on `VoIPCore`; CocoaPods ships it as the `Focus`
  subspec. See [ADR 0008](docs/adr/0008-focus-filter-defaults-are-inactive.md).
- `CallFocusFilter` is the app's Focus filter: a `SetFocusFilterIntent` with the app's
  `settings`, a `store` and `didRecord(_:)`. Its default `perform()` records the state that the
  settings ask for, then calls `didRecord(_:)`, where the app sends the state to its servers.
  Declare it in an App Intents extension, which the system runs on each Focus change without
  launching the app. The example app's `FocusFilter` extension declares one and the app shows its
  state.
- The `VoIPNotifications` library's `CallNotifier` is a `CallObserver` that posts a
  `CallNotification`, a communication notification, for each call that Do Not Disturb or a Focus
  filtered, through a `CallNotificationCenter`. It posts once per call, when the call becomes a
  call preview, or ends at once as filtered when the presentation policy doesn't preview filtered
  calls; with the `previewedByPolicy` trigger it also posts for calls that the policy previews.
  It never posts for a call that rings or a block-listed caller. Its notifications are passive or
  active, with the default sound or none, and never ring (see
  [ADR 0009](docs/adr/0009-call-notifications-never-ring.md)). When the call is joined here, it
  withdraws the notification; when the call ends without being joined here, it replaces the
  notification with a missed-call notification, unless `Options.endedWithoutJoining` keeps or
  removes it. A call that the user tried to join counts as joined, even when the system refused
  the join or it failed later, from a notification, a call preview's Live Activity or the app:
  the notifier withdraws its notification as for a join, and posts nothing when the call returns
  to its preview or ends. On an iPhone 13, a refused join from a call preview's Lock Screen card
  posted "incoming", then "missed" when the call ended. `Options.customize` changes or drops each
  notification, for example to localize its English text, and `events()` reports what was posted, withdrawn or refused. `VoIPTesting` adds
  `FakeCallNotificationCenter`, and the CocoaPods spec adds the `Notifications` subspec, which
  `Testing` includes.
- `UserNotificationsAdapter` is `CallNotifier`'s notification center on iOS, and `CallNotifier()`
  uses it. For each notification it donates an incoming `INInteraction` whose `INStartCallIntent`
  has the caller as its only contact, an `INPerson` made of the party's handles and display name,
  then updates the content from the intent with `UNNotificationContent.updating(from:)`. The
  request identifier is the Call ID, so a missed-call notification replaces the incoming one.
  `content(for:updating:)` builds the same content in a notification service extension, and
  `category(joinTitle:)` is the incoming call's category, with a Join action. The app needs the
  Communication Notifications capability, `INStartCallIntent` in `NSUserActivityTypes` and the
  user's permission for notifications.
- `CallNotifier.handle(_:)` routes a `CallNotificationResponse`, read from a
  `UNNotificationResponse`, or a `StartCallRequest`, read from the `INStartCallIntent` that Recents
  and Siri send. When a call preview with the call or the party is live here, it requests the join
  and returns `CallNotificationRoute.joining(_:)`; otherwise it returns `callBack(_:hasVideo:)`, and
  the app calls the party with a Call ID of its own. It requests the join once the app is active:
  when the app isn't active yet, it waits up to 2 seconds for it to become active, then requests
  the join anyway. On an iPhone 13, LiveCommunicationKit refused 4 of 4 joins that a call
  notification's tap or Join action requested while the app was still coming to the foreground,
  with the call service's `com.apple.CallKit.error.requesttransaction` code 6 (`invalidAction`);
  two of them were requested 84 and 233 ms after the response, about half a second before the app
  became active. Joins from a call preview's Lock Screen card, which the system performs once the
  app is in the foreground, succeeded 4 of 4. `handle(_:)` is unavailable in app extensions, which
  can't read the app's state. `Options.joinsOnTap` (default `true`) joins on a tap as well as on
  the Join action. The `Notifications` subspec links UserNotifications, Intents and UIKit, and the
  example app previews a call with a call notification. The documentation and the example isolate
  the app's `UNUserNotificationCenterDelegate` and its conformance to the main actor: the system
  stopped the example on every routed tap when its delegate's `async` method finished on another
  thread.
- The `VoIPLiveActivity` library's `CallPreviewAttributes`, with its `ContentState` and
  `CallPreviewStatus`, is the type of a call preview's Live Activity. Its JSON is a contract with
  the app's servers, which start, update and end call previews with ActivityKit push
  notifications: [the contract](docs/call-preview-activity.md) describes every payload, with
  dates as Unix timestamps in seconds, and `docs/contracts/call-preview-activity.json` holds its
  test vectors. A snippet is shortened to 240 characters. The CocoaPods `LiveActivity` subspec
  ships it. See [ADR 0010](docs/adr/0010-call-preview-activity-is-sdk-type.md).
- `CallPreviewActivities` is a `CallObserver` that shows call previews as Live Activities. Pass
  it to `VoIPClient.start` as an observer. When a call becomes a call preview in the foreground,
  it starts a Live Activity, which stays current for `Options.staleAfter` (2 minutes); in the
  background, where the system refuses, it sends `startFailed(_:_:)` with
  `CallPreviewError.notInForeground` without asking ActivityKit, which once blocked the main
  thread for 7.5 seconds before refusing, and the app's servers start the preview with the
  push-to-start token. It follows the Live Activities that the servers start, keeps one per call,
  ends a preview at once when this device joins its call, and shows the final state for
  `Options.endedDismissal` (2 minutes) when the call ends. `events()` starts with `started(_:)`
  for each preview that already runs, as `pushTokens()` starts with their tokens.
  `pushToStartTokens()`, `pushTokens()` and `authorization` with `authorizationUpdates()` give the
  app what its servers need; `start(_:state:)`, `update(_:_:)` and `end(_:dismissal:)` let the app
  manage previews itself. The first preview that the servers start gets its push token only once
  the user answers the system's second question about the app's Live Activities, which the
  documentation and the server contract explain. `ActivityKitAdapter` is its `LiveActivityCenter`
  on iOS, unavailable in app extensions, and `VoIPTesting` adds `FakeLiveActivityCenter`, so the
  CocoaPods `Testing` subspec now includes `LiveActivity`.
- Joining from a call preview's Live Activity: `CallPreviewActivities.join(_:)` requests
  `Action.join(_:)`, and a call that the client doesn't know, because the servers started its
  preview before the app ran, is joined with the new `VoIPClient.join(_:)` from the Live
  Activity's attributes; it ends with its preview unless it is joined. `VoIPClient.join(_:)`
  creates a call that the client doesn't know without `CallEvent.previewStarted(_:)`, so that a
  `CallNotifier` doesn't post and withdraw a notification for a join that the user started, and
  applies the server events that arrived for the call first, so that joining a call that already
  ended throws `ActionError.notAllowed(_:)` with its ended status instead of posting a
  notification and a missed-call one. The app declares a
  `JoinCallPreviewIntent`, a `LiveActivityIntent` of four lines, in a file that the app and its
  widget extension both compile, with `supportedModes` set to `.foreground(.immediate)` so that
  the system opens the app before the join, and `isDiscoverable` set to `false` so that Shortcuts
  and Spotlight don't offer Join Call with a free-text call ID. `CallPreviewView` is the default Lock Screen
  presentation, and `CallPreviewView.dynamicIsland(_:join:)` the compact, minimal and expanded
  ones. They show the status and the timer on lines of their own, so that the status isn't cut
  short beside Join, and Join keeps the size of its title and symbol, so that a long status
  doesn't squeeze it to its symbol without the "Join" title and accessibility label.
  `CallPreviewError` adds `unknownCall`, `notAttached` and `join(_:)`. The
  CocoaPods `LiveActivity` subspec links AppIntents, SwiftUI, UIKit and WidgetKit, and the example
  app previews a call and shows it from a widget extension.

### Changed

- `cksim` is a Swift command-line tool, built from the package's `cksim` product, and no longer
  needs Python. Its commands and options are the same, and shared options may still come before
  the command. Its JSON output sorts keys, and a usage error now exits with status 64. Build the
  standalone runtime with `node tools/build-runtime.ts <output>` (Node.js 24), which replaces
  `scripts/build-runtime.sh`; `CKSIM_BUILD_ARCHS=arm64` becomes `--archs arm64`. The Inspector
  is built with `node tools/build-inspector.ts <output>`.

### Breaking changes

- The old core is removed: the `VoIPSDK` product and its `ConversationClient`,
  `ConversationHandler`, `VoIPApplication`, `PushService`, `PushWire`, `MediaAdapter`,
  `SimulatorSupport`, audio routes, `DialRequest` and `VoIPSystemEntryPoints`, together with
  the Expo module, its config plugin and npm package, the `Integrations/LiveKit` media adapter
  and the Expo example. The call core replaces them. React Native and Expo apps use
  [expo-callkit-telecom](https://github.com/relayphone/expo-callkit-telecom) v2, whose iOS module
  runs on the call core. `pod 'IosVoipSDK'` without a subspec now installs `Core`,
  `LiveCommunicationKit` and `PushKit` instead of the `ExpoModule` subspec, which no longer
  exists.

  The call core keeps each call's state by its `CallID` and performs the user's actions itself,
  then tells the app, so there are no action handlers to register. Only starting or joining a
  call waits for the app, which places it and then calls `confirmPlaced(_:)`, or
  `confirmNotPlaced(_:)` when it can't. Migrate as follows:

  | Old core | Call core |
  | --- | --- |
  | `VoIPApplication.start(configuration:mediaAdapter:audioPolicy:)`, `startFromBundle(_:mediaAdapter:audioPolicy:)` | `VoIPClient.start(framework:media:push:audio:observers:configuration:clock:)` with `LiveCommunicationKitAdapter()` and `PushKitSource()` |
  | `ConversationClient.Configuration` | `VoIPConfiguration`: `maximumConversationGroups` becomes `maximumCalls`, `ringtoneName` becomes `ringtoneSound`, `includesConversationInRecents` becomes `includesCallsInRecents` |
  | `ConversationSnapshot`, `snapshots`, `observeState(_:)` | `Call` and `VoIPClient.calls`, which SwiftUI and Observation track |
  | `observeEvents(_:)`, `ConversationEventContext` | `VoIPClient.events()` and `CallEvent` |
  | `ConversationHandler` and `setConversationHandler(_:)` | `CallEvent.performed(_:_:)` after the SDK performs an action; `CallEvent.startRequested(_:)` and `joinRequested(_:)`, then `confirmPlaced(_:)` or `confirmNotPlaced(_:)` |
  | `startConversation(to:video:metadata:)` | `request(.start(OutgoingCall(id:parties:hasVideo:metadata:)))` |
  | `joinConversation(_:)`, `endConversation(_:)`, `setMuted(_:_:)`, `setHeld(_:_:)`, `playTones(_:_:)` | `request(_:)` with `.answer(_:)` (or `.join(_:)` from a call preview), `.end(_:)`, `.mute(_:muted:)`, `.hold(_:onHold:)` and `.playTones(_:digits:)` |
  | `reportIncomingConversation(_:source:)` with `IncomingCallPayload` | `report(_:)` with `IncomingCall`, which returns a `PresentationOutcome` |
  | `receiveCallEnded(_:)`, `reportConversation(_:report:)` | `receive(_:for:eventID:)` with a `ServerEvent` |
  | `Caller`, `Participant` | `Party` with one or more `Handle`s; phone numbers must be E.164 |
  | `ServerCallID` and the conversation `UUID` | `CallID`; the SDK derives the per-device UUID and never exposes it |
  | `PushService`, `observeToken(_:)` | `PushKitSource` and `tokens()` |
  | `PushWire`, `PushService.receiveRemoteMessage(_:)` | `VoIPPush(defaultFormat:)`, or a decoder passed to `PushKitSource(decode:)`; apply a push from another channel with `report(_:)` or `receive(_:for:eventID:)` |
  | `JSONValue` metadata | `[String: JSONValue]` metadata, which is never `nil`; `int(_:)` and `double(_:)` become `number(_:)` |
  | `MediaAdapter`, `NoMediaAdapter`, `Integrations/LiveKit` | Your own `CallMedia` |
  | `observeAudioRoutes(_:)`, `selectAudioRoute(_:)`, `AudioRoutesSnapshot` | `AudioSessionAdapter.routes` and `selectRoute(_:)` in `VoIPAudio` |
  | `AudioActivationPolicy` | `Deadlines.audioActivation` and `audioRecovery` |
  | `SimulatorSupport.activateIfNeeded()` | `VoIPSimulator.activate()` |
  | `pod 'IosVoipSDK'` (`ExpoModule`) and `import IosVoipSDK` | The `Core`, `Audio`, `LiveCommunicationKit`, `PushKit` and `Simulator` subspecs, still imported as `IosVoipSDK` |
  | The Expo module from `github:relayphone/ios-voip-sdk` | expo-callkit-telecom v2 |

  The call core doesn't yet handle `tel:` URLs, or donate calls to Siri and Recents. Keep doing
  these in the app until it does. `StartCallRequest` in `VoIPNotifications` reads the
  `INStartCallIntent`s that Recents and Siri send.

- The `VoIPCallKit` library, its `CallKitAdapter` and the `CallKit` CocoaPods subspec are
  removed: LiveCommunicationKit is the SDK's only calling framework. Apps that used them depend
  on `VoIPLiveCommunicationKit`, or the `LiveCommunicationKit` subspec, and start the client with
  `LiveCommunicationKitAdapter()`; the rest of the API is unchanged. A Focus that doesn't allow
  the app now filters its calls even from people the Focus allows, and the SDK reports them as
  filtered calls. See [ADR 0002](docs/adr/0002-one-calling-framework-per-build.md).

- The `VoIPSDKTesting` product is now `VoIPTesting`. Depend on
  `.product(name: "VoIPTesting", package: "ios-voip-sdk")` and `import VoIPTesting`;
  `TestClock` is unchanged.

- The SDK now requires iOS 26, macOS 26 for host tests, and Swift tools 6.4
  (Xcode 27.1) in the Swift 6 language mode. The Swift package, the CocoaPods
  spec and the example app declare iOS 26. Raise your app's deployment target.

- Inspector controls now validate complete runtime responses before awaiting
  journal confirmation. Custom bridges must return the existing runtime identity,
  UUID request/action/transaction identifiers and the operation's complete result
  fields, including `configured: true` for fault acknowledgements. Mismatched
  result kinds or identities are rejected; the flat version-one wire is retained.

- Runtime mailbox requests now reject parameters belonging to other controls,
  duplicate JSON fields and empty fault updates. Custom clients must provide
  ordinary integer tokens for integer fields and distinct UUIDs for multi-call
  controls. Push integers outside the signed/unsigned 64-bit range must be strings;
  floating values must fit a finite Double without underflow. Requests with a valid current
  identity and invalid parameters receive a rejection response; ambiguous or
  foreign identities are discarded. The CLI keeps the existing flat v1 format.

- The Inspector now decodes the same validated session model as the runtime.
  Custom session fixtures must include `controlTransport: "directory-watch-v1"`,
  schema version 1, a positive process ID, nonempty bundle/profile names and a
  run ID of 1–64 ASCII letters, digits, underscores or hyphens. Rebuild the
  Inspector together with the runtime when updating custom integrations.

- Simulator runtime packages no longer include `cksim-notify`, and sessions no
  longer publish a `notification` key. Controls use `directory-watch-v1`; rebuild
  runtime packages and relaunch apps before using the updated CLI with older
  runtime sessions.
