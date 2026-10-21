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
- **Start fresh.**
  - LiveCommunicationKit changes the *top-level* API substantially (see below), so we build a new library instead of migrating upstream's.
  - Good parts carry over with MIT attribution: the Android Core-Telecom implementation, the PushKit metadata adapter, and the lessons from #9.
- **Native core:** the Swift package **`ziahamza/ios-voip-sdk`**. The React Native/Expo library is built on top of it.
- **Phone** moves from Telnyx to LiveKit, then onto this library.
- **Default calling app** (`com.apple.developer.calling-app`) now. The EU dialer (`com.apple.developer.dialing-app`) comes later.
- **The simulator focuses on the LiveCommunicationKit stack.**
- **Upstream:** propose #9 upstream.

## Why the top-level API changes, so we start fresh

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
Start with fresh history. Credit upstream's MIT code where it is reused.

| Part | Contents |
| --- | --- |
| Core (no Expo, React Native, WebRTC or backend) | `ConversationClient` owns **the only** `ConversationManager` in the process. It holds a projection of `manager.conversations` plus app metadata keyed by UUID; metadata is registered synchronously before reporting, which is #9's invariant, built in. Typed async commands: `start`, `join`, `end`, `mute`, `pause`, `tones`, `merge`. System actions are delivered to an app handler with the action's deadline. It also publishes an `Observable` snapshot plus an `AsyncSequence` of events. |
| PushKit | A prefixed Objective-C shim target for the iOS 26.4 metadata selector. Policy: required pushes always report, and valid invitations always report. Malformed optional pushes are skipped. |
| Audio | `didActivate`/`didDeactivate` drive a `MediaAdapter` protocol, with a bounded, observable activation watchdog (fork #2's design). |
| Default calling | Routing for `tel:` links, `INStartCallIntent` and `NSUserActivity`, plus entitlement guidance. The default dialer is a separate module (`TelephonyConversationManager`, EU), built later. |
| Diagnostics | A debug-only guard that warns when another `CXProvider` or `ConversationManager` is created in the process, because that silently disables ours (D13). |
| `MediaAdapters/LiveKit` | First-class, since Phone is moving to LiveKit. No Telnyx adapter. |
| `CXCallObserver` | Used read-only, for call direction and the system-wide view. It is not a provider. |
| React Native/Expo library (separate) | A new package using the API above. iOS binds `ios-voip-sdk`. Android ports upstream's Core-Telecom code onto the same conversation model (`CallControlScope`: answer/disconnect/setActive/setInactive map to join/end/resume/pause). The config plugin covers `voip`, push, `calling-app`, and `dialing-app` (opt-in). |

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

**Add:** an RFC for `ios-voip-sdk` and the React Native library covering:

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

No code until Claude and Hamza review the RFC. Create the repos only after Hamza confirms names and visibility.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
