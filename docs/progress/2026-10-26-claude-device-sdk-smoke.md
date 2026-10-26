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

## Cold-launch race (delayed handler)

This was a rerun on main `47324e0` with the same local QA patch, never committed, plus one change: a delay before the JS call handler attaches, read from `Documents/qa-config.json` after React mounts. Each run was a cold background launch from a real VoIP push, with the app terminated and the phone unlocked. XCUITest tapped Accept as soon as it appeared, after confirming SpringBoard or InCallService was in front.

All times are in milliseconds. "After entry" means after process start; "after Join" means after the system Join reached the SDK.

| Run | Handler delay | Ringing after entry | JS ready / handler attached after entry | Join pending until handler | Connected / capture / audio activated after Join | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| Race 1 | 5,000 | 269 | 371 / 5,781 | **3,237** | 3,264 / 3,303 / 3,462 | Connected; clean End |
| Race 2 | 5,000 | 291 | 705 / 5,901 | **3,356** | 3,379 / 3,416 / 3,543 | Connected; clean End |
| Race 3 | 5,000 | 201 | 245 / 5,292 | **2,925** | 2,950 / 2,983 / 3,102 | Connected; clean End |
| Control | 0 | 192 | 239 / 562 | 6 (handler already attached) | 81 / 128 / 343 | Connected; clean End |
| Past the deadline | 40,000 | 227 | 270 / 40,352 | Never: **pending cleared 27,028 after Join (29 after the SDK deadline)** | — | **Call ended by the default `fail` policy**; no audio activation; handler attached later, too late |

**Findings:**

- **Join waits for the handler.** A system Join that arrives before the JS handler stays pending in the SDK, shown as `ringing` with a pending `join` from the `system` origin. It completes within about 10 ms of the handler attaching. Connection, LiveKit capture and audio activation then follow normally, with audio about 185 ms after the handler runs. There was no `audioActivated` before fulfillment.
- **Deadline and policy.** The SDK's Join deadline was 26.99 to 27.00 s after Join in every run. That's the reported 30 s minus its reserve, well inside iOS's own Join timeout of about 64 s measured on the device. When the handler misses it, the configured `unhandledAction: fail` ends the call 29 ms after the deadline.
- **What the user sees.** While Join is pending, the iOS UI already treats the call as answered (green call indicator and timer), but there is no media. Past the deadline the call disappears. **So a cold launch whose handler attaches late gives the user up to 27 s of silent "answered" call.** This isn't an SDK defect, but it's worth a product decision in M3.5: start the handler natively, or let apps choose a shorter Join budget for cold launches.
- **Natural race window.** Without a delay, the handler attached 562 ms after process start, about 370 ms after ringing. Neither XCUITest nor a person reliably answers inside that window.

**Locked lock-screen answering is still not covered.** During XCUITest sessions on this setup, `pressLockButton` didn't lock the phone even face-down, so calls arrived as Home Screen banners. This needs an attended run with the phone locked by its side button.

**No SDK bugs filed.** Cleanup: the QA build and the UI-test apps were uninstalled, the token copy was deleted, the build outputs were removed, and the device lock was released.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
