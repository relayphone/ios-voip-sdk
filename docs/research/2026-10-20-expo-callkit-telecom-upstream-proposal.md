# Upstream proposal for mfairley/expo-callkit-telecom

Posted on October 20, 2026 as [mfairley/expo-callkit-telecom#47](https://github.com/mfairley/expo-callkit-telecom/issues/47) (discussions are disabled upstream).

---

**Title:** Contributing measured iOS CallKit behavior, simulator CI and multi-call support

Hi Michael, thanks for building this. We're building CallKit test tooling and a VoIP app, and we'd like to contribute to `expo-callkit-telecom` rather than start another library.

We recently measured how CallKit and PushKit actually behave on an iPhone 13 (iOS 27.0), in the simulator and on GitHub's macOS runners. A few results line up with open issues here:

- **No call audio (#22, #32).** `callservicesd` can hold a stale audio session ID and never call `didActivate`; Apple DTS confirms this ([thread 837211](https://developer.apple.com/forums/thread/837211)). In the simulator, `opaqueSessionID` is always 0, so `didActivate` never arrives there at all.
- **Hold and unhold (#36).** Holding the only active call triggers `didDeactivate`, and unholding triggers `didActivate` again. The audio engine has to handle repeated cycles within one call.
- **Push handling.** iOS 26.4's `pushRegistry(_:didReceiveIncomingVoIPPushWith:metadata:withCompletionHandler:)` (no `for:` parameter) carries `mustReport`. In our simulator tests with real APNs pushes, the app was killed in-process when it was true and nothing was reported.
- **Call waiting.** The system's Hold & Accept arrives as one transaction (hold the active call, then answer); End & Accept likewise (end, then answer); Decline ends only the waiting call. An app can't answer a waiting call through `CXCallController` (`invalidAction`).

We've also prototyped a CallKit Simulator runtime that makes CallKit work in the iOS simulator, which genuine CallKit doesn't (it tears calls down because there's no call UI host). It could give this repo native iOS CI: build plus end-to-end call journeys on GitHub's macOS runners, without a device.

Proposed contributions, smallest first:

1. Help land #29, the malformed-push fallback that can end the wrong session.
2. Support the iOS 26.4 metadata push method alongside the legacy one.
3. Audio: hold and unhold handling, plus a bounded, observable path when `didActivate` never comes.
4. Queue native events until JS is ready (#46).
5. iOS CI using the simulator runtime.

And three larger changes we'd propose as RFCs first:

- **Multi-call:** call groups, hold, call waiting and system-composed transactions.
- **An Expo-independent Swift core**, published as a Swift package and wrapped by the module, so native Swift apps can use it too.
- **A small media adapter interface** (plain WebRTC and LiveKit first), building on #44.

Would you be open to these? We're glad to follow whatever review cadence and scope you prefer, and to help with maintenance if that's useful. Evidence, traces and probe sources are available to share.
