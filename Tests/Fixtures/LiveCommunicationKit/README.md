# LiveCommunicationKit on the iPhone 13 (iOS 27.0), October 21, 2026

These runs use genuine LiveCommunicationKit with no runtime. A probe app ran one launch per scenario. Focus was off on the phone, so no report was filtered.

## API mapping (iOS 27.1 SDK)

| CallKit | LiveCommunicationKit |
| --- | --- |
| `CXProvider`, `CXCallController` and the app's own `CXCallObserver` use | One `ConversationManager`. It is `Observable`, and its `conversations` list is maintained by the system. |
| `reportNewIncomingCall(with:update:completion:)` | `reportNewIncomingConversation(uuid:update:) async throws` |
| `reportOutgoingCall(startedConnectingAt:)`, `reportOutgoingCall(connectedAt:)`, `reportCall(endedAt:reason:)`, `reportCall(with:updated:)` | `reportConversationEvent(.conversationStartedConnecting / .conversationConnected / .conversationEnded(date, reason) / .conversationUpdated(update), for:)` |
| `CXCallController.request(transaction)` | `perform([actions]) async throws` |
| Start, Answer, End, SetHeld, SetMuted, PlayDTMF and SetGroup actions | `StartConversationAction`, `JoinConversationAction`, `EndConversationAction`, `PauseConversationAction`, `MuteConversationAction`, `PlayToneAction`, `Merge`/`UnmergeConversationAction`, and `SetTranslatingAction` (iOS 26) |
| `CXCall` flags: `isOutgoing`, `hasConnected`, `isOnHold`, `hasEnded` | `Conversation.state`: `idle`, `joining`, `joined`, `paused`, `leaving`, `left`. There is no direction flag; `CXCallObserver` still provides one. |
| `CXCallUpdate` booleans: supportsHolding, supportsDTMF, supportsGrouping, hasVideo | `Conversation.Update` with members, active remote members and a `Capabilities` option set |
| Fixed action deadlines (answer 60 s, start 600 s, others 5 s) | `timeoutDate`, settable when the app creates an action; the default is 30 s. System-originated actions observed here also had 30 s. |
| `CXProvider.reportNewIncomingVoIPPushPayload` | `ConversationManager.reportNewIncomingVoIPPushPayload` |
| None | iOS 26 additions: `TelephonyConversationManager` and `StartCellularConversationAction` (default dialer), `ConversationHistoryManager`, and translation |
| `CXCallObserver` for all calls, including other apps and cellular | No equivalent, but `CXCallObserver` still works next to a manager, because it isn't a provider. It saw every conversation here, with its direction. |
| Call Directory extension | No equivalent; it is a separate extension. |

## Measurements

| Scenario | Result |
| --- | --- |
| `basic` | Outgoing start is delivered, `conversationStartedConnecting` and `conversationConnected` move the conversation from `idle` to `joined`, and `didActivate` fires. End gives `left`, then `didDeactivate`. Incoming report: `idle` arrives **before** `reportNewIncomingConversation` returns. Join gives `joined` and `didActivate`. Pause gives `paused` and `didDeactivate`; resume gives `joined` and `didActivate`. A remote `conversationEnded` gives `left`. |
| Mute (in `basic` and `lck-after`) | Same as CallKit (D14): the app's mute is followed **13–14 ms** later by a system `MuteConversationAction` with the same value, and ending a muted conversation delivers a system unmute after the end. That unmute did not time out within 5.5 s; CallKit's timed out at 5.0–5.9 s. |
| `cx-after` (manager, then a `CXProvider`) | **The `CXProvider` receives every action**, including starts, joins and ends the manager requested for its own conversations. The manager still gets `conversationChanged`, but no `perform` and no audio callbacks. It got `didReset` when the provider was invalidated. |
| `lck-after` (a `CXProvider`, then the manager) | The manager receives everything. |
| `two-managers` | **The newer manager receives every `perform`**, including actions requested through the older one. **Both** managers receive `conversationChanged`. |
| Threading | Every delegate callback arrived on the main thread. `perform` and `reportNewIncomingConversation` resume off the main thread. |

LiveCommunicationKit uses an in-process `CXProvider`, and the per-process provider slot governs it exactly as it governs CallKit. An app must own exactly one `ConversationManager`, and any later `CXProvider` from a vendor SDK takes over every action.

## Mac Catalyst

**Blocked by the SDK.** In the macOS 27.0 SDK (Xcode 27.1), the Catalyst Swift interface (`arm64e-apple-ios-macabi.swiftinterface:314-315`) declares the `ConversationManagerDelegate` requirements `conversationManager(_:didActivate:)` and `conversationManager(_:didDeactivate:)`. But the framework's `.tbd` stub and the binary shipped in macOS 27.0.1 export only 12 of the iOS SDK's 16 symbols for that protocol. The method descriptors and dispatch thunks for those two requirements are missing.

Any Mac Catalyst conformance to `ConversationManagerDelegate` therefore fails to link: "Undefined symbols … method descriptor for … didActivate". So a Catalyst app can't receive LiveCommunicationKit actions. Genuine CallKit does work on Catalyst (see `../maccatalyst/`), and it also delivered no audio activation callbacks there.

Traces: `2026-10-21-iphone13-ios27-lck-*.jsonl`.
