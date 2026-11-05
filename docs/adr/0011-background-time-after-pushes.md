---
status: proposed
---
# Keep background time briefly after a VoIP push completes

## Context
On an iPhone 13 with iOS 27.1, a Focus filtered a VoIP push's call while the app was in the background. The push completed after the system answered its report, about 2.1 seconds after arrival. iOS then suspended the app before `CallNotifier`'s main-actor task processed `previewStarted(.filtered)`. Its incoming call notification appeared 33 seconds late, when the next push woke the app. An app reporting a ring outcome to its servers from `previewStarted` or `presented` can lose the same race: completing PushKit's callback doesn't mean that event observers finished their work.

## Decision
`PushKitSource` begins a UIKit background task synchronously at each VoIP push's arrival, before handing the push to the SDK. It ends after the push completion returns and a two-second settle period passes, at system expiration, or at a ten-second cap from arrival, whichever comes first. Each push owns its task, including when pushes overlap. An internal background-execution protocol and an injected clock make the lifetime logic testable on the host without UIKit.

`CallNotifier` also holds a background task for each notification post and withdrawal until the notification center returns, or the system expires it. This covers notifications made after the push's settle period, such as a missed-call notification much later. Apps doing their own push-triggered work should hold their own background task until that work finishes or expires.

## Considered options
- An engine-level acknowledgement from event observers before completing a push: a large API and new observer coordination for one suspension race.
- A fixed delay before calling PushKit's completion: holds PushKit's callback after reporting has finished, rather than requesting background execution for the work that follows.

## Consequences
- Push completion still returns promptly; the existing reporting watchdog remains independent.
- Background time is bounded and best effort. The settle period gives observers time to start, rather than promising that arbitrary observer work finishes.
- UIKit calls stay behind internal seams. App extensions may build notification content but cannot use the app's background execution.
