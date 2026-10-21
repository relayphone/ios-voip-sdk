# LiveCommunicationKit-first plan (October 21, 2026)

This plan supersedes the platform section of `2026-10-21-claude-v01-review.md`. The runtime and Phone findings in that review still stand.

The evidence is in:

- `../research/callkit-simulator-probe/livecommunicationkit/README.md` (iPhone 13, iOS 27.0);
- `../research/callkit-simulator-probe/maccatalyst/README.md`.

## Hamza's decisions

**Final as of the evening of October 21.**

- **LiveCommunicationKit only.**
  - No CallKit provider backend.
  - The minimum is iOS/iPadOS 17.4.
  - Mac Catalyst waits until Apple fixes the SDK defect (Feedback draft 2). There is no temporary CallKit adapter.
  - Apple Watch is deferred.
- **Propose v2 upstream first.** The preferred outcome is an evolved, LiveCommunicationKit-based API that @mfairley adopts as expo-callkit-telecom v2. If he declines, the same design ships as our own `react-native-voip`. Either way:
  - **The design:** [RFC 0001](https://github.com/ziahamza/expo-callkit-telecom/blob/rfc/v2-conversations-api/rfcs/0001-v2-conversations-api.md), under internal review in fork [PR #10](https://github.com/ziahamza/expo-callkit-telecom/pull/10).
  - **The iOS native core:** the Swift package **`ziahamza/ios-voip-sdk`**, public, with **no license file yet**.
  - **Android:** stays on Core-Telecom, refactored to the same model.
- **Phone** moves from Telnyx to LiveKit, then onto this library.
- **Default calling app** (`com.apple.developer.calling-app`) now. The EU dialer (`com.apple.developer.dialing-app`) comes later.
- **The simulator focuses on the LiveCommunicationKit stack.**
- **Upstream:** propose #9 upstream.

## What the evidence says about LiveCommunicationKit

### What improves

1. **One object instead of three.** `ConversationManager` replaces `CXProvider`, `CXCallController` and the app's own call store.
   - The system maintains conversation state, which is `Observable`.
   - `conversationChanged` reaches every manager.
   - A reported conversation was already present before `reportNewIncomingConversation` returned.
   - The compensating machinery we built for CallKit (#9's reservation store, #3's event journal) shrinks to registering app metadata before reporting.
2. **A Swift-native API:** async/await, `Sendable`/`Codable` value types, typed actions, deadlines the app can set, and every delegate callback on the main thread.
3. **Apple's new features are LiveCommunicationKit-only:** default dialer, telephony, conversation history and translation.
4. **Measured parity on the device** for:
   - start, join, mute (with the system echo), tones, pause/resume (with deactivate/activate), end, remote end;
   - one-provider-per-process routing.

### What does not change

- **The same `callservicesd`.** LiveCommunicationKit uses an in-process `CXProvider`, so Apple's confirmed stale audio session bug, Focus filtering, user-intent checks and D13 routing all apply.
  - A later `CXProvider` from any SDK takes every action away from the manager.
  - With two managers, the newer one receives every action.
  - The SDK must own the only manager, and must document vendor SDKs that create their own provider as incompatible.
- **The action deadline is 30 s, including for system actions.** CallKit gives answer 60 s and start 600 s. Fulfill a join when signaling accepts it, not when media connects.
- **No call direction or system-wide view.** `CXCallObserver` provides both and coexists, because it isn't a provider.
- **In the simulator, genuine LiveCommunicationKit is torn down** about 100 ms after the report, just like CallKit. Under the runtime it works, including join and `didActivate` (`runtime-spike/runs/sim-runtime-lck.log`). The runtime keeps interposing at the `CXProvider` level, so LiveCommunicationKit's own client-side logic runs for real.

## Why the top-level API changes, so v2 is a major version

Upstream's JS API (`src/Calls.ts`, `src/Calls.types.ts`) is CallKit- and WebRTC-shaped:

- **One active call:** `getActiveCallSession` plus session added/updated/removed events.
- **CallKit's fulfill step in JS:** the answer listener must call `fulfillIncomingCallConnected(requestId)` or `failIncomingCallConnected`.
- **Two sets of events:** per-action listeners (mute, held, DTMF, ended) next to `report*` calls.
- **Audio session plumbing in JS:** `setRTCAudioSessionConfiguration`, `prepareAudioSessionForCall`, `restoreAudioSession`.
- **Its own states:** requesting, connecting, ringing, connected, ended.

A LiveCommunicationKit-first API replaces each of these:

| Upstream | LiveCommunicationKit-first |
| --- | --- |
| One active session plus three session events | `conversations`: the system-maintained list with LiveCommunicationKit states (`idle`, `joining`, `joined`, `paused`, `leaving`, `left`), multi-conversation from day one, read as a snapshot (`useConversations()`) |
| `requestId` fulfill or fail, plus per-action listeners | One transport handler, for example `onJoin(conversation, { deadline })`. Resolving the promise fulfills the action; rejecting it fails the action. Deadlines come from `ConversationAction.timeoutDate`. |
| Audio session calls in JS | Native media adapters, starting with LiveKit, driven by `didActivate` and `didDeactivate`. JS never touches `AVAudioSession`. |
| Separate `report*` calls | `report(conversationId, event)`, mirroring `Conversation.Event` |
| None | Dial requests from the default calling app (`tel:` links, `INStartCallIntent`), and later the dialer, history and translation |

## The native core: `ios-voip-sdk` (Swift 6 package)
Start with fresh history. Add no license until Hamza decides. Credit upstream's MIT code where it is reused.

| Part | Contents |
| --- | --- |
| Core (no Expo, React Native, WebRTC or backend) | `ConversationClient` owns **the only** `ConversationManager` in the process. It holds a projection of `manager.conversations` plus app metadata keyed by UUID; metadata is registered synchronously before reporting, which is #9's invariant, built in. Typed async commands: `start`, `join`, `end`, `mute`, `pause`, `tones`, `merge`. System actions are delivered to an app handler with the action's deadline. It also publishes an `Observable` snapshot plus an `AsyncSequence` of events. |
| PushKit | A prefixed Objective-C shim target for the iOS 26.4 metadata selector. Policy: required pushes always report, and valid invitations always report. Malformed optional pushes are skipped. |
| Audio | `didActivate`/`didDeactivate` drive a `MediaAdapter` protocol, with a bounded, observable activation watchdog (fork #2's design). |
| Default calling | Routing for `tel:` links, `INStartCallIntent` and `NSUserActivity`, plus entitlement guidance. The default dialer is a separate module (`TelephonyConversationManager`, EU), built later. |
| Diagnostics | A debug-only guard that warns when another `CXProvider` or `ConversationManager` is created in the process, because that silently disables ours (D13). |
| `MediaAdapters/LiveKit` | First-class, since Phone is moving to LiveKit. No Telnyx adapter. |
| `CXCallObserver` | Used read-only, for call direction and the system-wide view. It is not a provider. |
| React Native/Expo library | expo-callkit-telecom v2 per RFC 0001, or `react-native-voip` if upstream declines. iOS binds `ios-voip-sdk`. Android ports upstream's Core-Telecom code onto the same conversation model (`CallControlScope`: answer/disconnect/setActive/setInactive map to join/end/resume/pause). The config plugin covers `voip`, push, `calling-app`, and `dialing-app` (opt-in). |

**Simulator:** keep interposing at the `CXProvider` level. LiveCommunicationKit's client-side logic (30 s deadlines, its state machine, broadcasts to every manager) then runs for real in the simulator. Add the four LiveCommunicationKit device traces as conformance cases, and run the probe's `PROBE_MODE=lck` under the runtime in CI.

## What changes in the queued step 1

**Keep:**

- runtime R1, R2, R4 and R9, plus the new LiveCommunicationKit conformance:
  - the four device traces;
  - the probe's `PROBE_MODE=lck` under the runtime in CI.

  LiveCommunicationKit flows become the runtime's acceptance target.
- Phone P1 and P2.
- Fork #9: fix E4–E6 minimally, then propose it upstream.

**Close as superseded,** linking to this plan: fork #2, #3, #5, #6, #7 and #8. Park #1 and #4, so #1's PushKit delta can go upstream after upstream #29 lands.

**Skip** Phone P3: it is Telnyx-specific, and Telnyx is going away.

**Add:** review and de-risk RFC 0001, which already covers:

- the Swift and JS API sketch;
- the handler and deadline model;
- the state projection and metadata registration;
- single-manager enforcement;
- the PushKit policy;
- the LiveKit media adapter;
- default calling;
- the Android mapping;
- the simulator conformance plan;
- Phone's migration path.

Prototype only what de-risks the RFC (see the Codex brief). Create `ziahamza/ios-voip-sdk` public, without a license. Post nothing upstream until Hamza approves.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
