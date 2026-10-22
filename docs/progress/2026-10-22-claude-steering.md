# Steering after M0–M1 (Claude, October 22, 2026)

Inputs:

- a code review of `main` at `2e96e47`, open PR #17 (M2) and draft PR #19 (M3);
- research on audio routing, Expo Modules 2.0 versus Turbo Modules, and the web;
- Hamza's product direction (§D).

Claude independently confirmed the two highest-risk findings (A1 and A2) in the code. Section A comes first, before more API surface accumulates on top of it.

**Verdict.** The core is in good shape:

- Swift 6 throughout;
- all state on `@MainActor`;
- no `main.sync`, semaphores or locks held across callbacks;
- the JS settle path is clean;
- pending actions survive a reload;
- push parsing and the `mustReport` policy are correct;
- strict TypeScript without `any`;
- `useSyncExternalStore` with revisions.

## A. Fix before merging more on top (ordered)

1. **Start the PushKit report inside the callback.**
   - **Today:** `PushService.receiveVoIPPush` (`Sources/VoIPSDK/PushService.swift:83-105`) schedules `Task { @MainActor … }` and returns. The LCK report then starts at least two main-queue turns later, behind `SerializedIncomingReports`. On a cold launch it waits behind React Native boot.
   - **Fix:** register metadata and call `reportNewIncomingConversation` directly from the PushKit callback, with one Task and no serializer hop for new UUIDs. Call PushKit's completion when the report settles.
   - **Watchdog:** add a bounded completion watchdog.
   - **Simulator:** make the runtime's push lane enforce PushKit's "must report" rule, so the simulator can fail this path.
   - **Device:** §4.D.1–D.3 (cold launch while locked; does an LCK report satisfy PushKit) must be measured on the iPhone before beta.
2. **Settle before the platform deadline.**
   - **Today:** `ConversationHandler` expires actions *at* `timeoutDate` (`ConversationHandler.swift:97-105, 199-203`), so `unhandledAction: "accept"` races LCK's own timeout.
   - **Fix:** apply the policy at the deadline minus a margin (start with 1.5 s), and expose the effective deadline to JS.
   - **Runtime:** the profile models CallKit's provider deadlines (60/600/5 s) under LCK, but the device shows **30 s** for LCK actions. Add that to the profile, citing the LCK traces.
3. **Echo filter.**
   - **Today:** the filter is skipped while an app mute is pending (`!hasPendingAction(.mute)`), so with a JS handler slower than about 14 ms the system echo reaches JS as a second mute.
   - **Fix:** compare against the *pending* app mute value instead.
   - **Measure:** echo timing with a delayed fulfill. Claude can do this on the iPhone.
4. **Audio: off main, and at call time** (research: `scratchpad/research-audio`, summarized here).
   - **One serial `AudioSessionQueue`** (a dedicated thread, or an actor with a custom serial executor) owns every `AVAudioSession`, `RTCAudioSession` and LiveKit audio call.
     - LCK main-thread callbacks capture minimal state, enqueue the work and return.
     - `setActive` and the session setters block for hundreds of milliseconds.
   - **Never call `setActive`** under LCK; the system owns activation (DTS, forum 846130). Set the category/mode on the queue *just before* fulfilling start/join, as Speakerbox does. Don't set it at launch: today every launch sets `.playAndRecord/.voiceChat`.
   - **WebRTC:**
     - turn on `useManualAudio`/`isAudioEnabled` gating at call start, not at app launch;
     - `lockForConfiguration` isn't reentrant: lock, configure and unlock in one synchronous block on one thread, never across an `await`;
     - set `isAudioEnabled = true` only in `didActivate`.
   - **LiveKit:**
     - `isAutomaticConfigurationEnabled = false`, because otherwise it calls `setActive` itself;
     - `setEngineAvailability(.none)` before the call and `.default` in `didActivate`;
     - its WebRTC audio calls block the calling thread, so keep them off main and out of the cooperative pool.
   - **Route model:** data-driven from what the OS reports.
     - Re-read `currentRoute` on every change, debounce 150–300 ms, then publish an immutable snapshot.
     - Infer "receiver available" from the observed route; there is no output-listing API.
   - **iPhone Duo.** It ships October 23 with iOS 27.1, and Xcode 27.1 has an "iPhone Duo" simulator.
     - Apple documents nothing about routes changing with the fold, so never hard-code by device.
     - `UIHinge`/`UIHingeInteraction` (iOS 27.1, main-actor, view-bound) may be passed in by the host app as an optional hint that triggers a route re-probe.
     - Add an iPhone Duo simulator lane.
   - **Suggested types:**

     ```
     AudioRoute { id, kind: receiver|speaker|wiredHeadset|usb|bluetoothHFP|bluetoothLE|bluetoothA2DP|carAudio|displayAudio|airPlay|mediaExtension|other(raw),
                  name, direction: input|output|duplex, capabilities{hwVoiceProcessing,…}, rawPortType }
     AudioRouteState { output, input, selectableOutputs, selectableInputs, speakerOverride, receiverAvailable, sessionActive, inputMuted, revision }
     events: routeStateChanged(state, reason, initiator), sessionActivated/Deactivated, interrupted/resumed, mediaServicesReset,
             muteChanged(source), routeSelectionFailed(requested, actual)
     commands: selectOutput(id), selectInput(id), setSpeaker(on), presentRoutePicker(), presentInputPicker()
     ```

     This maps cleanly onto Android's `CallEndpoint`.
5. **Acceptance must include system-originated journeys.**
   - **Today:** M1 conformance requires `origin == "app"` for every handler call. The "push" is injected from the example's own native code, and the "cold launch" injects during app init followed by an app-originated join.
   - **Add system-originated cases**, driven through cksim:
     - answer, decline and end;
     - Hold & Accept and End & Accept (D5);
     - mute plus echo, tones, duplicate push, provider reset;
     - a true push-initiated launch.
   - **Device exclusion:** verify it on a **pod-built Release `iphoneos` app**, not a hand-linked probe.
6. **Keep simulator code and test hooks out of device builds.**
   - The runtime resource bundle ships to devices (podspec, `Package.swift:28`), and the `CKSimInjectPush`/`CKSimEmit` test hooks are in the shipped pod's public headers. Make both simulator-only.
7. **One entry point.**
   - **Creation:** two public creation paths exist (`ConversationClient.shared` and `VoIPApplication.start`). Keep one.
   - **Adapters:** media-adapter registration must not depend on order. Make failures loud, not an `NSLog`.
   - **Duplicate linkage:** detect the SwiftPM product and the pod linked together, which creates two managers, and fail loudly.
   - **Foreign providers:** in Release, report as an SDK event (not just a Debug warning) when another `CXProvider` or `ConversationManager` takes over (D13).
8. **Small API fixes.**
   - Carry the JS rejection reason into `settleAction`; it is currently discarded.
   - Type the rejection codes in TypeScript.
   - Send the `conversationId` that event payloads declare.
   - Map `ended` with reason `local` correctly; it currently becomes `.remoteEnded`.
   - Make the incoming and outgoing `connected` semantics consistent: incoming reports `connected` on join, while outgoing waits for `reportConversation(connected)`.
   - Measure and test duplicate-push detection through LCK's error wrapping.
9. **M3 (`tel:`) on the simulator.**
   - **Today:** `LSApplicationWorkspaceErrorDomain` 115 on iOS 27 is expected, because a simulator can't select a default calling app.
   - **Fix:** in the simulator, accept by delivering the URL and the start-call intent/user activity to the app directly. Leave real default-calling dispatch to a device measurement.

## B. Bridge and threading direction (decide now, while the JS surface is small)

1. **Bridge: Expo Modules 2.0, not a Turbo Module.**
   - **Status:** Expo Modules 2.0 is beta on iOS and Android in Expo SDK 58 (stable October 15, 2026; React Native 0.88).
   - **Why:** it is Swift-native: `@ExpoModule`, `@JS`, `@Record`, `@Union`, typed `@Event`, and thread isolation checked by the compiler.
   - **Against Turbo Modules:** they need Objective-C++ glue around Swift (React Native's guide says a Turbo Module "won't be a pure Swift implementation"), and native payloads arrive as untyped dictionaries.
   - **Against a C++ core:** the platform-bound core leaves little to share.
   - **How to adopt it:**
     - keep all logic in the SwiftPM package, with `@ExpoModule` as a thin adapter;
     - keep the 1.0 DSL as a fallback (both can coexist in one module);
     - have the TypeScript layer talk to a small `NativeTransport` interface, so a Turbo Module adapter could be swapped in if 2.0 stalls;
     - require Expo SDK 58 or later.
   - **The threading trap:**
     - in 2.0, async `@JS` members default to `@JavaScriptActor` and stay on the JS thread until the first `await` (1.0's `AsyncFunction` ran off the JS thread);
     - isolate commands explicitly to the SDK's actor, or use `.concurrent`;
     - a JS closure that returns a value blocks the native caller, so use `async` closures for the handler.
   - **Shape:**
     - a sync, O(1) `@JS var snapshot`;
     - `@Event onChange(snapshot, version)`, coalesced natively so it fires only when the version changes;
     - commands as SDK-actor-isolated async functions;
     - the handler as native awaiting an async JS closure under a deadline Task, with a cancel event that becomes the JS `AbortSignal`;
     - immutable records for conversations;
     - `SharedObject`s only for native-lifetime controllers, such as the audio route controller.
   - **Unconfirmed in 2.0, so check first:**
     - `@Event` on `@SharedObject`;
     - whether `ExpoAppDelegateSubscriber` sees PushKit early enough under SDK 58's scene lifecycle.
2. **Threading contract.** Write it down in START-HERE, and enforce it.

   | Thread | What runs there |
   | --- | --- |
   | **main** | LCK delegate callbacks (system-delivered; capture and enqueue only), the PushKit callback (start the report synchronously), UIKit/`UIHinge` |
   | **SDK actor** (currently `@MainActor`) | State and the handler; nothing that blocks or does I/O |
   | **AudioSessionQueue** | Every audio-session, WebRTC and LiveKit audio call |
   | **JS thread** | Expo bindings only |

   **Enforce it:** add a main-thread stall check to the journeys (fail on main-run-loop latency above a threshold, for example 50 ms) and to the iPhone Duo lane.
3. **TypeScript ergonomics.**
   - Hand-written discriminated unions keyed on status, with a branded `ConversationId` and typed error codes.
   - Until Expo's type generation ships, add a CI drift check against the macros' `scan-exports` output.
   - `useConversation(id)` keeps each conversation's object reference stable, so the React Compiler can skip re-renders.
4. **Optional Effect v4 entry point.** Effect 4.0 is stable, with fixes guaranteed to September 2029.
   - **Shape:** `ios-voip-sdk/effect` as a subpath, with `effect` as an optional peer dependency.
   - **Contents:**
     - `changes: Stream<Snapshot>` via `Stream.callback({ bufferSize: 1, strategy: "sliding" })`, which keeps only the latest snapshot;
     - `events: Stream<ConversationEvent>`;
     - commands as `Effect<void, TaggedError>`;
     - the handler as a `Layer`, with the deadline as fiber interruption;
     - opt-in Schema validation.
   - **Core stays dependency-free.**
   - **Hermes:** needs Babel configuration, and a release that includes the `DateTime` fix (#8707).
   - **When:** after M2/M3, but keep the TypeScript core shaped so this is a thin layer.

## C. Product direction to design for now (Hamza)

Reserve the extension points in the API now; implement later. Each item becomes its own optional module, so the core stays small.

1. **Default calling app (international) and default dialer (EU),** replacing the Phone app where Apple allows it, plus **China mainland** distribution, where CallKit/LCK are restricted. Research is in progress; don't implement until it lands.
2. **Focus and Do Not Disturb.**
   - **Typed outcome:** `reportIncomingConversation` returns `reported`, `filtered(reason: doNotDisturb | blockList | …)` or `failed`.
   - **Native hook:** fires even with JS absent, so a backend or AI can take a filtered call.
   - **Breakthrough:** only through legitimate, user-consented mechanisms. Research is in progress; never re-report silently to get past Focus.
3. **Dynamic Island and Live Activities during calls; picture-in-picture for video calls** (`AVPictureInPictureVideoCallViewController`). Research is in progress.
4. **Multi-call, as a first-class feature:**
   - call waiting;
   - system-composed transactions delivered with a transaction id, so Hold & Accept can be handled atomically;
   - merge and unmerge;
   - groups.
5. **Simulator developer experience.** Plan this as M4; design the runtime's event channel now.
   - **What it is:** a "call UI and inspector" in the simulator. It renders an emulated incoming call (banner and full screen) with answer, decline, Hold & Accept and End & Accept.
   - **Inspector:** a live timeline of actions, deadlines, latencies against the device profile, and audio activation.
   - **Prerequisite:** a structured runtime event stream, so the inspector, the CLI and CI read the same events.
6. **Later:**
   - Apple Watch (keep the core watchOS-compatible);
   - Mac Catalyst once Apple fixes LCK linking;
   - Android as a sibling repo, mirroring this one with a native SDK plus React Native;
   - a web subset: foreground and desktop-background softphone, `setSinkId`, Media Session call actions, PiP, Web Push; iOS Safari only as Home Screen push;
   - media providers beyond WebRTC and LiveKit (Cloudflare).

## D. Order

1. Finish M2 (#17) and M3 (#19) **with A1–A9 applied**, as small PRs.
2. **M3.5:**
   - the Expo Modules 2.0 bridge;
   - the threading contract plus the stall check;
   - typed errors;
   - the audio route model;
   - the iPhone Duo lane.
3. **Device pass with Claude** on the iPhone 13 (§4.D plus the echo timing), and on an iPhone Duo if one is available.
4. **M4:** the simulator call UI and inspector.
5. **M5 and beyond:** the C items, in the order the research supports.
