# Device SDK smoke test (Claude, iPhone 13, iOS 27.0, October 26, 2026)

This is the first end-to-end run of the **SDK example app**, not a probe, on a real iPhone. It used real sandbox APNs VoIP pushes and the genuine system call UI.

## Setup

- **Source:** main `5419149`, built as a signed Release (bundled JavaScript) with `SDK_EXAMPLE_MEDIA_ADAPTER=livekit`.
- **App:** bundle `dev.iosvoipsdk.example`, topic `dev.iosvoipsdk.example.voip`, with `aps-environment=development` and no calling-app entitlement.
- **A local QA-only patch, never committed:**
  - native SDK state, event and token observers write timestamped rows to the app's Documents (the token goes to a private file and is never printed);
  - once Join settles, the patch reports connected, then cycles an app hold/resume and an app mute/unmute;
  - a JavaScript LiveKit `createLocalAudioTrack()` starts on connect and stops on end. It creates local capture demand only, with no room.
- **Driver:** XCUITest drove the system call UI and the app. Pushes were sent with `discovery/send-apns.mjs`. Timings compare the Mac's send time with the device's wall-clock trace rows (both NTP clocks).

## Results

| Flow | Result | Key timings |
| --- | --- | --- |
| Launch and PushKit registration | **Pass** | Token 254 ms after app entry |
| Foreground in-app incoming: Ring → Join → connected → hold → resume → End | **Pass** | Join to connected 19 ms; Join to audio activated 497 ms |
| Microphone permission and LiveKit local capture | **Pass** | Permission granted through the system alert; track started on connect and stopped on end |
| Cold launch from a real VoIP push, app terminated, three runs (see the locked-phone limitation below) | **Pass** | Process start 321–879 ms after send (APNs included); **ringing 169–274 ms after process start**; send to ringing 490–1,132 ms |
| Answer from the system banner, a genuine system Join | **Pass** | Handler 4–7 ms after Join; Join to connected 71–105 ms; **Join to audio activated 263–657 ms** |
| App hold and resume | **Pass** | Held or connected in 16–25 ms; audio deactivated or activated 70–90 ms later |
| App mute and unmute | **Pass** | `isMuted` 10–16 ms after the request |
| End | **Pass** | Ended in 13–17 ms; empty conversation state; capture stopped; audio deactivated 110–180 ms later |
| Foreground real push, no call | **Pass** | Ringing 914 ms after send. **The system showed its Accept banner even with the app in the foreground.** Join to audio activated 297 ms. |
| Second push during an active call | **Pass** | Reported 289 ms after send; the system offered End & Accept / Decline / Hold & Accept; the SDK tracked both calls; unanswered, the system ended the second call at 60.4 s and the SDK removed it cleanly |

**Pending-action deadlines the SDK reported:**

| Action | Deadline after the request |
| --- | --- |
| System Join | about 27 s |
| App hold and end | about 3.8 s (within the device-measured 5.3 s Pause/End limit) |
| App mute | about 28.5 s |

## Compared with the probe baselines

**Report done.** The SDK reached ringing 169–274 ms after process start. The probe measured about 190 ms from push delivery, so these are comparable.

**Join to audio activation.** The SDK measured 263–657 ms (median about 450 ms), against the probe's 236 ms from the Join callback to `didActivate`. The SDK's `audioActivated` event follows the LiveKit availability step. The variance is worth tracking in M-Stable performance work, but no failure was seen.

## Not covered by this run

1. **Answering on a truly locked phone, and the lock-screen in-call controls (system Mute/End).** The phone was locked before each push but always unlocked itself when the call rang, most likely through Face ID while someone was in view. So the call appeared as a Home Screen banner and answering opened the app. This needs an attended run with the phone face-down or covered.
2. **The cold race where JavaScript isn't ready.** Every answer came 3 s or more after launch, and the handler was already attached. Answering within about 1 s of a cold launch wasn't exercised.
3. **Outgoing calls.** The main example has no outgoing UI.
4. **Two-way media.** No LiveKit room or second participant; local capture only.

## Bugs

**No SDK bugs found.** One harness lesson: XCUITest taps on InCallService elements can land on the visible app when InCallService isn't on screen. Check the frontmost app before system-UI taps. The multi-call harness in `livecommunicationkit/multicall/` should do the same.

## Cleanup

All calls ended. The QA build and the UI-test apps were uninstalled, the private token copy was deleted, and DerivedData was removed. No settings were changed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
