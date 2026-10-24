# Multi-call through LiveCommunicationKit on a real device (iPhone 13, iOS 27.0 24A5355q, October 24, 2026)

**Setup.**

- The probe is `../../lckmulti.swift`. It uses LiveCommunicationKit (LCK) only; **no `CXProvider` is ever created** (D13).
- Each row is a script in `Documents/lck-multi.json`. The probe reports incoming conversations locally while it's frontmost, and runs app-initiated actions.
- Each action kind gets a fulfillment policy: immediate, delayed, failed, left pending, or reversed.
- `MultiCallUITests.swift` operates the **genuine** system UI with no human taps:
  - the SpringBoard banner;
  - InCallService's call-waiting choices;
  - the lock-screen in-call controls.
- `rows.py` defines every row's script and UI steps.
- `run.sh` runs one `xcodebuild test-without-building` per row on the iPhone 13 only, then fetches `<row>.jsonl`. `summarize.py <row>.jsonl` prints a row.
- Every trace row has:
  - `mono_ms` (device uptime) and `wall_ms`;
  - full conversation and action UUIDs;
  - `timeoutDate`;
  - delivery and settle times;
  - `manager.conversations` snapshots;
  - audio callbacks.
- Auto-Lock was Never and Focus off for the session.
- Every LCK delegate callback arrived on main.

## Results

A = first call (answered from the banner); B = second; C/D = later calls. "Same ms" means delivered within 0–3 ms.

| Row | Groups × per group | Result |
| --- | --- | --- |
| `hold-accept` | 2×1 | Hold & Accept delivered `Pause A (isPaused)` and `Join B` in the same ms, while InCallService was in front (app state background). A went `paused` and B `joined` about 120 ms after settling. `didDeactivate` then `didActivate` followed about 200 ms apart. Ending B from the app later **left A paused**: there was no automatic resume. |
| `end-accept` | 2×1 | End & Accept delivered `End A` and `Join B` in the same ms. A left and B joined. |
| `swap-app` | 2×1 | The app resumed A (`Pause A, isPaused: false`) while B was joined. The system then delivered **`End B`**, not `Pause B`: A joined and B left. A later Pause of B failed with `com.apple.CallKit.error.requesttransaction` 4 (unknown UUID). |
| `merge-b-into-a`, `merge-a-into-b` | 2×2 | The system accepted an app Merge in either direction and delivered it to the delegate. Fulfilling it **changed no state**: A stayed `paused` and B `joined`. |
| `unmerge-a`, `unmerge-b` | 2×2 | After a merge, the system accepted and delivered Unmerge. No state changed. |
| `unmerge-singleton` | 2×2 | Unmerging a conversation that was never merged was also accepted and delivered, with no validation. |
| `cap-2x1`, `grouped-hold-accept-move`, `cap-2x2` | 2×1, 2×2 | With A held and B joined (merged or not), a third call offers **End & Accept, Decline and End Held & Accept**, never Hold & Accept. An app merge doesn't free a group. Decline delivers `End C`. An app Merge of A into the still-ringing C was accepted. |
| `third-end-accept` | 2×1 | End & Accept on C delivered `End B` (the active call) and `Join C`. A stayed paused. |
| `third-end-held-accept`, `cap-2x2` | 2×2 | End Held & Accept on C: A was briefly reported `joined` about 10 ms before delivery. Then `Pause B`, `End A` and `Join C` arrived in the same ms: B paused, A left and C joined. |
| `grouped-end-accept` | 2×2 | After the app merged B into A, End & Accept on C ended **only B**. A stayed paused. |
| `cap-1x1`, `cap-1x2` | 1×1, 1×2 | The second call offers only End & Accept and Decline. That holds even with two calls allowed per group. An outgoing Start at capacity fails with `requesttransaction` 7 (maximum call groups) after 11–206 ms. |
| `caps-none`, `caps-toggle` | 2×1 | With **no** capabilities, or with `.pausing` removed mid-call through `conversationUpdated`, the system still offered Hold & Accept and delivered `Pause A`. An app Pause also succeeded. Capabilities don't gate the system's choices or app pauses. |
| `ha-delay-pause` | 2×1 | Pause A was fulfilled 2 s late. A showed `paused` after about 110 ms, before fulfillment. **B joined only after the delayed Pause settled** (+2.04 s), although Join B had settled at +7 ms. |
| `ha-reverse` | 2×1 | Fulfilling Join B before Pause A (both 630 ms late) works: B joined 12 ms after both settled. |
| `ha-fail-pause` | 2×1 | Failing Pause A made the system end A (`left`) and deliver `End A`. B joined. |
| `ha-fail-join` | 2×1 | Failing Join B: B left and the system delivered `End B`. **A stayed paused**, with no resume, until the app ended it. |
| `ha-pending-pause` | 2×1 | Leaving Pause A pending: **`timedOut` at about 5.3 s**, although `timeoutDate` said 30 s. The system ended A (`End A`) and B joined after the timeout. |
| `ha-pending-join` | 2×1 | Leaving Join B pending: **`timedOut` at about 64 s**. B left (`End B`) and A stayed paused. |
| `ea-delay-end` | 2×1 | End A was fulfilled 2 s late, and B joined only after it settled. |
| `ea-fail-end` | 2×1 | Failing End A: A left anyway and B joined. There was no retry. |
| `ea-fail-join` | 2×1 | Failing Join B: A had already ended and B left, so **both calls were lost**. |
| `ea-pending-end` | 2×1 | Leaving End A pending: `timedOut` at about 5.3 s. A left and B joined. |
| `locked-system-ui` | 2×2 | Hold & Accept works from the lock screen, with the same composition. The two-call lock-screen UI shows **Merge** (no Swap), plus Mute, Speaker, Keypad, More, End and FaceTime. Tapping Merge **delivered nothing** to the app, consistent with D12. |
| `filter-block`, `filter-block-check` | 2×1 | A contact for +1 555 555 0199 was blocked. The LCK report from that number **succeeded** (`ok` in 50–57 ms) and the normal incoming banner showed. Left unanswered, the system delivered `End X` after about 60 s. A repeat 66 s later was also `ok`. **The block list didn't produce code 4.** |

**Aggregate timings (28 system composites):**

| Measurement | Value |
| --- | --- |
| Gap between constituent deliveries | 0–3 ms |
| From the last settlement to the accepted call's `joined` | median 115 ms (9–239 ms) |
| From `didDeactivate` to `didActivate` | median 213 ms (151–404 ms when nothing is delayed) |

**Anomaly.** After a failed or timed-out constituent, the system delivers a cleanup End for a conversation that has already left. Fulfilling it immediately still produced `timedOut` about 5.2 s later.

## Consequences

1. **A system composite is one transaction.**
   - All constituents arrive together.
   - The accepted conversation joins only after every constituent settles.
   - The held one's `paused` state appears before its Pause is fulfilled.
2. **The effective deadlines are CallKit's, not `timeoutDate`:** about 5.3 s for Pause and End, and about 64 s for Join. The runtime profile should use these, and the inspector should plot them.
3. **Failure semantics:**
   - a failed Pause ends that call;
   - a failed Join ends the accepted call and leaves the held call paused;
   - a failed End is ignored.
   The SDK must resume (or end) the held call itself.
4. **Which choices the system offers:**
   - Hold & Accept needs `maximumConversationGroups` ≥ 2 and a free group.
   - When both groups are in use, a third call offers End & Accept, End Held & Accept and Decline.
   - `Conversation.Capabilities` gates none of this.
5. **Merge and Unmerge are pass-through.** LCK delivers them without validation or state changes, and it exposes no group membership. Its `debugDescription` is only `uuid`, `state` and `localMember`. The app owns grouping, and the runtime mustn't invent state transitions for them.
6. **Swap is the app's job.** Resuming a held call while another is joined (2×1) made the system **end** the joined call. An SDK swap should pause the active call and resume the held one in one `perform([...])`. That composition isn't measured yet.
7. **Lock-screen behavior:** the lock-screen Merge control doesn't reach the provider, but lock-screen Hold & Accept does.

## Not measured

- **Codes 5–7** (restricted sharing mode, protected calls, sensitive participants). They need broader Settings changes.
- **Group membership and transaction identifiers.** LCK exposes neither. A genuine CallKit probe is needed to observe transaction composition.
- **Composites the app performs itself** (for example, a pause plus a resume in one `perform`).
- **Swap through the system UI.** The unlocked foreground app has no system in-call UI, and the lock screen has no Swap control.

## Block list steps (October 24)

Hamza authorized these steps; nothing else in Settings changed. `MultiCallUITests` did them in Contacts:

1. Tapped **Add**, set the first name to `LCK Block Probe`, added the phone number `+15555550199` and tapped **Done**.
2. Tapped **Block Caller**, then **Block Contact**.
3. Ran the measurements (`filter-block`, then `filter-block-check`).
4. Tapped **Unblock Caller**, then **Edit**, **Delete Contact** and **Delete Contact** again to confirm.
5. Settings → Apps → Phone → Blocked Contacts was read (without changes) and showed an empty list.

Auto-Lock and Focus were Hamza's session settings and were left for him to restore. The probe configs were disarmed with `{}` afterwards, and all conversations were ended.
