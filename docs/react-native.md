# React Native and Expo

`@relayphone/ios-voip-sdk` is the SDK's iOS Expo module. It presents calls through
LiveCommunicationKit, receives VoIP pushes with PushKit, and exposes call state, commands and
events to JavaScript. Its version follows the repository's `VERSION`, and future package
releases come from the same tag as the Swift SDK.

The package is distributed as a GitHub release asset, with no npm registry token required.
It first ships in the next SDK release; the existing `v0.3.0` tag predates `expo/`.
`private: true` prevents accidental npm publication and still permits tarball installation.

## Install from a release

Use macOS with Xcode 27.1 or later, iOS 26 or later, and Node.js 26 for the commands below.
The example uses Expo 57, React Native 0.86.3 and React 19.2.3. The package requires Expo 57 or
later and a development build containing its native module; it doesn't run in Expo Go.

Choose a released version that includes the package and replace `X.Y.Z` below. Install the
asset pinned to that tag in your Expo app:

```sh
npm install https://github.com/relayphone/ios-voip-sdk/releases/download/vX.Y.Z/relayphone-ios-voip-sdk-X.Y.Z.tgz
npx expo install expo-build-properties
```

The release includes checksums and an attestation; see [release verification](runtime-releases.md#verifying-a-release).

### Evaluate unreleased changes

Until the next release, or to evaluate changes on `main`, pack a full checkout:

```sh
git clone --branch main https://github.com/relayphone/ios-voip-sdk.git
cd ios-voip-sdk/expo
npm ci
npm pack
```

This produces `relayphone-ios-voip-sdk-<version>.tgz` using that checkout's `VERSION`.
Keep the full repository while packing: `prepack` builds the API and config plugin and copies
the SDK sources from `Sources/` into `expo/ios/Vendor/`. The tarball is self-contained.
Install it in your app with `npm install /path/to/relayphone-ios-voip-sdk-<version>.tgz` and
install `expo-build-properties` as above. A tarball packed from `main` is for evaluation.

### Build the app

Configure the plugin as below, then generate and build the native app:

```sh
npx expo prebuild --platform ios
npx expo run:ios
```

The tarball includes the SDK targets its podspec builds. Don't add a separate `IosVoipSDK` pod
or Swift package to the same app. Rebuild the native app after changing plugin options.

## Config plugin

Wrappers and typed app configs can import the plugin's options and function type from
`@relayphone/ios-voip-sdk/plugin`. This entry loads the config plugin without loading the native
bridge; the default export is the same plugin used by `app.plugin`:

```ts
import type withVoIPConversations from "@relayphone/ios-voip-sdk/plugin";
import type { VoIPConversationsPluginProps } from "@relayphone/ios-voip-sdk/plugin";

type IOSPlugin = typeof withVoIPConversations;
const iosOptions = { mediaAdapter: "webrtc" } satisfies VoIPConversationsPluginProps;
```

For an app without WebRTC media, start with this `app.config.ts`:

```ts
import type { ExpoConfig } from "expo/config";

const config: ExpoConfig = {
  name: "Calls",
  slug: "calls",
  ios: { bundleIdentifier: "com.example.calls" },
  plugins: [
    ["expo-build-properties", { ios: { deploymentTarget: "26.0", enableSceneSupport: true } }],
    ["@relayphone/ios-voip-sdk", { mediaAdapter: "none", simulator: true }],
  ],
};

export default config;
```

The plugin configures iOS only. It adds VoIP and audio background modes, the APNs entitlement
and `INStartCallIntent` for Siri, Contacts and Recents. It also configures microphone and camera
permission messages. Provision the app for Push Notifications to receive real VoIP pushes.

| Option | Default | Effect |
| --- | --- | --- |
| `mediaAdapter` | `"webrtc"` | `"webrtc"` coordinates WebRTC's audio session; `"none"` leaves audio integration to the app. |
| `unhandledAction` | `"fail"` | `"accept"` treats a start or preview join that receives no handler as placed. Register a handler when placement needs app signaling. |
| `simulator` | `false` | Includes the simulator runtime for Debug iOS Simulator builds. |
| `callNotifications` | `false` | Adds communication notifications for calls that Do Not Disturb or a Focus filters. Requires `expo-notifications` and notification permission. |
| `callPreviewActivities` | `false` | `true` enables call preview Live Activities and generates a `CallPreviewWidget` extension and shared Join intent. `{ widgetExtension: false }` enables the integration with your own widget extension. |
| `focusFilter` | omitted | `{ appGroup: string, sources?: string[] }` enables Focus state sharing; see below. |
| `incomingCallTimeout` | `45` | Seconds before an incoming ring or outgoing dial times out. |
| `fulfillAnswerCallTimeout` | `30` | Seconds allowed to connect after answering. |
| `includesCallsInRecents` | `true` | Includes ended calls in the system's Recents list. |
| `sounds` | `[]` | Paths relative to the app root to bundle as ringtone resources; WAV is recommended. |
| `defaultRingtoneIos` | `"default"` | System ringtone, or a filename including its extension from `sounds`. |
| `iconTemplateIos` | omitted | App-relative path to a square template PNG for the call UI, about 40 × 40 points with the glyph in its alpha channel. |
| `microphonePermission` | `"Allow $(PRODUCT_NAME) to access your microphone"` | Permission message; `false` skips adding it. |
| `cameraPermission` | `"Allow $(PRODUCT_NAME) to access your camera"` | Permission message; `false` skips adding it. |

CallKit is allowed only inside the simulator runtime in Debug iOS Simulator builds; the module
uses LiveCommunicationKit, and device and Release builds exclude the runtime and do not link CallKit.

## Identity and state

`ConversationId` is the app's call ID, the SDK's `CallID.rawValue`, unchanged for incoming and
outgoing calls. Supply it as `serverCallId` for incoming calls and `id` to `startConversation`.
The SDK's platform UUIDs stay internal. Keep a distinct `eventId` for each server event so that
redelivery can be recognized.

`useConversations()` observes the immutable current list; `useConversation(id)` observes one
conversation; `getConversations()` reads the list outside React. State includes direction,
members, capabilities, mute/video flags, optional incoming payload and pending start/join.
Statuses are `ringing`, `previewing`, `dialing`, `connecting`, `connected`, `held`, `ending` and
`ended`. An ended conversation appears briefly with `ended.reason` and, on failure, its cause.

A `previewing` conversation follows a call without ringing or opening audio. Its
`previewReason.type` is `filtered`, `answeredElsewhere` or `policy`; a filtered preview also
carries `cause`. Joining it requests placement; ending it stops following the call on this device.

## Place outgoing calls and preview joins

Register one handler at module scope before React mounts. Its `start` and optional `join`
functions perform the app's signaling to place an outgoing call or join a preview. Resolve to
confirm placement, reject to fail it, and honor the supplied `AbortSignal` and deadline.
`setConversationHandler(null)` detaches the handler and cancels its outstanding work.

The following uses app-supplied signaling functions:

```ts
import {
  reportConversation,
  setConversationHandler,
  startConversation,
  type Conversation,
  type ConversationId,
} from "@relayphone/ios-voip-sdk";

declare function placeCall(call: Conversation, signal: AbortSignal): Promise<void>;
declare function joinCall(call: Conversation, signal: AbortSignal): Promise<void>;

setConversationHandler({
  start: (call, { signal }) => placeCall(call, signal),
  join: (call, { signal }) => joinCall(call, signal),
});

export async function callAlice(serverCallId: string): Promise<ConversationId> {
  return startConversation({
    id: serverCallId,
    to: { id: "alice", displayName: "Alice", phoneNumber: "+14155550123" },
    video: false,
  });
}

// Call when the app's transport actually connects, independently of placement.
export async function mediaConnected(id: ConversationId): Promise<void> {
  await reportConversation(id, { type: "connected" });
}
```

`startConversation` resolves with the supplied ID once the handler places the call and the SDK
starts it, after the media's `prepare` completes. For a preview, `joinConversation` likewise
resolves once the join handler places the call and the SDK carries out the join, after `prepare`
completes. Neither command waits for the transport to connect. Both reject if placement fails,
media preparation fails, or the SDK doesn't carry out the action within its deadlines
(`deadline_exceeded`). The handler must not wait for its command's promise. Report `connecting`
and `connected` separately as transport facts; reports made inside a handler are
held until placement completes. With the default policy, an app start without a handler fails
immediately, and other unhandled placement actions fail by their deadline.

The SDK performs answer, end, hold, mute and tones natively, including before JavaScript loads.
These actions never consult the handler. Observe snapshots and `actionPerformed` events to
update the app's UI and media. Answering a ringing call uses `joinConversation(id)` without a
handler; joining a preview uses the `join` handler. If a preview join fails, it returns to
`previewing` and emits `joinFailed` with a typed reason: `ended`, `refused`, `frameworkReset` or
`failed` with its failure cause.

## Commands, reports and events

| API | Meaning |
| --- | --- |
| `joinConversation(id)` | Answer a ringing call or join a preview. |
| `endConversation(id)` | End a call or stop following a preview. |
| `setHeld(id, held)`, `setMuted(id, muted)` | Request hold or mute. |
| `playTones(id, digits)` | Send tones. |
| `mergeConversations(first, second)` | Merge two calls when their capabilities allow it. |
| `reportConversation(id, report)` | Report `connecting`, `connected`, `updated` members or `ended` with a reason from the transport. |
| `reportIncomingConversation(payload)` | Present an incoming call learned through the app's own connection. Returns an outcome, which may be a preview, filtering, capacity or failure rather than a ringing call. |
| `receiveCallEnded(payload)` | Apply a server end signal to a known incoming call; returns whether it was accepted. Observe state/events for its completion. |

For an incoming call received through your foreground signaling connection:

```ts
import { reportIncomingConversation } from "@relayphone/ios-voip-sdk";

export async function incomingCall(serverCallId: string, eventId: string) {
  return reportIncomingConversation({
    eventId,
    serverCallId,
    caller: { handleType: "phone", value: "+14155550123", displayName: "Alice" },
    hasVideo: false,
  });
}
```

VoIP pushes use an `incomingCall` object with those same fields. Native code registers PushKit
at launch and reports calls before JavaScript runs. `usePushToken()` returns the current
`{ type: "apns-voip", value }` or `null` after invalidation; send changes to your servers. See
the [SDK quick start](../README.md#quick-start) for push reporting and server-event guidance.
Phone handles require an international `+` country code and normalize to E.164; email and
generic handles keep their values.

`incomingConversationOutcome` retains the most recent 16 outcomes while JavaScript has no
listener, dropping the oldest if full. The first listener receives them once in arrival order.

`useConversationEvent(name, listener)` subscribes to lifecycle signals. In addition to
`joinFailed` and `actionPerformed`, events include `incomingConversationOutcome`,
`answeredElsewhere`, `dialRequest`, `providerReset`, audio activation/deactivation and
`audioActivationMissing`. The optional integrations add `callNotification`,
`callNotificationRoute` and `callPreview`. State belongs in the snapshot; use events for facts
such as a correlated server event or a notification response. Public event and payload types
are in [`conversations/types.ts`](../expo/src/conversations/types.ts).

Commands reject with errors whose `code` and `message` describe the failure and whose optional
`nativeDomain` and `nativeCode` preserve native details. Placement rejection uses
`handler_failed`; missing its deadline uses `deadline_exceeded`. Incoming reports return a
typed `IncomingConversationOutcome` instead of inventing a conversation ID on failure.

## Media and audio routes

The package coordinates calls and audio; the app connects its own room or peer connection.
With `mediaAdapter: "webrtc"`, provide a WebRTC implementation such as
`@livekit/react-native-webrtc`, as the example does. The adapter puts WebRTC's audio session in
manual mode and starts/stops its audio with system activation. LiveKit's React Native SDK uses
WebRTC's audio session too, so use `"webrtc"` with LiveKit. Do not also activate the audio session
from JavaScript. With `"none"`, the app supplies its own media and audio integration.

`useAudioRoutes()` returns `{ routes, current }` from the SDK's `AudioSessionAdapter`;
`selectAudioRoute(route.id)` requests one of those routes. Use the returned IDs rather than
deriving them from route names.

For media that must prepare before JavaScript starts, register a Swift `CallMedia` through
`NativeCallMedia.register(_:observers:)` in an Expo app delegate subscriber's
`application(_:willFinishLaunchingWithOptions:)`, before the module starts the client in
`didFinishLaunching`. This overrides `mediaAdapter`. The SDK configures audio before
`prepare(_:)` and calls `activate()`/`deactivate()` with system audio changes; observers can
report transport progress through `VoIPClient.receive(_:for:eventID:)`.

[`NativeCallMedia`](../expo/ios/NativeCallMedia.swift) documents registration and
`mediaCredentials(for:)` for credentials kept out of JavaScript. A conversation has
`media: "native"` after that media prepares it; don't connect its media again in JavaScript.

## Notifications, call previews and Focus

For `callNotifications: true`, install `expo-notifications` with `npx expo install`, request the
user's notification permission, and keep it as the notification center's delegate. The module
uses it to receive responses to communication notifications for filtered calls.

For `callPreviewActivities`, set `ios.bundleIdentifier`. `useCallPreviewActivities()` and
`getCallPreviewActivities()` expose authorization, push-to-start tokens and per-preview update
tokens; send changes to your servers. The [Live Activity contract](call-preview-activity.md)
defines the JSON they send to ActivityKit. With `{ widgetExtension: false }`, supply your own
widget and Join intent instead of the generated extension.

For `focusFilter`, provide an App Group and, optionally, app-relative Swift source paths:

```ts
const focusFilter = {
  appGroup: "group.com.example.calls",
  sources: ["./focus/CallsFocusFilter.swift"],
};
```

Declare the app's `CallFocusFilter` with its own parameters, as the
[example](../expo/example/client/focus/CallsFocusFilter.swift) does. Use
`internal import VoIPConversations` in those Swift files: the imported SDK types aren't
re-exported as public dependencies. The plugin copies the files into the app and adds the App
Group entitlement; omit `sources` when your own App Intents extension declares the filter.

`useFocusFilterState()` and `getFocusFilterState()` return `unknown`, `inactive` or `active`
with the filter's settings. Send that state to your servers unchanged so they choose how each
call appears on this device. It describes the app's filter, not whether any Focus is on.
The Focus and Live Activity hooks/getters return `null` when their option is disabled.

## Example and simulator coverage

The [example app](../expo/example/client) includes notifications, a generated preview widget,
a Focus filter and WebRTC audio. Its [JavaScript journeys](../expo/example/client/journeys)
drive incoming answer/hold/end, outgoing start/connect/end, preview join, answered elsewhere
and a filtered preview. The [journey workflow](../.github/workflows/expo-journeys.yml) builds
the example from the packed module and checks its results and the simulator runtime journal.
