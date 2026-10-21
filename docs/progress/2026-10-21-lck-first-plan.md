# LiveCommunicationKit-first plan (October 21, 2026)

This plan supersedes the platform section of `2026-10-21-claude-v01-review.md`. The runtime and Phone findings in that review still stand.

The evidence is in:

- `../research/callkit-simulator-probe/livecommunicationkit/README.md` (iPhone 13, iOS 27.0);
- `../research/callkit-simulator-probe/maccatalyst/README.md`.

## Hamza's decisions

- **Mac:** Mac Catalyst only. AppKit can't use CallKit or LiveCommunicationKit.
- **Swift core repo:** `ziahamza/callkit-sdk`.
- **Phone:** moves from Telnyx to LiveKit, then onto `callkit-sdk`.
- **LiveCommunicationKit by default.** Hamza is open to dropping CallKit entirely.
- **Upstream:** propose #9 upstream.
- **Default calling app** (`com.apple.developer.calling-app`) now. The EU dialer (`com.apple.developer.dialing-app`) comes later.
- **Apple Watch:** deferred.

## Recommendation: go all-in on LiveCommunicationKit

### Why it is better

1. **One object instead of three.** `ConversationManager` replaces `CXProvider`, `CXCallController` and the app's own call store.
   - The system maintains conversation state (`idle` → `joined` → `paused` → `left`).
   - That state is `Observable`.
   - `conversationChanged` reaches every manager.
   - On the phone, a reported conversation was already present **before** `reportNewIncomingConversation` returned.
   - Much of what we built to compensate for CallKit becomes unnecessary: #9's reservation store and #3's event journal both exist because CallKit gives the app no authoritative state.
2. **A Swift-native API:** async/await, `Sendable`/`Codable` value types, typed actions, and per-action deadlines the app can set. All delegate callbacks arrived on the main thread.
3. **Apple's new features are LiveCommunicationKit-only:** default dialer, telephony, conversation history and translation (iOS 26). Default calling app works with either framework.
4. **Measured parity on the device** for:
   - start, join, mute (including the system echo), tones, pause/resume with deactivate/activate, end, remote end;
   - one-provider-per-process routing.
5. **Same platform coverage as CallKit:** iOS/iPadOS 17.4+, Mac Catalyst 17.4+ (but see the risks), watchOS 10.4+ and visionOS 1.1+.

### What it does not fix

- **It is not less buggy where it matters.** LiveCommunicationKit uses an in-process `CXProvider`, so the same `callservicesd` applies: the stale audio session bug Apple confirmed, Focus filtering, user-intent checks and D13 routing.
  - A later `CXProvider` from any SDK takes over every action from the manager (`cx-after`).
  - Two managers send every action to the newer one (`two-managers`).
- **No call direction or system-wide view.** `CXCallObserver` still provides both and coexists, because it isn't a provider.
- **Mac Catalyst is blocked.** In the macOS 27 SDK (Xcode 27.1), any `ConversationManagerDelegate` conformance fails to link, because the audio requirements are missing from the Catalyst stub and binary (Feedback draft 2). Genuine CallKit works on Catalyst.
- **Requires iOS 17.4 or later.**
- **The action deadline is 30 s, including for system actions.** CallKit gives answer 60 s and start 600 s. A join must be fulfilled within 30 s, so fulfill when signaling accepts, not when media connects.

### Shape

LiveCommunicationKit is the only provider backend on iOS and iPadOS, and later watchOS.

CallKit survives only in three places:

- `CXCallObserver`, for call direction and the system-wide view;
- Call Directory, if ever needed;
- a **temporary Mac Catalyst backend** behind the same internal interface, deleted once Apple fixes the SDK.

The public API is conversation-shaped, following LiveCommunicationKit's model, not CallKit's.

## `callkit-sdk` architecture

Seed the repo by pushing the fork's full history. That keeps upstream's MIT authorship, t0rs's #29 commits and the Android Core-Telecom code. Then restructure it into a monorepo:

| Part | Contents |
| --- | --- |
| `CallKitSDKCore` (Swift 6; no Expo, React Native, WebRTC or backend) | `ConversationClient` owns **the only** `ConversationManager` in the process. It holds a projection of `manager.conversations` plus app metadata keyed by UUID; metadata is registered synchronously before reporting, which is #9's invariant, built in. Typed async commands: `start`, `join`, `end`, `mute`, `pause`, `tones`, `merge`. System actions are delivered to an app handler with the action's deadline. It also publishes an `Observable` snapshot plus an `AsyncSequence` of events. |
| PushKit | A prefixed Objective-C shim target for the iOS 26.4 metadata selector. Policy: required pushes always report, and valid invitations always report. Malformed optional pushes are skipped. |
| Audio | `didActivate`/`didDeactivate` drive a `MediaAdapter` protocol, with a bounded, observable activation watchdog (fork #2's design). |
| Default calling | Routing for `tel:` links, `INStartCallIntent` and `NSUserActivity`, plus entitlement guidance. The default dialer is a separate module, `CallKitSDKDialer` (`TelephonyConversationManager`, EU), built later. |
| Diagnostics | A debug-only guard that warns when another `CXProvider` or `ConversationManager` is created in the process, because that silently disables ours (D13). |
| `MediaAdapters/LiveKit` | First-class, since Phone is moving to LiveKit. No Telnyx adapter. |
| Catalyst CallKit backend | Temporary; implements the same internal backend protocol. |
| `packages/expo` | A thin Expo/React Native binding. Level-triggered: `useConversations()` snapshot, action handlers and events (review item E3). The config plugin covers `voip`, push, `calling-app`, and `dialing-app` (opt-in). |
| `android/` | Upstream's Core-Telecom code, mapped onto the same conversation model. Core-Telecom's `CallControlScope` and flows map closely to LiveCommunicationKit's model. |

**Simulator:** keep interposing at the `CXProvider` level. LiveCommunicationKit's client-side logic (30 s deadlines, its state machine, broadcasts to every manager) then runs for real in the simulator. Add the four LiveCommunicationKit device traces as conformance cases, and run the probe's `PROBE_MODE=lck` under the runtime in CI.

## What changes in the queued step 1

**Keep:**

- runtime R1, R2, R4 and R9, plus the new LiveCommunicationKit conformance;
- Phone P1 and P2;
- fork #9: fix E4–E6 minimally, then propose it upstream (approved).

**Drop or park:**

- **#3:** close it. The new SDK makes the system's state the source of truth.
- **Fork #1 E8/E10 and #2, #4–#7:** superseded by the `callkit-sdk` RFC. Propose the #1 PushKit delta upstream later, after upstream #29 lands.
- **Phone P3** (cleanup pushes via metadata): fold into the LiveKit migration, unless Telnyx stays in production for more than a few weeks.

**Add:**

- the `callkit-sdk` repo, seeded with the fork's history;
- an RFC covering:
  - the API sketch;
  - the backend protocol;
  - single-manager enforcement;
  - the PushKit policy;
  - the React Native binding shape;
  - the Android mapping;
  - the platform matrix;
  - the migration path for Phone;
- the Expo Mac Catalyst spike (still needed; it uses the CallKit backend on Catalyst).

No code extraction until Claude and Hamza have reviewed the RFC.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
