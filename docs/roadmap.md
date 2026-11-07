# Roadmap

The current release is listed in [`VERSION`](../VERSION) and the [changelog](../CHANGELOG.md).
Until 1.0, a minor release may change the public API, and the changelog says how to migrate.

## Toward 1.0

The work below is in priority order.

### 1. Production use

The [RelayPhone](https://github.com/relayphone) app is moving its iOS calls onto the SDK: incoming
VoIP pushes, presentation with LiveCommunicationKit, the audio session, and its own media through
`CallMedia`. Real use comes first because it found every fix in 0.2.1: late call notifications
after a push, missed-call notifications for calls that weren't missed, and native media without a
configured audio session.

### 2. Follow-up from device testing

Device testing on iOS 27.1 left two observations:

- **Resolved: push tokens of call previews started by push.** A call preview Live Activity that a
  push-to-start push created didn't deliver its push token to the app, through
  `CallPreviewActivities.pushTokens()`, within several minutes. Previews that the app started did.
  In device testing on iOS 27, the system gave a push-started preview its update token only once
  the user answered the system's question about the app's Live Activities on the Lock Screen,
  which could take minutes. This is platform behavior. Tests cover discovery before and after
  launch, delayed tokens and call ID mapping. See the
  [server contract](call-preview-activity.md#pushes) for handling a late token.
- **Open: Focus filter state.** With a Focus on whose filter was set for the app, the app read no
  Focus filter state from `FocusFilterStore`. This needs one device observation: turn the filter
  on, bring the app to the front, and read the `VoIPFocus` log. Diagnostics report whether the
  filter ran, its state, store read and write failures, and the state sent to JavaScript.

The Focus question is parked until a device is available. If the SDK is at fault, the fix ships
in a patch release with a test.

### 3. Reliable simulator tests in CI

The simulator journeys and runtime tests are what let an app test calls without a device, so they
must be trustworthy. On hosted runners, the simulator's test runner sometimes hangs before it
connects, and a red run then says nothing about the SDK.

- Retry only infrastructure steps (creating, booting, installing and launching before the app's
  first checkpoint), at most once, on a fresh simulator. Never retry a product assertion.
- Label every failure in the job summary as an infrastructure step or a product check.
- **Done when** main has 10 consecutive green runs with no infrastructure failure.

### 4. Simulator runtime fidelity

The [simulator runtime](simulator-runtime.md) should behave like a device wherever an app can
observe the difference.

- **Measure, or keep labelled as unverified:**
  - the filtered-call codes 5–7 (restricted sharing mode, protected call, sensitive participants);
  - the multi-call cases.
- **Device reference values** in the Inspector, next to each simulator measurement: push to
  report, join to audio activation, mute echo, and the PushKit termination delay.
- **The Inspector's GUI journey** runs as an automatic CI check on changes to the runtime or the
  Inspector. It asserts on the runtime's event journal, with screenshots for diagnosis only.

### 5. 1.0

1.0 freezes the public API. It ships once a minor release has run in production without needing
a breaking change, and after a review of the public names, documentation and deprecations.

## After 1.0

- **Apple Watch:** research how calls, pushes and audio work on watchOS, and which media options
  exist there, then add a CI build of `VoIPCore` for watchOS. `VoIPCore` already imports no UIKit
  or calling framework.
- **Mac Catalyst.**

## React Native, Expo and Android

[expo-callkit-telecom](https://github.com/relayphone/expo-callkit-telecom) v2 is the React Native
and Expo library. Its iOS module runs on this SDK, and its Android module runs on Core-Telecom. Its
roadmap lives in that repository.
