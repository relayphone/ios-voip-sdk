# PushKit through LiveCommunicationKit on a real device (iPhone 13, iOS 27.0, October 23, 2026)

**Setup.**

- Real sandbox APNs, using the team-scoped sandbox key, to the topic `dev.callkitsim.probe.voip`.
- The probe is `../../lckpush.swift`. It uses LiveCommunicationKit (LCK) only, and **no `CXProvider` is ever created** (D13).
- Each run is configured by `Documents/lck-push.json` in the app container. That's because cold launches get no launch environment.
- PushKit is delivered on a private serial queue.

**Strategies.**

- `entered`: start the LCK report in a detached task, wait for it to start, then return from the delegate. This is the SDK's fix.
- `deferred`: return immediately and report later on the main actor. This is the SDK's old behavior.

## Results

| Trace | Conditions | Result |
| --- | --- | --- |
| `d1-locked-cold-answer` | Cold launch, phone **locked**, `entered`. A person answered on the lock screen. | Metadata callback with `mustReport` true. The report started at 0 ms and the delegate returned at 55 ms. **The report succeeded at 191 ms**, and completion followed. The `JoinConversationAction` callback (the user's answer) arrived on main; `joined` came 95 ms later, and **`didActivate` 236 ms after that callback**. Auto-ended 5 s later. The process survived. Every LCK delegate callback arrived on main. |
| `d3-cold-unlocked-entered` and `-repeat` | Cold launch, unlocked, Focus **on** | The report failed after about 2.07 s with `com.apple.CallKit.error.incomingcall` code 3 (filtered by Do Not Disturb). The process survived: it was suspended, not killed. A second push from the same number **69 s later was also filtered**, so the "repeated calls" breakthrough didn't apply. |
| `d2-active-outgoing-foreground` | Connected outgoing LCK conversation, app in the foreground | The push had `mustReport` **false**. It was skipped, and the app stayed alive. |
| `d2-active-outgoing-background` | Connected outgoing conversation, app in the **background** (state 2) | `mustReport` **false**. "Already on a call" is its own rule, separate from being in the foreground. |
| `fb16655952-cold-deferred` (filtered) and `-ringing` | Cold launch, `deferred` (the report started 13 ms or 88 ms after the delegate returned) | **No crash on iOS 27.0**, on either the filtered or the ringing path. The ringing call ended unanswered after 25 s. FB16655952 did not reproduce, but keep the `entered` strategy anyway. |
| `late-report-3s` | Cold launch; the report started 3.15 s after delivery | Survived; the call rang. |
| `late-report-5s` | Cold launch; the report was due 5 s after delivery | **Killed about 4.4 s after delivery.** The crash is SIGABRT from an `NSAssertionHandler` failure in `-[PKPushRegistry _terminateAppIfThereAreUnhandledVoIPPushes]`. The trace contains alive markers at 2.088 s and 4.200 s; termination timing and crash attribution come from the device crash observation. |
| `echo-outgoing` | Connected outgoing conversation; app mute fulfilled 0, 300 or 1,000 ms after delivery | The system echo `MuteConversationAction` arrived **8–17 ms after the app *fulfilled*** its mute, never while it was pending. Unmute behaves the same. |

## Consequences

**PushKit has an in-process deadline of about 4.4 s from delivery.** It applies even if the app hasn't called the completion yet. Report immediately.

**SDK:**

- Nothing before the report may depend on main, the JS runtime or React Native boot.
- Required simulator CI uses a **proposed <500 ms budget** from PushKit delivery to native provider-report entry. The D1 fixture records `afterMs: 0` (separately rounded trace timestamps differ by 1 ms); 500 ms is a CI safety budget, not a measured Apple deadline.
- The 4.0 s completion watchdog is fine, but the *report start* is what must happen early.

**Runtime:** the simulator's push job should terminate the app at about 4.4 s when no report has been made, as an `ios-27.0` profile value.

**Filtered calls:**

- They arrive as `NSError` domain `com.apple.CallKit.error.incomingcall`, code 3, even through LCK. Map them by domain string, without linking CallKit.
- The app is not killed, so a backend or AI hook can run.

**`mustReport` is false** for both a foreground app and an app already on a call, including when it's in the background.

**The mute echo follows fulfillment.** The SDK must filter by value already recorded, not only by pending actions. `main`'s filter (#26) does this.

**Typical device latencies, for the simulator profile and inspector:**

| Step | Latency |
| --- | --- |
| Push delivery to report done (cold launch, locked) | about 190 ms |
| Join callback to `didActivate` | about 236 ms |
