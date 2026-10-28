# Calling library plan: CallKit done right, for Swift and React Native (v2)

October 20, 2026. Companion to the [simulator plan](2026-10-20-callkit-simulator-runtime-plan.md). Revised after the user asked "why not fork or contribute back to `expo-callkit-telecom`?" and after an external review. Proposal; no code yet.

## Decision: upstream-first on `expo-callkit-telecom`, fork-ready

v1 recommended a new library that borrowed from `expo-callkit-telecom`. Checking the project's health reverses that:

- **The maintainer accepts outside work.** PRs from five outside contributors have merged, with turnaround from a day to about two months. In [#11](https://github.com/mfairley/expo-callkit-telecom/issues/11) he wrote that he is "open to contributions" and plans no features of his own. We would bring the roadmap; he reviews.
- **He acts on well-argued requests.** After a design discussion in [#21](https://github.com/mfairley/expo-callkit-telecom/issues/21), he made the module independent of any particular WebRTC build ([#44](https://github.com/mfairley/expo-callkit-telecom/pull/44)), which is the property our media add-ons need.
- **Its users already hit our measured rules:**
  - [#22](https://github.com/mfairley/expo-callkit-telecom/issues/22) and [#32](https://github.com/mfairley/expo-callkit-telecom/issues/32): no call audio, consistent with S3;
  - [#36](https://github.com/mfairley/expo-callkit-telecom/issues/36): audio lost after hold and unhold (D3);
  - [#38](https://github.com/mfairley/expo-callkit-telecom/issues/38): second-call ringing, filed for Android (iOS call waiting has no issue yet; multi-call is our proposal);
  - [#46](https://github.com/mfairley/expo-callkit-telecom/issues/46): events lost before JS starts;
  - [#29](https://github.com/mfairley/expo-callkit-telecom/pull/29): an open fix for the same malformed-push bug we found.

  Our evidence turns into fixes its users already want.

- **It has a working foundation:** Android Jetpack Core-Telecom, an Expo config plugin, native push handling, a typed `CallSession` API, a docs site and a release pipeline, with about 42k downloads a month. Rebuilding those would cost months and split an ecosystem that's already small.
- **The simulator gives it what it lacks most:** native CI. Today its workflows only build docs and publish.

The risks are real but manageable:

- There is one maintainer, and merges can be slow; #29 has been open since July 30.
- Our larger changes (multi-call, an Expo-independent Swift core, an add-on interface) might not fit his plans.

So the plan is **upstream-first, fork-ready**:

1. Open a discussion with the maintainer. Share the evidence, propose the roadmap below, and ask how he wants to work: PR review cadence, co-maintainership, or an organization.
2. Land small, evidence-backed fixes for the open issues.
3. Propose the structural changes as RFCs.
4. If an agreed structural change stalls past an agreed window (about six weeks), continue in an MIT fork under our organization. Keep it API-compatible, keep sending compatible fixes upstream, and keep attribution.

This changes two v1 recommendations:

- **React Native module technology becomes the Expo Modules API**, which is upstream's choice; it runs in bare React Native through `install-expo-modules`. An earlier review endorsed a Codegen TurboModule; I'm reversing that because compatibility with upstream matters more than avoiding the `expo-modules-core` dependency.
- **The Swift core** should be an Expo-independent Swift package inside the upstream repository, wrapped by the Expo module. That serves native Swift apps without React Native. If upstream declines, the core lives in our repository and our fork wraps it.

## Upstream contribution roadmap

| Order | Change                                                                            | Upstream link        | Evidence                   |
| ----- | --------------------------------------------------------------------------------- | -------------------- | -------------------------- |
| 1     | Review or land #29; malformed-push fallback ends the call it reported, by UUID    | #29                  | Source audit at `bc335010` |
| 2     | iOS 26.4 metadata push API alongside the legacy method; honor `mustReport`        | new                  | P1, P2, R5                 |
| 3     | Audio: hold, unhold and activation bookkeeping; bounded recovery (below)          | #22, #32, #36        | D3, S3                     |
| 4     | Queue native events (including lock-screen decline) until JS is ready             | #46                  | Cold launch (P5)           |
| 5     | Native iOS CI: build plus simulator end-to-end with the CallKit Simulator runtime | new                  | R1–R8                      |
| 6     | RFC: multi-call (groups, hold, call waiting, system-composed transactions)        | new; #38 for Android | D4, D5                     |
| 7     | RFC: Expo-independent Swift core (SPM) wrapped by the module                      | new                  | Native Swift consumers     |
| 8     | RFC: media adapter interface (WebRTC, LiveKit first) and test audio device        | #21, #44             | R3, S8                     |

## Reuse ledger (pinned)

| Source                                      | Revision                                    | License                                                                                                                                                                                                 | Use                                                                                                       |
| ------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `mfairley/expo-callkit-telecom`             | `bc3350103137`                              | MIT ("Copyright (c) 2026 Michael Fairley")                                                                                                                                                              | Upstream base. As a fork: retain notices, record source paths and revisions                               |
| `react-native-webrtc/react-native-callkeep` | `8a535e594971`                              | ISC                                                                                                                                                                                                     | Report-card subject and migration guide; no code reuse planned                                            |
| `@stream-io/react-native-callingx`          | `stream-video-js@72f1d37495a3` / npm 0.11.5 | **Conflict:** `package.json` says MIT, but the bundled `LICENSE` is Stream's proprietary "Source Code License Agreement" (restricts redistribution and use as a "functional or commercial alternative") | **No reuse** until Stream clarifies. The session-ownership problem it addresses is designed independently |
| `livekit/client-sdk-swift`                  | `acf219dabaf2`                              | Apache-2.0                                                                                                                                                                                              | Reference for the audio contract (`setEngineAvailability`); adapter target                                |
| Cloudflare RealtimeKit                      | binary                                      | Commercial binary                                                                                                                                                                                       | Adapter target after an empirical probe under the simulator runtime                                       |

The report card separates **demonstrated defects** (for example the fallback ending the wrong call, once reproduced) from **scope choices** (single call, an app ring timer, the legacy push API). A legacy delegate is supported API, not non-compliance.

## Native startup and audio sequence

1. **At launch, before any UI**, register `PKPushRegistry` and the native handlers (P7). Do not require the provider here.
2. **Create the provider lazily, as a retained singleton**, on first use, push or outgoing call, and invalidate any old instance. This follows Apple DTS's latest guidance in [thread 837211](https://developer.apple.com/forums/thread/837211); early push registration coexists with a lazy provider. Apps that answer a push with a report do so on the provider created at that moment.
3. **Refresh `CXProvider.configuration` before reporting a new call only when no other call holds valid audio.** Per the [active/held-call guidance](https://developer.apple.com/forums/thread/783870?page=2), refreshing while another call is active can disrupt it. This is the provider's configuration, not WebRTC's `RTCAudioSession` configuration; they are different operations.
4. **Audio ownership is explicit.** The media add-on never activates the session itself. It prepares the engine (for example LiveKit `setEngineAvailability(.none)`, WebRTC `useManualAudio = true`) and starts only inside `didActivate`; it stops in `didDeactivate`. Hold and unhold produce deactivate and activate (D3), so the add-on must handle repeated cycles within one call (#36).
5. **The `didActivate` watchdog is bounded and fallible.** After an answer or start is fulfilled, wait a configurable budget, defaulting well above the measured 290–530 ms; the default is tuned from field data, not one handset.
   - If activation doesn't come, emit `audio.activationMissing` with OS build, timings, provider generation and call count.
   - Make one recovery attempt that the state allows: refresh configuration if this is the only call, otherwise none.
   - If activation still doesn't come within a second budget, emit the terminal `audio.activationFailed`, end the call in order (report ended with `.failed`, fail pending actions, tell the transport to hang up), and recreate the provider before the next call.
   - The library **never fabricates an activation callback** on a device and never marks the call healthy without one.
6. **One genuine report per call.** Production builds report once to CallKit. In the simulator, the runtime's shadow report is the genuine one and app reports are not duplicated (P3, P4).

## Actions, transport and failure semantics

The core owns CallKit; the app's transport, or a media add-on, owns the network. The concrete Apple action objects stay with the core. Adapters that require them (Telnyx `answerFromCallkit`) receive the action through a scoped handle, so the core still knows when it completes.

| Situation                                      | Behavior                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deadlines                                      | Use each action's own `timeoutDate`, minus a configurable app budget and safety margin. The measured 5/60/600 s are the initial iOS 27 profile, not constants. Never fulfill or fail an action after its timeout ([Apple](https://developer.apple.com/documentation/callkit/cxaction/timeoutdate)). |
| Answer                                         | Native-before-JS: the core starts the transport answer through the adapter, or waits for JS within the budget. Success → fulfill. Failure or budget expiry → fail the action **and** cancel the transport answer.                                                                                   |
| Late network success                           | After the action failed or the call ended, a late "answered" from the transport is not a no-op. The core issues a transport hangup and media teardown, and emits `transport.lateAnswerTornDown`. Hangups are idempotent and retried.                                                                |
| Remote cancel during answer                    | Fail the pending answer, report ended `.remoteEnded`, cancel the transport.                                                                                                                                                                                                                         |
| React reload or JS gone with an action pending | Pending native actions keep their native deadline; events are queued and replayed with revisions on reattach (#46). Reload never ends a call implicitly.                                                                                                                                            |
| `providerDidReset` during activation           | Fail and drop pending actions, tear down transports, reset audio ownership, then recreate the provider.                                                                                                                                                                                             |
| Hold & Accept (D5)                             | Handled in order, with **compensation, not atomicity**. Hold succeeds but answer fails: the system ends the waiting call, and the core requests unhold of the original call if that is policy (default on). Hold fails: fail the answer too, so two calls are never active.                         |
| End & Accept (D5)                              | End succeeds but answer fails: the original call is gone and cannot be restored; the core reports the waiting call ended and tells the app. End fails at the transport: complete the end locally anyway (the device times it out at 5.2 s) and reconcile the transport hangup asynchronously.       |
| Ended reasons                                  | A system `CXEndCallAction` has no reason. The core keeps known origins (user, remote, system timeout inferred from 60 s, backend) and otherwise reports `unknown`. Inferences are labeled as inferences.                                                                                            |
| Focus/DND                                      | Return the typed filter result (`filteredByDoNotDisturb`). The repeat-call allowance is a user setting, not a retry strategy.                                                                                                                                                                       |

The partial-failure rows for Hold & Accept and End & Accept still need device measurement of what iOS does with the remaining call. They become conformance scenarios.

## Media add-ons and a tested support matrix

The core imports no add-on; add-ons depend on core contracts. Resolving `RTCAudioSession` at runtime only decouples a small audio shim from one framework import. It does not establish compatibility with every WebRTC binary, its peer-connection API, or an injectable audio device. Each binary gets a tested row, and anything else returns an explicit `unsupported` result:

| Stack                          | Binary                                       | Audio contract                                               | Test audio device                         | Status                                                                 |
| ------------------------------ | -------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------- | ---------------------------------------------------------------------- |
| Google WebRTC                  | `stasel/WebRTC` 154.0.0                      | `RTCAudioSession` manual audio                               | `RTCAudioDevice` if the binary exposes it | One-direction loopback measured in the simulator (R3); two-way pending |
| LiveKit                        | `livekit/client-sdk-swift` at `acf219dabaf2` | `setEngineAvailability`                                      | Through its WebRTC                        | First adapter after plain WebRTC                                       |
| react-native-webrtc            | Its bundled WebRTC                           | `RTCAudioSession`                                            | To be determined                          | Expo journey                                                           |
| Telnyx                         | `TelnyxRTC` 4.2.0 (Phone's pin)              | `enableAudioSession`/`disableAudioSession`, concrete actions | No                                        | Phone adoption                                                         |
| Twilio, Stream, Agora, Fishjam | Pinned when started                          | Per SDK                                                      | Per SDK                                   | By demand                                                              |
| Cloudflare RealtimeKit         | Binary                                       | Unknown                                                      | Unknown                                   | Empirical probe first                                                  |

The first deliverable is **one incoming and one outgoing journey** on plain WebRTC with the reference signaling server, before generalizing to more providers.

## Conformance gate

- **Normalized traces.** Call and action UUIDs become aliases (A, B; A.answer); wall times become offsets; hosts and incidental interleavings are dropped. What is compared: outcomes (results, errors, end states), transaction and action relationships, required partial orders (for example request completion before `perform`, and `perform` before `didActivate`), delegate queues, and timing windows only where apps depend on them (deadlines, ring timeout).
- **Versioned profiles.** Each device profile is keyed by OS, build and configuration (iPhone 13, iOS 27.0, 24A5355q today). Behavior not yet measured on a profile is recorded as unknown. The simulator enforces measured rules for the matching profile and does not generalize one handset to all iOS versions.
- **Measured behavior is profile data, not library policy.** The waiting-call restriction, the 60 s ring, action-property timing and activation timing feed the simulator and conformance profiles. The library handles them defensively without hard-coding them as cross-version truths.
- **Failure propagation.** CI fails when a scenario's trace is missing, empty or incomplete. The current discovery summary script doesn't do this and must change.
- **Real media evidence** is independent captures in **both directions**: tone in at each peer, detected at the other, with leading and trailing silence checks. The current spike proves one stream between two in-process peers; it is not two-way evidence.
- **Independent consumers.** At least one unmodified third-party consumer (callkeep or upstream `expo-callkit-telecom` at a pinned version) runs in the same harness alongside our reference apps.

## Packaging and versions

- **Swift:** one Swift package version across products at first (SwiftPM resolves one revision per package); document tags and compatibility bounds.
- **npm:** packages version-locked to the Swift core they embed.
- **Clean-consumer builds early:** SPM in a fresh Xcode project; packed npm tarballs in bare RN and Expo. These check module names, resources, Swift concurrency flags, and that simulator-only code is excluded from device builds.

## Milestones (revised)

1. **Harness hardening**: fail on missing or empty traces, fix the older-SDK build, normalized trace format. **Minimal control surface** (answer, end, inject faults), moved earlier so every later journey can be driven.
2. **Upstream engagement and small PRs** (roadmap 1–4), each with a simulator reproduction.
3. **Simulator engine** (Swift port of the prototype) with conformance profiles, plus **upstream iOS CI** using it (roadmap 5).
4. **First working journey**: plain WebRTC incoming and outgoing on the Swift core, then through the Expo module, with two-way tone receipts and clean-consumer builds.
5. **RFCs land or the fork decision is made**: multi-call, Swift core extraction, media adapter interface.
6. **LiveKit adapter, then Telnyx (Phone)**; RealtimeKit probe.
7. **Android**: keep upstream's Core-Telecom lane green throughout. Its emulator qualification gate follows the first iOS RN journey and doesn't block the iOS releases.
8. **Report card** for callkeep, `expo-callkit-telecom` (pinned) and others, separating defects from scope, plus simulator UI and test-framework helpers. Then hosted environments and releases.

## Decisions taken (October 20, 2026)

1. **Upstream contact:** posted as [mfairley/expo-callkit-telecom#47](https://github.com/mfairley/expo-callkit-telecom/issues/47).
2. **Fork:** [`relayphone/expo-callkit-telecom`](https://github.com/relayphone/expo-callkit-telecom). Its `main` mirrors upstream; each upstreamable change is a branch off `main`; an `integration` branch brings everything together for our apps.
3. **Simulator:** stays in this separate repository and is consumed by the fork's CI through pinned release artifacts.
4. **Implementation:** through small draft PRs. *Superseded on October 21, 2026: see [`docs/START-HERE.md`](../START-HERE.md).*
