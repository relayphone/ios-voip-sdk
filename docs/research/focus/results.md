# Focus device results: first iPhone 13 pass

These are the measured results for the [device plan](device-plan.md) from [#124](https://github.com/relayphone/ios-voip-sdk/issues/124). They were run on 26–27 October 2026 with the [`spikes/focus`](../../../spikes/focus/README.md) probe. The probe uses only LiveCommunicationKit (LCK); CallKit was not tested. Two sessions were cut short to return the shared phone. All 16 F rows except F06–F08 are now measured, along with C02 and the locked Auto-Answer run. The Live Activity rows are still open.

The rows were automated: XCUITest changed the settings and observed the screen, and pushes went through the sandbox. There is **one sample per row**; the plan asks for three. Traces, receipts and tokens stay in a private working folder and are not committed.

## Setup

| Item | Value |
| --- | --- |
| Device | iPhone 13, iOS 27.0 (24A5355q), unlocked, an XCUITest session observing. |
| Build | Xcode 27.1 (27A9275); probe from `main` with the harness fixes from #143 and #146. Signed with a development certificate. |
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
| F12 | **On** | Yes | No | On | **reported, 114 ms** | 2 ms | **banner and full-screen call UI**; CN scheduled |
| F13 | **On** | No | Yes | Off | **filtered**: code 3, after 2197 ms | 2 ms | none |
| F14 | **On** | No | Yes | On | **filtered**: code 3, after 2205 ms | 4 ms | none; CN scheduled |
| F15 | **On** | Yes | Yes | Off | **reported, 101 ms** | 4 ms | **banner and full-screen call UI** |
| F16 | **On** | Yes | Yes | On | **reported, 100 ms** | 1 ms | **banner and full-screen call UI**; CN scheduled |

Every unanswered reported call ended itself after the probe's 25 s ring timeout. The CN's own banner was not observed separately in any CN row. After F13, the step that turns the Focus back off failed once because Contacts reopened in an unexpected state; the Focus was turned off a few minutes later and the harness now relaunches Contacts once to recover.

### Repeated calls (C02)

Both runs: Focus on, app and caller not allowed, CN off. The same caller called twice, 69.4 s apart.

| Allow Repeated Calls | First call | Second call | Call surface |
| --- | --- | --- | --- |
| Off | filtered, code 3, 2205 ms | filtered, code 3, 2140 ms | none |
| **On** | filtered, code 3, 2177 ms | **filtered**, code 3, 2140 ms | none |

### Locked answer with Auto-Answer

| Run | Setup | Report | Answer |
| --- | --- | --- | --- |
| F01, locked | Focus off; Auto-Answer Calls on with a 3 s delay; phone locked with the lock button, then 45 s with no UI session; cold push | reported, 120 ms (entry 2 ms) | **`JoinConversationAction` arrived 3.4 s after the push** while the phone was locked; the conversation joined. The probe ended it after 23 s. |

Auto-Lock could not be changed under XCUITest. Selecting 30 seconds showed a checkmark, then read back as the previous value (Never). The run locked the phone with the lock button instead, so Auto-Lock played no part.

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
   - With the Focus on and the app in the Focus Apps allowlist, the report succeeded and the call rang (banner and full-screen call UI). This held with the caller allowed (F15, 101 ms; F16 with a CN, 100 ms) and with the caller **not** allowed (F11, 89 ms; F12 with a CN, 114 ms), even though Allow Calls From was Allowed People Only.
   - So for LCK, app allowance overrides the People and Allow Calls From rules. A user who allows the Phone app in a Focus gets every Phone call ringing.
4. **Allowing only the caller does not let the call through.**
   - With the Focus on, the caller in the People allowlist, Allow Calls From set to Allowed People Only and the app not allowed, the report still failed with code 3 after 2197 ms, and nothing appeared (F13).
   - Adding a genuine person-aware CN for that allowed caller did not change it (F14, 2205 ms).
   - The caller was the owned contact, matched by E.164 phone number.
   - For LCK, the People allowlist and Allow Calls From did not apply in this setup; only the Apps allowlist did.
5. **Allow Repeated Calls does not let a second LCK call through.** With the setting on, a second call from the same caller 69 s later was still filtered with code 3 (C02). This repeats the earlier negative result with the setting explicitly controlled.
6. **Auto-Answer answers an LCK call on a locked phone.** With Auto-Answer Calls on, a cold VoIP push to a locked phone produced a system `JoinConversationAction` after the configured 3 s. No UI was involved.
7. **Report entry is immediate, and the filtered result is slow.**
   - Report entry came 1–9 ms after push receipt, even on a cold launch.
   - The filtered result arrived about 2.2 s after entry, and PushKit completion followed straight away.
   - After a filter, the process was last observed 1 s after the push; the 3 s survival sample never logged.
   - Reported calls kept the process alive for at least 10.6 s.
8. **Unauthorized Focus status reads as "not focused".**
   - With `INFocusStatusCenter` authorization not determined (`0`), `focusStatus.isFocused` read `false` while the test Focus was on (F09, F10).
   - Treat a status that is not authorized as unknown, never as "not focused".

### iOS 27 Settings facts that affect the product

- **New custom Focus defaults.** A new custom Focus starts with Allow Calls From set to **Contacts Only** and Allow Repeated Calls **on**, plus suggested apps and people.
  - Under those defaults, any saved contact may get through a fresh custom Focus. This is not measured for LCK here; the matrix uses Allowed People Only.
- **App picker needs notification permission.** The Focus Apps picker offers only apps that already have notification permission. Phone must request notification permission before users can allow it in a Focus.
- **Allowlist editing.** The very first People setup is a two-step sheet (Next, then Done). Later edits happen on a page that saves live.
- **Live Activity consent.** Live Activities need the inline consent above before a transcript surface can be relied on.

## Second pass: CallKit and the Focus filter (27 Oct, quiet mode)

This was a single-sample pass on the same iPhone 13 (iOS 27). It ran in quiet mode, with the ringer at 0% and no microphone or audio rows, from the automated morning batch (#153, #156). A Mac reboot cut short an earlier attempt, so this pass ran from a persistent folder. Priority rows ran first; everything else was deferred for time.

| Row | Provider | Setup | Report outcome | Visible UI |
| --- | --- | --- | --- | --- |
| C06 | LCK | Focus on, app not allowed, Focus filter policy `screenWithAI` | filtered, code 3, 2214 ms | none |
| C05 | LCK | Focus on, Focus status not authorized | filtered, code 3, 2200 ms | none |
| C00 (positive) | CallKit | Focus off | reported, 1213 ms | banner (unlocked) |
| F09 | CallKit | Focus on, nothing allowed | filtered, code 3, 3223 ms | none |
| F11 | CallKit | Focus on, app allowed, caller not allowed | reported, 1490 ms | banner |
| **F13** | **CallKit** | **Focus on, caller allowed (People), app not allowed, Allowed People Only, repeated calls off** | **reported, 1209 ms** | **banner** |
| F01 + server answer | CallKit | Focus off, local "answered elsewhere" signal while ringing | reported 1393 ms; `answeredElsewhere` end 4 ms after the signal | dismissal not qualified (banner only) |

New rules (one sample each; repeat before relying on them):

1. **The Focus filter is how an app learns that a Focus is on.**
   - With a Focus filter set on the test Focus, the app read `aiPolicy: screenWithAI` from its App Group once the Focus turned on.
   - That held in foreground samples and natively at `push.received`, with no JS, while `INFocusStatusCenter.isFocused` stayed `false`.
   - Before the Focus turned on, the value was `unset`.
   - This is the recommended signal for host-controlled screening (RFC #149).
2. **CallKit honours the People allowlist, and LCK does not.**
   - With only the caller allowed (F13), the CallKit report succeeded and the banner appeared.
   - The same setup on LCK was filtered with code 3 (first pass, F13 and F14).
   - The caller was the owned contact, matched by exact E.164 `.phoneNumber` handle.
   - So exposing the exact caller handle through CallKit lets Focus-allowed people ring.
3. **CallKit app allowance behaves like LCK.** With the app allowed and the caller not (F11), the call rang. With nothing allowed (F09), the call was filtered, with code 3 after about 3.2 s (LCK: about 2.2 s).
4. **Ending a ringing call is fast.** After a local answered-elsewhere signal, the app reported the CallKit end with reason `answeredElsewhere` 4 ms later. A ring that lingers for 20–40 s (Phone's DND incident) is delivery of the signal, not the end-call step.

Unqualified or deferred in this pass:

- **F15 (CallKit, app and caller allowed):** the UI sampler stopped with "Foreground app changed while sampling call surfaces". That's likely the call taking over the screen, but it's unproven.
- **F09 under built-in DND with an unknown caller:** the harness's unknown-caller check matched the owned test contact in Contacts search, a harness bug.
- **C01 (Allow Calls From: Everyone):** iOS 27's picker has no "Everyone" label, a selector bug.
- **Flaky restore step:** after a failed row, `restore-all` missed the Contacts "Edit" control twice. A direct retry passed both times.
- **Deferred for the 2 h budget:** the remaining CallKit matrix samples, repeat calls, Allow Calls From, Favorites, handle formats, DND with answered-elsewhere, and the Live Activity rows (159 rows).
- **Skipped (quiet mode):** the microphone row (C00 `--listen`).

## What this means for Phone

- **Silent AI screening works by default.** While a Focus is on and Phone is not in its allowed apps, every LCK call is filtered with code 3, which the SDK can hand to AI screening. This held even for allowed people, repeated callers and a person-aware CN.
- **Allowing Phone in a Focus lets every call ring.** There is no per-caller middle ground through iOS settings: People and Allow Calls From do not apply to LCK calls here.
  - A "let my important callers ring" feature therefore has to be decided by Phone itself, not by the Focus People list.
  - One option is a server-side VIP list: ask the user to allow Phone in the Focus, then screen everyone else on the backend.
- **Auto-Answer hands an incoming call to the app while the phone stays locked.** The system answered on its own, so a hands-free locked answer can rely on the normal Join path.

## Typed-outcome mapping

This applies the [proposed `IncomingPresentationResult`](sdk-api.md#typed-incoming-result-and-native-policy) to what the device produced.

| Device outcome | Domain / code | Measured latency | SDK result | Default policy | Evidence |
| --- | --- | --- | --- | --- | --- |
| Report succeeds | – | 63–119 ms | `.reported(conversationID:)` | normal ringing and actions | C00, F01–F05, F11, F12, F15, F16 |
| Filtered by Focus | `com.apple.CallKit.error.incomingcall` / 3 | 2.19–2.21 s | `.filtered(reason: .focus)` | `screenWithAI`, or `decline` per the user's policy | F09, F10, F13, F14, C02 |
| Codes 4–7 | same domain, 4–7 | not produced | `.filtered(reason: .blockList / .restrictedSharing / .protectedCall / .sensitiveParticipants)` | conservative: no AI for code 4; decline or no screening for 5–7 | none yet (C07, C10) |
| Anything else | unknown pair | – | `.failed(IncomingFailure)` | no screening | – |

What this means for the SDK:

- The report waiter must allow well over 2.2 s before treating a filtered report as a timeout.
- The filtered hook must enqueue its outbox record within the about 1 s that the process was observed to survive the push.
- The SDK must keep the domain and code together; the probe trace already records `reason: "focus"` for code 3.

## Next steps

1. Fix the probe's activity continuity, then rerun L01–L04 and L09 (the Live Activity under Focus). Use `--keep-setup` and one `restore-all` at the end. The resume steps live in the operator's private run folder.
2. Repeat any row whose outcome differs from its neighbours before turning it into a rule.
3. Re-run C00 with the Mac microphone once it is granted, to qualify audible and haptic silence.
