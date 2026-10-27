# Focus device measurement plan for Claude

Execution handoff for [#124](https://github.com/ziahamza/ios-voip-sdk/issues/124). **Claude operates the iPhone 13; this lane does not use a device.** This is an unexecuted plan, not new evidence. Read [platform findings](README.md) and the [proposed SDK contract](sdk-api.md) first. Use owned test numbers and a sandbox backend; no production calls or real caller transcripts. Implementation/probe adapters described below are future prerequisites, not files shipped by this docs lane.

## Setup and recording contract

Use the iPhone 13 with its current iOS/build recorded, plus Xcode/build/probe commit. Preserve the user's existing settings before changing them. Use a dedicated test Focus in **Allow Notifications From** mode for both Apps and People, with no schedule or cross-device activation. Record Focus sharing, notification authorization/preview/sound settings, locked/unlocked state, network and Low Power Mode. Record the physical Ring/Silent switch, ringer-volume slider, haptics setting and connected audio accessories. For the main matrix, hold these constant in Ring mode with an audible ringer level and enabled haptics, using the phone itself as the observation route. Run the Focus-off positive control below before and after each session. If it fails, audible/haptic-silence conclusions are **unqualified**, even if reports succeed. Set Allow Calls From to **Allowed People Only**, repeated calls off, Time Sensitive off and Emergency Bypass off for the main matrix. Record the exact UI labels if this OS uses different wording.

Use one caller contact with normalized E.164 number and stable `INPerson` / LCK phone-number handle; ensure no duplicate/mismatched contacts. “App included” means the app is explicitly in the Focus Apps allowlist; “person included” means that contact is explicitly in the People allowlist. Do not switch to a Silence list mid-matrix. Control the ordinary Communication Notification independently from the VoIP push: CN-on sends one genuine call-related `INStartCallIntent`-updated notification; CN-off sends none. Keep its interruption level active, with identical notification permissions and no Critical/Time Sensitive capability in the probe. Timestamp its send/delivery separately so its banner/sound cannot be mistaken for call ringing.

For **every call row**, record one compact trace linked from the execution issue:

- Row/run ID, correlation IDs (test `serverCallID`, invitation UUID, local conversation UUID if any), caller handle kind, app/process state, provider (LCK or CallKit), all independent settings above.
- Monotonic timestamps for push receipt, `mustReport`, native report entry/result, PushKit completion, process suspension/termination, native filtered callback, outbox enqueue/send, backend acknowledgment and AI connection/decline. Record native queue/main flag and whether JS was running.
- Full error **domain/code** and a redacted bounded underlying-error chain; system conversation state, action delivery and audio activation. No tokens, credentials or caller content in logs.
- Human-observed system call banner, ordinary notification banner, sound, vibration and screen wake as separate fields; identify which surface caused each. Save only redacted screenshots/video and linked traces, outside the repo.
- Backend final owner/disposition/history and user-visible status. Never infer AI connected from a filtered error, or rendered activity from APNs HTTP 200.

Run each row three times with a fresh invitation ID and caller lifecycle reset, first cold/background and locked, then repeat any differing outcome unlocked/foreground. Avoid accidental repeat-call windows: wait over three minutes or explicitly reset that setting/control caller between unrelated rows. Record skips and prerequisites rather than fabricating results. Reuse the [push evidence](../callkit-simulator-probe/livecommunicationkit/push/README.md#results) as a baseline, not a substitute for these rows. An app-only LCK probe is required; compare CallKit in a **separate** app/process, never by creating another provider in the production SDK (D13).

## Core call matrix: all 16 combinations

“Full trace” below means the recording contract above, including both notification and call observations. **Measurement pass** means a valid, repeatable, attributed sample, even if it disproves a platform hypothesis. **Product pass** additionally requires clean decline/AI handling without a local ringer when filtering occurs, exactly one native callback/backend disposition, and no fake successful conversation. Allowance combinations are intentionally discovery rows: Apple does not publish an LCK precedence table, so do not encode an assumed result as a pass condition.

| ID | Focus | App in allowed Apps | Caller in allowed People | Communication Notification | Record / pass criteria |
| --- | --- | --- | --- | --- | --- |
| F01 | Off | Excluded | Excluded | Off | Full trace; report succeeds, call visibly rings with confirmed audible/haptic alert and can be answered; no CN. This qualifies the alert-observation baseline. |
| F02 | Off | Excluded | Excluded | On | Full trace; baseline call succeeds; attribute any second alert to CN, one call only. |
| F03 | Off | Included | Excluded | Off | Full trace; inactive Focus app selection does not change baseline success. |
| F04 | Off | Included | Excluded | On | Full trace; call succeeds; separate CN observation. |
| F05 | Off | Excluded | Included | Off | Full trace; inactive Focus People selection does not change baseline success. |
| F06 | Off | Excluded | Included | On | Full trace; call succeeds; separate CN observation. |
| F07 | Off | Included | Included | Off | Full trace; baseline call succeeds. |
| F08 | Off | Included | Included | On | Full trace; call succeeds; no duplicate report/AI handoff from CN. |
| F09 | On | Excluded | Excluded | Off | Full trace; expected code 3 / no local ringer; one decline or AI disposition. If it rings, hypothesis fails: inspect allowances, do not force suppression. |
| F10 | On | Excluded | Excluded | On | Full trace; measure whether CN identity changes either surface; filtering must still get one clean disposition. Unexpected breakthrough blocks claiming this combination is silent. |
| F11 | On | Included | Excluded | Off | Full trace; isolate Apps allowance effect on call report/ringer; support only the observed repeatable rule. |
| F12 | On | Included | Excluded | On | Full trace; compare F11 for CN effect; attribute app-allowed notification separately. |
| F13 | On | Excluded | Included | Off | Full trace; isolate People / Allowed People Only effect; verify matched contact, report and ringer. |
| F14 | On | Excluded | Included | On | Full trace; compare F13 for person-aware CN effect; no duplicate calling path. |
| F15 | On | Included | Included | Off | Full trace; test user-authorized breakthrough hypothesis; successful report/ringer qualifies only if repeatable. |
| F16 | On | Included | Included | On | Full trace; compare F15; no duplicate report or manufactured repeat call. |

Qualify LCK first. Replay the matrix with a separate CallKit control app when available; if unavailable, mark all cross-provider conclusions unverified. A successful report alone does not establish audible breakthrough, and a silenced ordinary notification does not establish code 3.

### Contact and repeat follow-up after #146

The [first device pass](results.md) contains one sample per row: LCK F13/F14 and repeat-on C02 were filtered, while app-allowed F11/F12/F15/F16 presented call UI. Audio was not measured. These do not establish CallKit behavior or a general iOS rule. Run the following as **three independent samples per configuration**, and report each outcome even if it contradicts the earlier result. Record provider, raw handle value/type, the contact's exact saved number, settings, CN delivery, report domain/code/timing and the qualified system surface. The probe's CallKit and LCK modes are different app processes with one provider each, under the same test bundle; neither mode is the production SDK.

Use the existing E.164 test contact. For an unknown-caller variant, use a different owned test number absent from Contacts. For Favorites, explicitly add/remove the test contact from Favorites before the relevant variant and verify that state; app and caller allowance stay excluded unless stated. Restore the contact and Focus afterwards. A configuration passes **measurement** only when three attributed samples with confirmed settings and traces are captured; neither a successful report nor a filtered report alone is a prescribed platform outcome.

| Row | Controlled configuration | Record / pass criteria |
| --- | --- | --- |
| CK-F13 | CallKit; Focus on, app excluded, E.164 caller in Allowed People, Calls From Allowed People Only, repeat off, CN off | Three independent reports/surface observations; compare to LCK F13. Use `CK-F13` and a CallKit C00 visual positive control. |
| CK-C02 | CallKit; Focus on, app/person excluded, CN off; repeat switch **off**, then **on** | Three two-call pairs for **each** switch position. Compare both reports and the second call's surface; do not assume a breakthrough. |
| LCK-C02b | Same as CK-C02, but LCK | Three two-call pairs for each switch position; compare to CallKit and the single-sample [C02](results.md#repeated-calls-c02). |
| CK-CONTACTS / LCK-CONTACTS | Each provider; Focus on, app excluded, Calls From **Contacts Only**, repeat off; test saved contact and a distinct unknown number | Three samples **for each** provider/caller variant; record matching contact identity and any UI. |
| CK-EVERYONE / LCK-EVERYONE | Each provider; same controls, Calls From **Everybody/Everyone**; saved and unknown callers | Three samples per provider/caller variant; record the actual Settings label and UI, not merely report success. |
| CK-FAVORITES / LCK-FAVORITES | Each provider; same controls, Calls From **Favorites**; test contact favorited, then not favorited | Three samples per provider/favorite-state variant; record a verified Favorites state before every sample. |
| CK-HANDLE / LCK-HANDLE | Each provider; Focus on, app excluded, test contact in Allowed People, repeat off; same caller as `.phoneNumber` E.164, `.phoneNumber` national digits, then `.generic` | Three samples per provider/format. Record the **raw supplied handle**, kind and CN `INPersonHandle` type/value if CN is on; no normalization inside the probe. Compare E.164 with F13 and include the CN-on/off condition in the record. |

For every repeat pair, send the second call about **69 seconds** after the first (strictly inside three minutes). Before the first call of the next pair or control row, wait **at least 181 seconds after the previous attempted call**, including an APNs attempt with an unknown outcome; use a fresh invitation UUID for every attempt. The probe runner fences repeat pairs against the last recorded attempt; the device operator's separate runner must enforce the same fence. Do not generate synthetic retries to manufacture a breakthrough.

The probe accepts `CK-F13`, `CK-C02`, `LCK-C02b`, or `C01 --provider callkit|lck --calls 'Contacts Only'|'Everyone'|'Favorites'`. Use `--repeated-calls on|off`, `--caller-format e164|national|generic`, and optionally `--caller-value` for an owned unknown number. A successful report is not a confirmed audible ring. For Live Activity rows, record activity and surface IDs before and after relaunch, the **matching current** token registration, and rendered revision/text separately from APNs acceptance; if the same activity is unavailable, stop as unqualified rather than creating a replacement.

**Onboarding/status controls:** request notification permission before guiding the user to the Focus Apps picker: the iOS 27 device pass found that picker lists only apps with notification permission. For C05, request and record Focus-status authorization separately; the same pass observed `isFocused == false` while authorization was not determined and Focus was on. Treat unauthorized/restricted/denied or nil status as **unknown**, not not-focused. Even authorized `false` is app-relative when this app is allowed, per [Apple's sample](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates). Measure the Intents-extension delivery and cold/killed-app cases before using it as a server policy signal.

### Built-in Do Not Disturb and answered-elsewhere follow-up

The [Phone incident](https://github.com/ziahamza/phone-app/issues/885#issuecomment-6429483597) and operator's follow-up describe one full-screen CallKit presentation while built-in Do Not Disturb was on and the ringer was silent; the assistant answered around 22:27:01Z on 26 October, but the UI remained until about 22:27:41Z. Three later runs did not reproduce the full-screen presentation: **one of four** presented, not a measured breakthrough rate. The incident does not establish the exact Focus allowances or audible ringing. Record initial versus AI-requested invitation and do not infer either from the UI.

Run these rows on the **iPhone 13 only**, three independent samples **per row**. Before each sample verify built-in **Do Not Disturb**, app explicitly excluded from Allowed Apps, an owned E.164 caller absent from Contacts and Allowed People, Allowed People Only for calls, repeat off, CN off, and no applicable Emergency Bypass. Record the exact list mode, settings and UI labels, OS/build, app/provider, initial versus AI-requested invitation, app execution state, notification/Focus authorization, ringer and haptics. Space attempts by at least 181 seconds and use a fresh call/invitation ID; run the CallKit Focus-off positive control before and after. Snapshot and restore the user's original built-in DND configuration, previously active Focus, ringer and related settings. A silent-switch observation establishes presentation, not audible ringing.

| Row | Controlled configuration | Record / interpretation |
| --- | --- | --- |
| CK-DND-SILENT | CallKit; built-in DND on; unknown caller; app excluded; ringer silent | Three attributed reports, UI observations and domain/code/timings. Does the one-of-four Phone observation recur under verified settings? Record both filtering and presentation; neither is a predetermined result. |
| CK-DND-RING | Same, ringer on with qualified volume/haptics | Three independent reports and separately attributed visual/audio/haptic observations; compare to silent switch and Focus-off control. |
| CK-DND-END | Same DND/unknown/app-excluded setup; while the system call UI is actually visible, the assistant answers the **same** server call and sends the matched device an authenticated answered-elsewhere event | Three independent attempts. For each visible-call attempt, measure end-to-dismissal; classify filtered/no-UI or missing-signal attempts as **N/A/unqualified**, never as fast dismissal. Fewer than three observed dismissals leaves the latency row unqualified; do not run indefinitely to force presentation. Record server answer commit and signal send/ack, device receipt, native end-report invocation, screen/banner disappearance and observation coverage. Use device monotonic time for receipt-to-report/UI; measure clock offset and uncertainty for server-to-device timing. Record missing, delayed, duplicate and out-of-order events, UUID/call binding, and process/network state. Compare with the [RFC timing target](app-breakthrough.md#answered-elsewhere-and-dismissing-a-ringing-call). |

The current `spikes/focus` runner targets its owned custom Focus and has no backend assistant or remote-end adapter; its local ring timeout is **not** evidence of server-driven dismissal. Use the operator's qualified Phone runner, or add and qualify those adapters before treating these rows as automated. If DND filters every attempt, report that result and use a separately labeled Focus-off visible-call control to qualify the end path; do not alter allowances to manufacture a DND breakthrough.

## Controls and failure paths

| ID | Change from controlled baseline | What to record | Pass / interpretation |
| --- | --- | --- | --- |
| C00 | Focus off, fixed Ring/volume/haptics/accessory settings; legitimate test call, then separate CN test | Observed audible/haptic alerts attributed to call and CN, plus settings before/after session | Known positive alert control succeeds before silence/breakthrough conclusions qualify. Otherwise fix the observation setup and rerun affected rows; report success alone is insufficient. |
| C01 | Focus on, app/person excluded; Allow Calls From: Nobody / Allowed People / Contacts / Everyone, as available | Exact offered values, contact match, full trace per value | Publish observed call behavior per option; no unsupported LCK claims. |
| C02 | Same caller twice, 69 s apart; repeated calls explicitly off, then on; CN off | Both full traces, setting screenshot, interval | Reproduce or revise the earlier negative result. Breakthrough is a user/system rule; no SDK auto-retry behavior. |
| C03 | Silence Notifications From instead of Allow; caller in/out; “Allow Calls From Silenced People” off/on if offered | List mode, toggle, full traces | Document inverse semantics; do not merge these results into the Allow matrix. |
| C04 | Phone number vs email vs generic handle, allowed contact; genuine CN with/without matching contact identifier | Matching inputs, separate CN/call outcomes | Only validated identity shapes qualify People-based behavior; no fake identity to gain allowance. |
| C05 | User-shared Focus status authorized, denied, sharing off, permission revoked, and Focus changed while app suspended | Optional `isFocused`, authorization, sample age, intent deliveries, foreground refresh | Unknown remains unknown; mandatory reporting and actual filtered result work without this permission. No background observer guarantee. |
| C06 | A user-configured `SetFocusFilterIntent` chooses AI policy; extension runs with app absent. The app, widget and filter now have the registered `group.dev.callkitsim.focus` for team `85A9MS6428`; keep their App Group entitlements in the signed build. Use Xcode's signed-in account and `xcodebuild -allowProvisioningUpdates`, without ASC `-authenticationKey*` arguments. | Persisted policy/version and later native read | Policy applies without JS; no claim to disable Focus or read arbitrary Focus names/rules. The earlier build without the App Group remains unqualified. |
| C07 | Block caller in iOS and separately in app/backend; Focus off | Full trace plus backend block decision | Reconfirm known LCK iOS-list limitation; app/backend block never routes caller to AI or take-over. Restore test block/contact afterward. |
| C08 | Code-3 report, JS disabled; duplicate push; cold relaunch before outbox acknowledgment | Handler count, generation, outbox replay, server idempotency | One logical disposition/agent; native hook independent of JS/main responsiveness; no local capture after failed report. |
| C09 | Code-3 report with backend offline / timeout / app suspension | Outbox status, backend fallback, eventual history | No unsupported background-runtime assumption; bounded fallback declines or screens per server policy; UI never falsely says connected. |
| C10 | Synthetic codes 4–7, unknown domain/code, wrapped error | Typed result and backend policy in a simulator/unit fixture | Correct reason/domain, no default AI for block/security cases; these are mapping tests, **not** device reproduction of those policies. |
| C11 | Intelligent Breakthrough & Silencing | Hardware/OS/language/region support | **N/A on iPhone 13.** On a supported second device, replay F09/F10 with setting off/on; record notification/call outcomes separately. No app-controlled urgency guarantee. |

## Live Activity visibility and cadence under Focus

Prerequisites: a signed widget/intent extension, Live Activities enabled, versioned attributes/state schema, native per-activity token registration sink and sandbox ActivityKit APNs producer consuming existing celld captions. Without them, mark these rows blocked on implementation. Do not open background SSE on the phone. Use synthetic redacted text, a recorded server snapshot revision, and a stale-date 30 s beyond each snapshot. The proposed transport schedule is one changed snapshot per five seconds at priority 5; it is not an Apple SLA.

Record for every row: Focus and lock state; activity authorization; frequent-update setting and reported capability; foreground/intent/pre-armed start source; activity/surface/session IDs; token version/registration acknowledgment (**not token**); APNs status/request ID, send time/priority/payload byte count, state revision/timestamp/stale-date; observed rendered revision/time, privacy treatment, screen wake/sound/vibration, and end/dismissal. Only Claude's observation can establish rendering. For latency, report median/p95 and missing revisions rather than assuming every push is delivered.

| ID | Focus | Configuration / action | Pass criteria |
| --- | --- | --- | --- |
| L01 | Off | Foreground start; lock; priority-5 changed snapshots every 5 s for 2 min | Eligible start returns activity; token handoff precedes update; latest snapshots or truthful stale UI; updates cause no alert/sound/wake. Report cadence distribution. |
| L02 | On | Same as L01, app and person excluded | Lock Screen visible when user inspects it if permitted; no alert/sound/wake from updates; report any hidden presentation honestly. |
| L03 | Off | User-arm monitoring activity first; suspend app; backend binds synthetic AI call and updates | Existing per-activity token updates surface/session state without app SSE; no mistaken incoming LCK conversation/audio capture. |
| L04 | On | Same pre-armed flow as L03; locked and cold app | Same silent criteria; distinguish existing activity from new creation. AI continues if presentation fails. |
| L05 | Off | Background, no existing activity; no user action | No arbitrary `Activity.request`; history fallback. Push-to-start is not used in silent mode. |
| L06 | On | Same as L05 | Same fallback, no synthetic notification/alert/ringer to force a surface. This limits automatic silent-start acceptance. |
| L07 | On/off | Explicit Control Center/widget `LiveActivityIntent` start while main app not foreground | Attribute user initiation, auth/lock prerequisites, start result/token handoff; no inferred permission from PushKit. |
| L08 | On/off | Live Activities disabled; frequent updates separately disabled/enabled | Capability updates reach server; no repeated start attempts when disabled; reduce cadence; UI/history never promises a live surface. |
| L09 | On/off | Stop sending for >30 s, then resume; separately disconnect network | Stale presentation says “Updates delayed”; eventual latest state replaces old content without replaying captions; backend AI unaffected. |
| L10 | On/off | Token rotation/relaunch; delayed old token upload; APNs invalid token | New version wins; old token retired; discovery resumes native observation; no token leakage or cross-session update. Use simulation if rotation cannot be induced. |
| L11 | On/off | Bounded staging burst vs five-second baseline; frequent off/on; priorities 5 and 10 in separate controlled runs | Record delivery/throttling with a hard send cap (60 pushes per run). No guaranteed exhaustion or numeric budget inference; priority-10 budget not used for default transcript. Never add alerts to rescue delivery. |
| L12 | On/off | Simulated APNs acceptance without rendering, producer backoff, older snapshot delivered late | UI stale or latest; no falsely fresh transcript; server coalesces/backoffs, timestamps remain increasing. No per-render acknowledgment assumed. |
| L13 | On/off | Non-ASCII/emoji/escaping near byte limit; privacy previews off/on | Body <=4096 UTF-8 bytes, attributes+state <=4 KB; valid decoding/truncation; no private text with previews off. |
| L14 | On/off | End call, user dismisses, logout, consent revoke, monitor expiry | Call-specific surface ends; monitor clears session or ends per policy; server stops updates/revokes binding; no covert renewal beyond eight-hour active lifetime. |
| L15 | On/off | Optional **alerting-mode** push-to-start, only if separately authorized for this test | Include required `aps.alert`; record actual interruption and per-activity-token second handoff. Never count as proof of silent automatic start. Skip for silent-only qualification. |
| L16 | On/off | Dynamic Island compact/minimal/expanded | **N/A on iPhone 13.** Repeat relevant rows on an Island-capable device; no guarantee of persistent expanded transcript. |

A short trial cannot establish an hourly budget. Do not stress a personal phone to exhaustion; simulate budget/unrendered delivery failures, and use a separately approved sustained staging run only if needed. For the release claim “live transcript”, choose a freshness target after these measurements. Until then, always show timestamp/stale state and describe the surface as best-effort; delayed priority-5 delivery is not corrected by unauthorized interruption.

## Take-over and end-to-end acceptance

Use Phone's existing owner-join test flow against the **same LiveKit room/SIP call**. Start with AI confirmed and the incoming report already filtered. Keep Focus on throughout.

| ID | Action | Record / pass criteria |
| --- | --- | --- |
| T01 | Open transcript deep link, then take over | Owner authenticated/unlocked; new **outgoing** LCK `StartConversationAction` and SDK UUID; cancellation-aware handler joins existing room; no Join against rejected incoming UUID and no second SIP dial. |
| T02 | Take over from Live Activity intent | Same route/ownership checks; measure locked-state authentication. No microphone before genuine LCK audio activation; UI pending until server confirms owner media readiness. |
| T03 | Double tap / second device / retry | One server reservation/committed owner; only one AI-to-owner switch; losing device gets truthful state, no duplicate local audio demand. |
| T04 | Deny microphone, fail LCK action/join, cancel, expire grant, reset provider | Local action/media clean up, reservation rolls back; AI retains call unless caller ended; no automatic retry-ringing. |
| T05 | Caller hangs up during take-over; late join success | End wins server-side, pending UI resolves terminal, late media is disconnected, no resurrected call or contradictory history. |
| T06 | Complete call, foreground later | Single server call history links filtering, AI handling and owner participation; captions reconcile from existing SSE/history, state age is truthful, no unexpected Focus setting change. |

Publish a short table with row IDs, build/settings, sample count, actual result, pass/fail/skip, and evidence links on #124 / the executing lane. Unexpected platform behavior is evidence to revise a claim, not an instruction to bypass it. Restore Focus, Ring/Silent, ringer volume/haptics, audio accessories, contacts/block entries and app/privacy settings; end all test calls/activities, revoke sandbox registrations and delete throwaway build/simulator artifacts. Keep secrets and bulk receipts out of git.
