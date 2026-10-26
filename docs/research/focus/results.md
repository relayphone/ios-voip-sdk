# Focus device results: first iPhone 13 pass

These are the measured results for the [device plan](device-plan.md) from [#124](https://github.com/ziahamza/ios-voip-sdk/issues/124). Claude ran them on 26 October 2026 with the [`spikes/focus`](../../../spikes/focus/README.md) probe. The probe uses only LiveCommunicationKit (LCK); CallKit was not tested. The run was cut short twice to return the shared phone, so this pass is partial; this page is updated as rows complete.

The rows were automated: XCUITest changed the settings and observed the screen, and pushes went through the sandbox. There is **one sample per row**; the plan asks for three. Traces, receipts and tokens stay in a private working folder and are not committed.

## Setup

| Item | Value |
| --- | --- |
| Device | iPhone 13, iOS 27.0 (24A5355q), unlocked, an XCUITest session observing. |
| Build | Xcode 27.1 (27A9275); probe from `main` plus this PR's harness fixes. Signed with a development certificate. |
| Signing | The App Group was removed locally, because command-line automatic signing cannot add that capability. |
| Delivery | Sandbox VoIP push to `dev.callkitsim.focus.voip`. Each push launched the probe cold. |
| Test Focus | Owned custom Focus "Focus Probe 124", in Allow Notifications From mode for both People and Apps. |
| Focus settings | Allow Calls From **Allowed People Only**, Allow Repeated Calls **off**, Time Sensitive Notifications off, Share Across Devices off. |
| Caller | One owned test contact with a single E.164 mobile number. The push identifies the caller by the same handle. |
| Communication Notification (CN) | When on: one local notification built from a genuine incoming `INStartCallIntent` at the active interruption level. |
| Observation | The call surface counts as observed when SpringBoard shows its Accept/Decline buttons (banner) or InCallService shows its root view (full screen). |
| Qualification | The visual observation is qualified by C00. Audio and haptics were **not measured**: the Mac microphone prompt was still pending. The Ring/Silent switch position was not recorded. |

The two allowlists also kept the defaults that iOS suggested for a new Focus: three Apple and messaging apps, and one personal contact. None of them took part in a call.

## Rows

"Report" is the LCK `reportNewIncomingConversation` result, measured from report entry. "Entry" is the time from push receipt to report entry.

| ID | Focus | App allowed | Caller allowed | CN | Report | Entry | Call surface |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C00 | Off | – | – | Off | reported, 81 ms | 2 ms | banner and full-screen call UI |
| F01 | Off | No | No | Off | reported, 63 ms | 1 ms | banner and full-screen call UI |
| F02 | Off | No | No | On | reported, 104 ms | 7 ms | banner and full-screen call UI; CN scheduled 74 ms after the report |
| F03 | Off | Yes | No | Off | reported, 73 ms | 2 ms | banner and full-screen call UI |
| F04 | Off | Yes | No | On | reported, 119 ms | 2 ms | banner and full-screen call UI; CN scheduled |
| F05 | Off | No | Yes | Off | reported, 82 ms | 2 ms | banner and full-screen call UI |
| F06–F08 | Off | | | | **skipped**: F01–F04 already establish the Focus-off baseline | | |
| F09 | **On** | No | No | Off | **filtered**: `com.apple.CallKit.error.incomingcall` code 3, after 2189 ms | 7 ms | none |
| F10 | **On** | No | No | On | **filtered**: code 3, after 2205 ms | 9 ms | none; CN scheduled |
| F11 | **On** | Yes | No | Off | **reported, 89 ms** | 1 ms | **banner and full-screen call UI** |
| F12 | On | Yes | No | On | pending | | |
| F13 | **On** | No | Yes | Off | **filtered**: code 3, after 2197 ms | 2 ms | none |
| F14 | On | No | Yes | On | pending | | |
| F15 | **On** | Yes | Yes | Off | **reported, 101 ms** | 4 ms | **banner and full-screen call UI** |
| F16 | On | Yes | Yes | On | pending | | |

Every unanswered reported call ended itself after the probe's 25 s ring timeout. After F13, the step that turns the Focus back off failed once because Contacts reopened in an unexpected state; the Focus was turned off a few minutes later and the harness now relaunches Contacts once to recover.

### Locked answer with Auto-Answer

| Run | Setup | Report | Answer |
| --- | --- | --- | --- |
| F01, locked | Focus off; Auto-Answer Calls on with a 3 s delay; phone locked with the lock button, then 45 s with no UI session; cold push | reported, 120 ms (entry 2 ms) | **`JoinConversationAction` arrived 3.4 s after the push** while the phone was locked; the conversation joined. The probe ended it after 23 s. |

Auto-Lock could not be changed under XCUITest. Selecting 30 seconds showed a checkmark, then read back as the previous value (Never). The run locked the phone with the lock button instead, so Auto-Lock played no part. The CN's own banner was not observed separately in F02, F04 or F10.

### Live Activity (L01, unqualified)

The Live Activity rows ran into probe and consent problems before measuring Focus. What was observed, Focus off, phone unlocked:

- **Two-stage consent.** iOS 27 asked for consent inline, on the probe's own Lock Screen card in Notification Center.
  - The first card asked "Allow Live Activities from Focus Probe?" (Don't Allow / Allow).
  - The next card asked "Do you want to continue to allow Live Activities from Focus Probe?" (Don't Allow / Always Allow).
  - The harness grants both for the disposable probe and reruns the row, because pushes sent before consent cannot qualify it.
- **Remote updates did not render, even after Always Allow.**
  - A priority-5 ActivityKit update was accepted by APNs (HTTP 200) but was not rendered after 2 minutes.
  - The card kept revision 0 and switched to "Updates delayed" once its 30 s stale date passed. Stale rendering itself works.
  - One diagnostic priority-10 update (HTTP 200) also did not render within 25 s.
- **Suspected cause: activities churn across relaunches.** Each probe launch reported an empty activity inventory and started a new activity with a new token. Until the probe keeps one activity across relaunches and the update reaches the current token, L01–L04 and L09 stay pending.

### Other rows

| Rows | Status |
| --- | --- |
| C02 (repeated calls off, then on) | Pending. Run next. |
| L01–L04, L09 | Pending a probe fix; see above. |
| C01, C05 | Pending, low priority. |
| C06 (Focus filter policy) | **Unqualified**: built without the App Group. |
| C03, C04, C07–C11, L05–L08, L10–L16, T01–T06 | Skipped automatically, per the plan: they need adapters, a backend or hardware this probe lacks. |

## Measured rules

1. **Focus off: every call rings.** Each report succeeded in 63–119 ms and showed both the banner and the full-screen call UI (F01–F05). Focus app membership, caller membership and a CN made no difference.
2. **Focus on, with neither the app nor the caller allowed: the call is filtered.**
   - Setup: Allow Calls From is Allowed People Only and repeated calls are off.
   - LCK fails the report with `com.apple.CallKit.error.incomingcall` code 3, about 2.2 s after entry (F09).
   - No banner and no call UI appear.
   - A genuine Communication Notification for the same caller does not change this (F10).
   - This repeats the earlier [push probe](../callkit-simulator-probe/livecommunicationkit/push/README.md#results) result (2.07 s, code 3), now with the allowances controlled.
3. **Allowing the app lets every call from it through.**
   - With the Focus on and the app in the Focus Apps allowlist, the report succeeded and the call rang (banner and full-screen call UI). This held with the caller allowed (F15, 101 ms) and with the caller **not** allowed (F11, 89 ms), even though Allow Calls From was Allowed People Only.
   - So for LCK, app allowance overrides the People and Allow Calls From rules. A user who allows the Phone app in a Focus gets every Phone call ringing.
4. **Allowing only the caller does not let the call through.**
   - With the Focus on, the caller in the People allowlist, Allow Calls From set to Allowed People Only and the app not allowed, the report still failed with code 3 after 2197 ms, and nothing appeared (F13).
   - The caller was the owned contact, matched by E.164 phone number.
   - For LCK, the People allowlist and Allow Calls From did not apply in this setup; only the Apps allowlist did.
5. **Auto-Answer answers an LCK call on a locked phone.** With Auto-Answer Calls on, a cold VoIP push to a locked phone produced a system `JoinConversationAction` after the configured 3 s. No UI was involved.
6. **Report entry is immediate, and the filtered result is slow.**
   - Report entry came 1–9 ms after push receipt, even on a cold launch.
   - The filtered result arrived about 2.2 s after entry, and PushKit completion followed straight away.
   - After a filter, the process was last observed 1 s after the push; the 3 s survival sample never logged.
   - Reported calls kept the process alive for at least 10.6 s.
7. **Unauthorized Focus status reads as "not focused".**
   - With `INFocusStatusCenter` authorization not determined (`0`), `focusStatus.isFocused` read `false` while the test Focus was on (F09, F10).
   - Treat a status that is not authorized as unknown, never as "not focused".

### iOS 27 Settings facts that affect the product

- **New custom Focus defaults.** A new custom Focus starts with Allow Calls From set to **Contacts Only** and Allow Repeated Calls **on**, plus suggested apps and people.
  - Under those defaults, any saved contact may get through a fresh custom Focus. This is not measured for LCK here; the matrix uses Allowed People Only.
- **App picker needs notification permission.** The Focus Apps picker offers only apps that already have notification permission. Phone must request notification permission before users can allow it in a Focus.
- **Allowlist editing.** The very first People setup is a two-step sheet (Next, then Done). Later edits happen on a page that saves live.
- **Live Activity consent.** Live Activities need the inline consent above before a transcript surface can be relied on.

## Typed-outcome mapping

This applies the [proposed `IncomingPresentationResult`](sdk-api.md#typed-incoming-result-and-native-policy) to what the device produced.

| Device outcome | Domain / code | Measured latency | SDK result | Default policy | Evidence |
| --- | --- | --- | --- | --- | --- |
| Report succeeds | – | 63–119 ms | `.reported(conversationID:)` | normal ringing and actions | C00, F01–F05, F11, F15 |
| Filtered by Focus | `com.apple.CallKit.error.incomingcall` / 3 | 2.19–2.21 s | `.filtered(reason: .focus)` | `screenWithAI`, or `decline` per the user's policy | F09, F10, F13 |
| Codes 4–7 | same domain, 4–7 | not produced | `.filtered(reason: .blockList / .restrictedSharing / .protectedCall / .sensitiveParticipants)` | conservative: no AI for code 4; decline or no screening for 5–7 | none yet (C07, C10) |
| Anything else | unknown pair | – | `.failed(IncomingFailure)` | no screening | – |

What this means for the SDK:

- The report waiter must allow well over 2.2 s before treating a filtered report as a timeout.
- The filtered hook must enqueue its outbox record within the about 1 s that the process was observed to survive the push.
- The SDK must keep the domain and code together; the probe trace already records `reason: "focus"` for code 3.

## Next steps

1. In priority order: C02, then F12, F14 and F16. Then fix the probe's activity continuity and rerun the L rows. Use `--keep-setup` and one `restore-all` at the end. The resume steps live in the operator's private run folder.
2. Repeat any row whose outcome differs from its neighbours before turning it into a rule.
3. Re-run C00 with the Mac microphone once it is granted, to qualify audible and haptic silence.
