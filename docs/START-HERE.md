# Start here

This is the current, canonical brief for `ios-voip-sdk`. Where older documents in `docs/progress/` disagree with it, this file wins.

## 1. Goal

Build a VoIP calling SDK for iOS on **LiveCommunicationKit (LCK)** and ship it as two products from the same Swift sources:

1. a **Swift package**;
2. an **iOS-only Expo module** with a React Native/Expo API.

Both include **built-in simulator support**. Genuine CallKit and LCK tear calls down in the iOS simulator, about 100 ms after an incoming report, so this repository's simulator runtime supplies the missing call service. Developers and CI can then test calling on any iOS simulator without a device.

The API is specified in [RFC 0001](https://github.com/ziahamza/expo-callkit-telecom/blob/rfc/v2-conversations-api/rfcs/0001-v2-conversations-api.md), on [fork PR #10](https://github.com/ziahamza/expo-callkit-telecom/pull/10). It is written as a possible **v2 of [expo-callkit-telecom](https://github.com/mfairley/expo-callkit-telecom)**, an MIT Expo module by Michael Fairley that wraps CallKit and Android Core-Telecom. That v2's iOS side would depend on this repository's Expo module, and its Android side would stay in that repository.

**We don't wait for upstream.** This SDK is useful on its own: to native Swift apps, Expo apps, and Phone (Hamza's app, whose calling moves from Telnyx to LiveKit and then onto this SDK).

## 2. Decisions (Hamza, October 21, 2026)

- **LCK only.**
  - No CallKit provider backend.
  - Direction comes from the SDK's incoming/outgoing bookkeeping. Device Release builds must not directly link CallKit (October 22 steering §A0.2); the SDK no longer observes system-wide calls through `CXCallObserver`.
  - The minimum is iOS/iPadOS **17.4**.
- **Mac Catalyst waits for Apple.** It is blocked by an SDK defect (see §5). There is no temporary CallKit adapter.
- **Apple Watch is deferred.** Keep the Swift core compatible with watchOS.
- **A clean v2.** There is **no** v1 compatibility shim; a migration guide replaces it.
- **Default calling app** (`com.apple.developer.calling-app`, iOS 18.2+) is in scope.
- **Default dialer** (`com.apple.developer.dialing-app`, iOS 26+) comes later. Apple only allows testing it from an EU developer account on a device in the EU.
- **Public repository, no license file yet.** Hamza will add one before the beta release. Don't add one yourself.
- **Nothing goes upstream** to expo-callkit-telecom (issues, PRs or comments) without Hamza's explicit approval for that specific action.

## 3. Target architecture

### Swift package (Swift 6; no Expo, React Native, WebRTC or backend dependency)

| Part | Responsibility |
| --- | --- |
| `ConversationClient` | Owns the process's **only** `ConversationManager`. A debug guard warns if any other `CXProvider` or `ConversationManager` appears (see D13 in §5). |
| State | Projects `manager.conversations` and LCK states into a `Conversation` model: id, direction, status, members, capabilities, mute/video, connected and ended info, the payload, and a pending action. App metadata is registered synchronously *before* `reportNewIncomingConversation`. |
| Handler | Delivers system actions (`join`, `start`, `end`, `hold`, `mute`, `tones`) with a cancellation signal and an effective deadline captured once at delivery: the earlier of advertised `ConversationAction.timeoutDate` and delivery plus 5.3 s for hold (Pause)/end or 64 s for join, minus a 1.5 s safety margin once. Other kinds use the advertised deadline minus the margin; no earlier advertised deadline is extended. These conservative caps come from the [iOS 27 multi-call observations](research/callkit-simulator-probe/livecommunicationkit/multicall/README.md), not measurements of every supported OS; the raw advertised deadline remains diagnostic data. A resolved promise fulfills the action; a thrown error fails it. **With no handler**, as on a cold launch, the action stays pending until its effective deadline, then policy applies (`fail` by default). Handler attachment preserves that deadline. Duplicate system echoes that change nothing are filtered. |
| Commands and reports | Commands: `start`, `join`, `end`, `setMuted`, `setHeld`, `playTones`, `merge`. Reports: `connecting`, `connected`, `updated`, `ended(reason)`, and `reportIncoming` for non-push rings. |
| PushKit | An Objective-C shim target for `pushRegistry:didReceiveIncomingVoIPPushWithPayload:metadata:withCompletionHandler:`, compiled only when `<PushKit/PKVoIPPushMetadata.h>` exists; it has no `forType:`. Policy: required pushes and valid invitations always report; malformed pushes with `mustReport == false` are skipped. Wire format: an `incomingCall` envelope with `eventId`, `serverCallId`, `caller` and so on, plus `callEnded`, as expo-callkit-telecom uses today. Duplicates by `eventId` are dropped. Register PushKit during app launch, because a background push launch has no UI scene. |
| Audio | `didActivate`/`didDeactivate` drive a `MediaAdapter` protocol, with `webrtc` (RTCAudioSession) and `livekit` adapters. A bounded activation watchdog emits `audioActivationMissing`, makes one recovery attempt, then emits `audioActivationFailed` and ends the call cleanly; it never fakes an activation. Audio routes come from `AVAudioSession` routes and the speaker override. |
| Default calling | `tel:` links and the start-call intent become `dialRequest`. |
| Simulator support | In `#if targetEnvironment(simulator)` builds, activate the runtime in-process **before** creating the manager. Device builds contain no runtime code. Preferred: a source target that compiles out. Fallback: an XCFramework with an empty device slice. Decide in M0. If activation fails, log the reason and continue with genuine behavior; never crash. |

### iOS-only Expo module

- **Platform:** `expo-module.config.json` lists `apple` only.
- **API:** the RFC's API, including `useConversations()`, `useConversation(id)`, `setConversationHandler`, commands, `reportConversation`, `useAudioRoutes()`, `usePushToken()` and `useConversationEvent`.
- **Build:** the podspec compiles the same Swift sources.
- **Config plugin:**
  - entitlements and the `voip` background mode;
  - push;
  - `defaultCallingApp`;
  - media adapter selection;
  - `unhandledAction`;
  - simulator support.

## 4. Work plan (in order)

> **Current order (Hamza, October 23):** restore every required main CI lane first; remove archived receipt packets and correct the APNs workflow guard; land the §A0 and §A fixes in small PRs; finish M2 and M3; then complete the corrected-source iPhone measurement in [#22](https://github.com/ziahamza/ios-voip-sdk/pull/22), or record its exact blocker.
>
> **CI time-box (Hamza, October 23):** legacy discovery on Xcode 26.3/26.6 is nightly/manual and non-blocking after repeated hosted simulator-startup failures. Failures remain visible in that workflow. SDK M0/M1 acceptance remains required on relevant PRs and main, including changes to either workflow. Do not add further legacy startup repair machinery.
>
> Read [`progress/2026-10-22-claude-steering.md`](progress/2026-10-22-claude-steering.md) for the technical requirements. §A0 covers PushKit report entry and its queue, no CallKit linkage in device builds, and both iOS 27 audio-interruption paths. Apply §A to M2/M3 before merging. §C reserves extension points; it is not a feature list to implement now.
>
> **M-Stable is the stopping point:** main is green on every required lane, all §A0 and §A fixes are merged, M2 and M3 are merged, and #22 is measured on the corrected source or has an exact blocker recorded. Then **STOP**. Write `docs/progress/<date>-codex-m-stable.md`, at most one page: what landed with PR and CI links, what did not, and open risks or questions. Wait for Claude and Hamza's review. Do not start M3.5 or the Expo Modules 2.0 bridge until they reply; the older §B/§D schedule is deferred, not a design reversal.


### A. Fix the runtime from the v0.1 review

[`docs/progress/2026-10-21-claude-v01-review.md`](progress/2026-10-21-claude-v01-review.md) has the details.

- **R1:** the completion of `reportNewIncomingCall` must run on **main** when the delegate queue is nil. Today it runs on `owner.reportQueue` (`Sources/Engine/RuntimeEngine.swift`, around line 450). On the device, all 19 completions arrived on main. Add the event to the main-thread checks.
- **R2:** at install, verify every swapped implementation on the concrete classes (`CXProvider` is a class cluster, `CXXPCProvider`) and set-and-read-back the KVC snapshot keys. Refuse cleanly with a diagnostic instead of `abort()`, crashing, or silently falling through to genuine CallKit.
- **R3:** model teardown callbacks (`providerDidReset`/`didBegin` to older providers) only after measuring them on the device.
- **R5:** the build-identity check compares the hash of the actually loaded image, not just the digest format.
- **R6:** add tampered fixtures for shipping-only branches; add negative controls for semantics, generations and the CLI.
- **R7:** read deadlines and the D5 compositions from the device traces instead of hard-coding them.
- **R8:** say which OS CI covers. CI has iOS 26.5; the profile is iOS 27.0.
- **R9:** package and attest releases in CI, with annotated tags.
- **R4** (the simulator-wide loader) matters less once the SDK activates in-process. Still make test-host-only loading the documented default for apps without the SDK, and add `cksim repair`.

### B. Make LCK the runtime's acceptance target

- Turn the four LCK device traces (`basic`, `cx-after`, `lck-after`, `two-managers`) into conformance cases.
- Run the probe's `PROBE_MODE=lck` under the runtime in CI.
- Use the CallKit traces only for the provider layer that LCK runs on.

### C. SDK milestones

| Milestone | Scope | Done when |
| --- | --- | --- |
| M0 | `Package.swift` plus the Expo module (same sources), an Expo example app, built-in simulator support | The example builds, and an incoming call rings and joins in a plain simulator with no injection, locally and in CI |
| M1 | Single manager plus guard; state projection; handler with deadlines and pending actions; commands and reports; PushKit shim and policy; TypeScript API and hooks | Push → ring → join → connected → hold → end, plus a no-handler cold launch, pass under the runtime |
| M2 | Media adapters (`webrtc`, `livekit`), watchdog, audio routes | The stale-audio fault ends cleanly; LiveKit adapter journeys pass |
| M3 | Default calling app: `tel:` and intent → `dialRequest`; entitlement in the plugin | A `tel:` link opens a dial request in the example |

### D. Device measurements on the test iPhone, with real sandbox APNs

1. Cold launch while locked, answer on the lock screen, and time from answer to `didActivate`.
2. `mustReport` for a push received during an active conversation.
3. Whether an LCK report satisfies PushKit's in-process reporting check on a cold launch.

### E. Later

- Android: measure Core-Telecom's callback suspension and timeouts on the emulator. This is for expo-callkit-telecom v2.

## 5. Evidence: what we know, and where

All of this is under `docs/research/callkit-simulator-probe/` unless noted. The folder keeps its historical name.

| Fact | Where |
| --- | --- |
| **D13, one provider per process:** the newest *created* `CXProvider` gets every `CXCallController` action, including for calls an older provider reported. A provider without a delegate takes over and its actions are lost. Releasing a provider keeps it registered. After the newest is invalidated, requests fail with `unknownCallProvider` after about 10.6 s, with no fallback. A report from an invalidated provider revives it. | `provider-routing/` |
| **D14, mute echoes:** each app mute is followed 10–17 ms later by a system mute action with the same value. Ending a muted call delivers a system unmute after the end, which times out at its deadline. | `provider-routing/` |
| **LCK:** full action parity; system-maintained state (`idle`, `joined`, `paused`, `left`); the conversation exists before the report returns; 30 s action deadlines; all delegate callbacks on main; the same mute echo; and D13 applies. A later `CXProvider` steals all actions from a manager, and the newer of two managers gets every `perform`. | `livecommunicationkit/` |
| **CallKit deadlines and rules:** answer 60 s (expiry measured at 59.58 s), start 600 s, others 5 s; ring timeout 60.1 s. An app answering a waiting call gets `invalidAction`. Hold & Accept is `[SetHeld(active), Answer(waiting)]`, End & Accept is `[End(active), Answer(waiting)]`, Decline is `[End(waiting)]`. | `2026-10-20-iphone13-*.jsonl`, `device-system-ui/` |
| **Simulator:** `callservicesd` tears calls down (reason 55, no call UI host), and `opaqueSessionID` is 0, so `didActivate` never fires. | `2026-10-20-sim-*`, `runtime-spike/` |
| **Real APNs:** `mustReport` is false in the foreground *and* for a running background app; it does not follow `applicationState`. Not reporting when `mustReport` is true kills the app in-process. A cold launch works with early registration. | [device APNs research](research/callkit-simulator-probe/apns-real/README.md), [verification history](verification/README.md) |
| **Mac Catalyst:** CallKit and LCK are unavailable to native macOS apps. Catalyst CallKit works only for a LaunchServices-registered app, needs user intent for outgoing calls, has no mute echo and no audio callbacks. With Xcode 27.1, Catalyst LCK delegate conformances can't link. Re-registering a running app crashed `callservicesd`. | `maccatalyst/` (it also has Feedback Assistant drafts) |
| **Runtime v0.1:** what it covers and how it was qualified | [runtime guide](simulator-runtime.md), [verification history](verification/README.md) |
| **Measured iOS 27 ordinary audio diagnostic, full fixture RED:** raw, C-decoded and Swift-consumed modern notifications agree (2 active, 3 inactive); the silent engine stopped after async activation, before the fourth operation. No A0.3/M2 or LCK-interruption acceptance. | [`audio-session-lifecycle/2026-10-22-iphone13-ios27/`](research/callkit-simulator-probe/audio-session-lifecycle/2026-10-22-iphone13-ios27/README.md) |
| **Measured iOS 27 ordinary no-I/O transport, complete separate fixture PASS:** all four sync/async activation/deactivation operations succeeded; raw, C-decoded and Swift-consumed modern notifications agree (2 active, 4 inactive). Same frozen executable; no engine or rendered frames. Earlier silent-engine fixture remains RED; no A0.3/M2 or LCK/system-interruption acceptance. | [`audio-session-lifecycle/2026-10-22-iphone13-ios27-noio/`](research/callkit-simulator-probe/audio-session-lifecycle/2026-10-22-iphone13-ios27-noio/README.md) |

## 6. Related work outside this repository

- **Fork `ziahamza/expo-callkit-telecom`** (`main` mirrors upstream):
  - **#10:** RFC 0001.
  - **#9:** a fix for the incoming-session publication race, intended for upstream once Hamza approves. Review items E4–E6 still need fixing.
  - **#1 and #4:** parked (PushKit hardening and its CI).
  - **Closed** as superseded by RFC 0001: #2, #3, #5, #6, #7 and #8.
- **Upstream issue** [mfairley/expo-callkit-telecom#47](https://github.com/mfairley/expo-callkit-telecom/issues/47), our original proposal, has no reply yet.
- **Phone (`ziahamza/phone-app`):**
  - [#374](https://github.com/ziahamza/phone-app/pull/374) tests Phone's PushKit path against the v0.1 runtime, using the loader.
  - **Open Phone follow-ups** (P1 fingerprint, P2 Xcode Cloud) belong in that repository.

## 7. Working rules

- **Stop feature work when required main CI is red.** Restore all required CI lanes before opening or advancing feature PRs.
- **Evidence first.** Label claims *measured*, with a CI run or consumed trace, or *proposed*. Device behavior is the reference; record per-OS differences as profile data.
  - Deliver code and tests with CI links and a short result table in the PR description. Keep the description as the source of truth.
  - Do not commit JSON receipts, raw run logs, build inventories or proof packets. Fresh acceptance outputs belong in Actions artifacts or ignored `discovery/out/`.
  - Keep device measurements as test fixtures when automated conformance consumes them. Preserve the existing research until its retention is explicitly reviewed; an archival receipt is not a test fixture.
- **One observable acceptance target per PR.** Use Conventional Commits and aim for no more than about 800 changed non-test lines. Squash-merge PRs and rebase linearly; do not rewrite main.
- **Milestone notes are at most one page.** Include what landed with PR and CI links, what did not, and open risks or questions. Observe the M-Stable stop in §4.
- **Simulators:** create your own throwaway simulators and delete them afterwards. Never use other people's simulators. The Mac's disk has filled up before, so clean DerivedData.
- **Device:** use only the dedicated test iPhone named in Hamza's private notes, and never Hamza's personal devices.
  - The phone may have a Focus active. A repeat report from the same number within seconds gets through.
  - UI automation needs the phone awake and unlocked.
- **Credentials:** sandbox APNs uses a team-scoped key, reached through Hamza's private setup. Never print or commit tokens, keys or JWTs. Raw logs that may contain VoIP tokens stay private.
- **Host Mac:**
  - In zsh, `log` is a shell builtin; use `/usr/bin/log show`.
  - Don't re-register a running app with LaunchServices; it crashed `callservicesd`.
- **No upstream actions and no license file** without Hamza.

## 8. History

`docs/progress/` holds the dated handoffs and reviews that led here. They are kept for provenance and may be out of date:

- **`2026-10-21-codex-implementation-handoff.md`:** the first runtime checkpoint.
- **`2026-10-21-claude-review.md`:** review of that checkpoint, plus provider routing.
- **`2026-10-21-apns-and-review-handoff.md`:** APNs setup.
- **`2026-10-21-claude-v01-review.md`:** v0.1 review; its findings are listed in §4.
- **`2026-10-21-lck-first-plan.md`:** the LCK decision record that this file summarizes.

`docs/research/2026-10-20-*.md` are the original CallKit-era plans. Their calling-library plan is superseded by RFC 0001.
