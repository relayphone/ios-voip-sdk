# Phone integration: AI handles a call during Focus

**Device-lock coordination, checked 27 October 2026:** Phone's [iPhone dogfood procedure](https://github.com/ziahamza/phone-app/blob/main/docs/iphone-dogfood-qa.md) describes an orchestrator-assigned device window, and its [Focus ticket](https://github.com/ziahamza/phone-app/blob/main/docs/tickets/focus-mode.md) assigns shared-iPhone execution to the SDK orchestrator. Neither documents a `~/.device-locks` protocol. The [QA pair-pool locks](https://github.com/ziahamza/phone-app/blob/main/docs/qa-pair-pool.md) protect test account/number pairs, not a physical-device lease. A read-only search of Phone's current GitHub code for `.device-locks` and `device-locks` found no matches. Consequently the Focus harness's canonical-UDID directory lock is **cooperative and not verified as recognized by Phone**; the orchestrator must allocate the iPhone 13 window and ensure both runners honor the same convention. Phone retains priority.

Handoff for the Phone App Orchestrator, tracked by [phone-app#885](https://github.com/ziahamza/phone-app/issues/885) and [SDK #124](https://github.com/ziahamza/ios-voip-sdk/issues/124). This is a proposed UI/data contract, not implemented behavior or a new Phone backend schema. Read the [platform limits](README.md), [typed SDK proposal](sdk-api.md), and [Claude's device plan](device-plan.md) before implementation.

Reuse Phone's existing LiveKit SIP numbers ([#458](https://github.com/ziahamza/phone-app/issues/458)), owner-join/take-over UI and flow ([#456](https://github.com/ziahamza/phone-app/issues/456)), and celld captions SSE ([#858](https://github.com/ziahamza/phone-app/issues/858), frame-loss fix). **Take-over joins the existing AI LiveKit room/SIP call through a new outgoing local SDK conversation.** It does not answer the rejected incoming invitation, dial the caller again, or turn Focus off.

## User-visible promise and its boundary

When the system filters a call, the configured policy either declines it or asks the backend AI to handle it. Phone shows “AI is handling this call” only after the backend confirms that the agent joined. The user may open a transcript screen, read both sides of the AI/caller conversation silently, and choose take-over. Focus stays under the user's control. No local microphone, playback, ringer or automatic app opening occurs while AI handles the call.

A silent Live Activity can update an **existing eligible surface**. Apple's push-to-start requires an alert, so a brand-new automatic activity cannot be promised to appear silently after every filtered call. Offer an explicit “Show call status during this Focus session” action that arms a monitoring activity in the foreground or from a user-invoked `LiveActivityIntent`. This pre-armed option is subject to device qualification, dismissal, authorization and ActivityKit's eight-hour active lifetime. With no eligible surface, keep backend handling and transcript/history available in the app; do not send an alert merely to create the surface. A separately authorized alerting mode is outside silent-mode acceptance.

## Screens and states

| Surface / state | Content and controls | Transition / behavior |
| --- | --- | --- |
| Settings: Focus calling | Decline / AI screening policy, explanation of user-managed Focus allowances, optional shared Focus permission | Persist policy/version natively and on backend; actual report filtering remains authoritative. Focus permission is optional, with unknown status preserved. |
| Settings: silent call status | Enable/disable monitoring surface; explicit Lock Screen identity/transcript preview choice, default off; frequent-updates availability | Explain “Updates may be delayed.” If not armed or disabled, offer in-app status/history. Do not repeatedly prompt for denied permissions. |
| Home / call details: routing | “Call silenced; asking AI to handle it” or “Declining call” | Driven by native filtered result plus server acknowledgment. Avoid a ringing screen, Answer button, or false agent-connected status. |
| AI screening: transcript screen | “AI is handling this call”, caller identity per normal app policy, elapsed time, labeled caller and AI turns, last-update age; **Take over**, **End call** | No audio playback or transcript announcements on arrival. User opens this screen through normal navigation or a deep link; no automatic foregrounding. |
| Lock Screen / Live Activity | Default “AI is handling a call”; optional short redacted last turn; **Open transcript** and optional **Take over** | Use only existing eligible activity. Omit update alerts/sounds. Mask previews when privacy policy requires it. Taking over may require unlock/authentication. |
| Dynamic Island | Compact/minimal state indicator; expanded short excerpt/actions if space permits | Supported devices only; iPhone 13 has no Island. Do not promise a persistent expanded transcript. |
| Transcript stale / reconnecting | Retain known turns, visibly mark “Updates delayed” and last successful time; retry when foreground | Does not imply AI disconnected. Hide/disable take-over only when server ownership/liveness cannot be validated; revalidate on action. |
| Take-over pending | “Joining call…”, prevent duplicate taps; permit cancellation if server operation allows it | New outgoing LCK conversation plus existing-room media join. AI retains ownership until server confirms owner media readiness. |
| Owner connected | Existing in-call UI, optional captions; AI marked handed off | Server-confirmed commit, not just LCK fulfillment or JS promise completion. Close/end call-specific activity or clear monitoring session according to preference. |
| Take-over failed | “Couldn't join. AI is still handling the call” **only if server confirms that fact**; retry/open details | Roll back pending ownership and local media. If status unknown, say “Checking call status”; if ended, show ended state. |
| Ended / declined | Final disposition, AI summary/transcript if available, owner participation and history | Server terminal state wins over late captions, joins or pushes. End call-specific activity; clear the call from a user-armed monitor. No celebratory alert under Focus. |

“End call” needs an authenticated backend operation for this active SIP call; ending the transcript surface or a failed local LCK invitation does not hang up that server call. Keep “Hide call status” separate and reversible. Use the existing Phone destructive-action convention for caller disconnection. Plain transcript reading must not implicitly join, reserve take-over, or activate audio.

## Proposed transcript-screen data contract

An adapter maps existing celld/Phone frames into these types. The names below are **new normalized UI types**, not claims about current SSE field names or endpoints. Keep one authoritative server call/session identity and an adapter test fixture from the existing captions feed; do not fork the captions producer or replace #858's loss handling.

```typescript
type Phase = 'routing' | 'screening' | 'takeoverPending' | 'ownerConnected' | 'ended';
type Speaker = 'caller' | 'agent' | 'owner';
type CaptionTurn = {
  id: string;                 // stable across interim/final corrections
  revision: number;           // safe integer, monotonic for this turn
  speaker: Speaker;
  text: string;
  final: boolean;
  startedAt: string;          // server ISO 8601 UTC
  endedAt?: string;
};
type ScreeningSnapshot = {
  schemaVersion: 1;
  sessionID: string;          // opaque stable server call ID, no room credentials
  revision: number;           // safe integer, monotonic whole-session projection
  cursor: string;             // opaque resume cursor supplied by existing adapter
  phase: Phase;
  observedAt: string;         // authoritative server projection time
  caller: { displayName?: string; identityHint?: string };
  incoming: {
    invitationID: string;
    result: 'filtered';
    reason: 'focus';          // other security/block outcomes never auto-screen
    errorDomain: 'com.apple.CallKit.error.incomingcall';
    errorCode: 3;
  };
  owner: 'ai' | 'pending' | 'human' | 'none';
  canTakeOver: boolean;       // revalidated server-side on every action
  turns: CaptionTurn[];       // bounded initial page; older history paginated
  terminal?: {
    reason: 'declined' | 'callerEnded' | 'ownerEnded' | 'agentEnded' | 'failed';
    endedAt: string;
  };
};
type CaptionEnvelope = {
  sessionID: string;
  eventID: string;            // existing frame identity, preserved by adapter
  revision: number;           // session projection revision
  cursor: string;
} & (
  | { kind: 'turnUpsert'; turn: CaptionTurn }
  | { kind: 'snapshot'; snapshot: ScreeningSnapshot }
  | { kind: 'state'; phase: Phase; owner: ScreeningSnapshot['owner'];
      canTakeOver: boolean; terminal?: ScreeningSnapshot['terminal'] }
);
```

State-only events must carry every changed ownership/terminal field; caption text is not a state transition. Render interim text in place using `turn.id`; apply only newer turn revisions, and reconcile with final text rather than appending a second turn. Preserve server ordering and deduplicate `eventID`/cursor replay. A terminal session cannot be resurrected by a late text frame; retained final text can be reconciled into its history. Use a snapshot refresh on unknown schema or a detected sequence gap; an opaque cursor is not an integer to increment. The adapter must provide a gap/replay policy using the actual feed's semantics rather than assuming numeric revision gaps always mean packet loss.

Foreground flow: fetch the authenticated latest snapshot/history page, attach to existing captions SSE with its supported resume cursor, then reconcile any overlap. If this feed does not offer replay, fetch a new snapshot after reconnect before accepting more deltas. Disconnect/stop depending on SSE when the app is suspended; resume with snapshot reconciliation on foreground. Store local arrival time separately from server time for age/clock-skew handling. Screen “live” means a recent confirmed update, not merely an open socket. Never put room access tokens, SIP credentials, ActivityKit tokens or unredacted transcripts in diagnostic events.

## Server-to-Live-Activity projection

The server already owns the captions stream. It derives a compact view from the same session projection and pushes that view directly to ActivityKit. Foreground SSE remains for the full transcript; neither background React Native nor the widget keeps SSE alive. The [SDK token contract](sdk-api.md#server-push-to-update-and-token-handoff) supplies a native, authenticated, durable registration path, independent of JS.

| Contract element | Phone/backend responsibility |
| --- | --- |
| Registration | Receive `{surfaceID, sessionID?, activityID, token, tokenVersion, environment, bundleID, frequentPushesEnabled, previewPolicy}`; verify owner/session/consent; atomically replace rotated tokens and retire the old version. Never log token material. |
| Pre-armed surface | `sessionID: nil` is idle monitoring, not a fake call. Atomically bind the eligible server call to that owner's surface and put session ID in **mutable content-state**, not immutable attributes. Pick one call deterministically; do not mix concurrent captions. |
| State mapping | `routing` stays in-app until AI status is confirmed; project `screening`, `takeoverPending`, `ownerConnected`, `ended`, or idle `monitoring` into the SDK `FocusTranscriptAttributes.ContentState`. Include schema version, monotonic revision, Unix-second `updatedAt`, speaker and permitted excerpt. |
| Privacy | Default excerpt/speaker omitted and generic status only. Preview opt-in belongs to the owner/surface, not the caller or agent; do not infer consent from notification permission. Use server redaction and compatible widget privacy treatment. |
| Schedule | Initial proposal: coalesce changed snapshots to at most one per five seconds, priority 5, stale-date +30 s. Send a whole snapshot, not every SSE frame or word. These are product choices to qualify, not Apple freshness guarantees. |
| Transport | Per-activity token, APNs topic `<bundle-id>.push-type.liveactivity`, `apns-push-type: liveactivity`; explicit `apns-priority: 5`; increasing `aps.timestamp`, `event: update`, complete `content-state`, `stale-date`; no `alert`/sound for updates. |
| Size | Enforce APNs body <=4096 UTF-8 JSON bytes and separately static attributes+state <=4 KB; initially cap excerpt at 240 UTF-8 bytes, respect grapheme boundaries, account for escaping/emoji. Full turns stay server-side. |
| Frequent updates | Optional **Info.plist** `NSSupportsLiveActivitiesFrequentUpdates`, not a special entitlement. Honor device capability changes and reduce cadence when disabled. It does not remove budgets. |
| Budget / missing delivery | Priority 10 uses a system-managed hourly budget; never escalate to it or add alerts to defeat throttling. Priority 5 can also arrive late/be lost. APNs acceptance is not a screen acknowledgment. Coalesce/back off; the widget displays “Updates delayed” after stale-date. Keep AI and authoritative captions running. |
| End / hide | Send end with final state/dismissal date for call-specific activity. An armed monitor may instead clear session/excerpt and return to idle within its original lifetime. User dismissal, logout, expired activity or consent removal invalidates the binding; do not silently recreate it. |

Lifecycle and API constraints come from the [README's Apple/SDK audit](README.md#silent-transcript-live-activity). A general notification token, VoIP token and push-to-start token cannot substitute for the per-activity update token. If an optional **alerting** push-to-start mode is ever added, its required start alert and subsequent per-activity-token handoff need separate acceptance; it cannot count as silent-mode success. Missing token/registration/surface means in-app/history fallback.

Because a monitoring surface can outlive one call, keep its ActivityKit projection revision monotonically increasing **across session bindings** and serialize pushes per surface. Session transcript revisions remain per call. Never reset the surface revision or let a delayed previous-call update overwrite the next call. Distinguish `serverCallID`, rejected invitation UUID, ActivityKit `activityID`/`surfaceID`, and the outgoing owner conversation UUID in all adapters.

## Take-over integration with existing owner join

Route the transcript button, deep link and optional `LiveActivityIntent` into the existing #456 join flow. The deep link carries only an opaque session ID; authenticate/unlock and confirm current eligibility before requesting media credentials. Use one request ID for a retry of the same operation.

1. Server verifies the signed-in owner, active SIP call, policy and current ownership; creates an expiring take-over reservation. Repeated request IDs return the same operation; competing devices cannot both commit.
2. SDK `takeOverScreenedCall(sessionID:requestID:)` creates a new **outgoing** `startConversation(to:video:metadata:)`, leading to LCK `StartConversationAction`. Its prepared `ConversationHandler.start` connects to the existing LiveKit room using a short-lived grant. It does not use `JoinConversationAction` on the filtered UUID or create a second SIP leg.
3. Respect SDK action cancellation/deadlines and existing LiveKit audio-session ownership. No capture until genuine LCK activation; no manual `setActive`, second provider, or background audio to keep captions alive. UI remains pending through local setup.
4. Backend commits only on confirmed owner media readiness, then mutes/removes the agent speaker. Commit and cancellation/end races must be atomic; do not stop the AI because the user tapped, LCK fulfilled, or a bridge promise resolved.
5. On failure/cancellation, clean up local outgoing conversation/media, release reservation and retain AI ownership if the call is still alive. If the caller ended, terminal state wins. Retry validates eligibility again. After a successful commit, show existing owner call controls and persist one linked history entry.

The backend contract needs reservation/commit/cancel and an authoritative operation-status read; adapt the existing owner-join endpoints rather than assuming new URL names. “Joining” and “joined” must have the same meaning on web and native. Reading the transcript remains available without taking audio ownership.

## Acceptance and handoff

Use [F01–F16, L01–L16 and T01–T06](device-plan.md) as the implementation qualification matrix. Silent mode passes only when an actually filtered call follows configured decline/AI policy with no local ringer, existing eligible activity updates remain non-alerting, transcript status/privacy/staleness is truthful, and take-over joins the same LiveKit call. **Automatic creation of a new silent activity is not part of that promise.** Settings-authorized breakthrough is a separate tested behavior; an AI urgency label cannot grant it.

Provide Phone's implementing lane one adapter fixture covering interim/final captions, reconnect overlap, late terminal frames, concurrent calls and take-over rollback, plus native/backend token registration fixtures and the current-main build instructions. This docs lane provides the normalized contract only; before any code/adapter handoff, verify it applies and builds on clean current main. Device execution remains with Claude. Track implementation gaps on #885 and SDK work on #124; do not claim these docs merge qualifies device behavior.
