# M1 TypeScript bridge

**Status:** the public bridge and M1 native simulator journeys pass
[SDK acceptance](https://github.com/relayphone/ios-voip-sdk/actions/runs/40693437174).
The portable controls cover immutable state, handler settlement/cancellation,
replacement, reentrancy and subscription cleanup. The
[M-Stable checkpoint](../docs/progress/2026-10-28-m-stable.md) separates these
results from remaining media, default-calling and device acceptance work.

The public entry exports state hooks, imperative snapshots, handlers, commands,
reports, push-token and lifecycle-event hooks, and audio routes. The M0 internal
`ios-voip-sdk/internal/bootstrap` entry remains diagnostic infrastructure.
Watchdog and audio-route producers are implemented; `dialRequest` remains reserved
for M3. Genuine activation, deactivation, reset and answered-elsewhere events are
forwarded from the shared native client.

RFC 0001 omits formal definitions for `Participant`, `IncomingCallPayload` and
`PendingAction`. The first two preserve the existing push fields. Pending actions
carry `id`, `kind`, ISO `deadline`, `origin` and the applicable `held`, `muted` or
`digits` argument. Conversation snapshots have no additional metadata field.
Incoming metadata stays in `payload`; outgoing metadata is passed to native.
Snapshot arrays and their nested bridge JSON are frozen copies. Applications
should treat state as read-only and use commands/reports to change it.

Fulfilling `join` or `start` confirms signaling acceptance. Incoming calls remain
`connecting` after the system joins; outgoing calls can remain `dialing` until a
`connecting` report. Neither path publishes `connected` or `connectedAt` until the
backend calls `reportConversation(id, { type: 'connected' })`. System hold and
termination states still take precedence over that transport progress.

`setConversationHandler(null)` removes the handler. Replacing or removing it
aborts the old handler's signals with `handlerReplaced` and ignores its late
promise results. Native retains unexpired actions, may redeliver them to the new
generation, and owns the deadline and unhandled-action policy. `deadline` in both
the pending snapshot and handler context is the effective application deadline.
Native captures the delivery time once, selects the earlier of the advertised
`timeoutDate` and delivery plus 5.3 seconds for hold (Pause) and end, or 64 seconds
for join. It reserves 3 seconds for final audio configuration on start/join,
and 1.5 seconds for other action kinds. Other kinds use the advertised deadline
minus their margin. These conservative application caps
come from the [iOS 27 multi-call observations](../docs/research/callkit-simulator-probe/livecommunicationkit/multicall/README.md);
they do not extend an earlier advertised deadline or claim measured bounds on
every supported OS. The raw advertised deadline remains diagnostic data. Native
applies the policy at the effective deadline, cancels running work, and refuses
an accept if execution resumes after selected expiry. Handler attachment
does not recapture delivery time or subtract the margin again. JS never uses a
timer to extend or fulfill an expired action. Optional hold, mute and tones
callbacks accept when omitted. Handler callbacks may return `void` or a promise,
matching the RFC's synchronous mute example. Native filters system echoes.

On iOS 27, a failed Pause or Join can make the conversation leave before a
system End arrives. That End can deliver the original `ended` snapshot to the
cleanup handler after the conversation has disappeared from public state.
Cleanup does not reinsert it or request another End. Unclaimed cleanup input
uses the existing 120-second metadata window; once End claims it, the normal
action deadline governs handler attachment and completion. Native object
release alone does not cancel cleanup. Reset or a replacement generation
invalidates retained cleanup input; a new terminal observation and genuine End
after reset are fresh platform input.
End identifies a UUID without its native object identity. If several already-ended
generations reuse it with no current object, SDK policy uses the latest accepted
terminal input.
Other held calls remain held: the application chooses whether to resume or end
them. These semantics follow the [measured failure cases](../docs/research/callkit-simulator-probe/livecommunicationkit/multicall/README.md);
the metadata window is SDK policy, not a measured system deadline.

`useConversation(id)` returns `undefined` when the system has no matching live
conversation. `usePushToken()` returns `null` before registration or after token
invalidation. The shared RFC token type includes `fcm`; this iOS module produces
`apns-voip`. `pushTokenUpdated` delivers that same nullable token, without the
private revision envelope. Reports return `Promise<void>` so native failures are
observable. No v1 API is retained.

`useAudioRoutes()` returns immutable `{ routes, current }` snapshots; `current`
is the actual OS output with an `output:<UID>` id, port name and raw port type,
or `null` when no output is observed. `input:<UID>` choices and `speaker` are
selection targets, not a complete output inventory or proof of receiver
availability. `selectAudioRoute(id)` requests an available input or speaker
override while system audio is active; selecting the already-current output id
is a no-op. Published state follows the subsequent OS read, including after a
failed request, rather than assuming that the requested route became current.

## Private native contract

The exact typed contract is `src/internal/protocol.ts`. All listeners attach
before the first snapshot request. Both `getConversations()` and
`conversationsChanged` carry `{ revision, conversations }`; both `getPushToken()`
and `pushTokenUpdated` carry `{ revision, token }`. Each stream has its own
nonnegative, monotonically increasing safe-integer revision. Older and equal
revisions do not replace the cache, so a delayed initial read cannot resurrect a
conversation or an invalidated token. A valid snapshot restores a failed initial
read. Hook initialization failures reach the React error boundary; imperative
read failures reject their promise.

`setHandlerAttached(attached, generation)` and
`settleAction(actionID, generation, success, error?)` are synchronous bridge
methods. Native serializes them with action delivery. `handlerAction` carries
`actionID`, `generation`, `kind`, `conversation`, `deadline`, `origin` and the
applicable action argument. `actionCancelled` carries `actionID`, `generation`
and a reason string. `error`, when present, is `{ name, message }`.

`conversationEvent` carries `{ type, payload }` for non-token public signals;
token events use their separate revisioned stream. The native module must detach
the old handler bridge on destruction, cancel its continuations, and discard
late settlements. Generations are scoped to that module/JS-context lifetime.
Within one JS context the runtime survives Fast Refresh under a global symbol,
so subscriptions, handler generations and pending signals are not duplicated.
Only one active JS context may own the process's native handler bridge.

These API details resolve gaps in the draft RFC and need review with the combined
M1 implementation. They do not claim device qualification, media integration or
default-calling entry-point support.

## Capacity rejection

A system request rejected with `com.apple.CallKit.error.requesttransaction` code 7
becomes Swift `ConversationClientError.atCapacity` and Expo `at_capacity`.
The platform domain/code was measured in the [iPhone 13/iOS 27.0 capacity trace](../docs/research/callkit-simulator-probe/livecommunicationkit/multicall/cap-1x1.jsonl).
Unrelated errors, including incoming-call filtering errors, retain their existing behavior.
Use `isConversationCommandError` to narrow the rejection. The SDK does not infer
available system call groups from its local conversation count.

Incoming callers use the validated [Caller contract](CALLER.md), shared by Swift, pushes and Expo reports.

Hosts can send an explicit [answered-elsewhere ownership signal](ANSWERED-ELSEWHERE.md) to stop a known incoming ring.
