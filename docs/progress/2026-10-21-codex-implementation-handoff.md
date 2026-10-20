# Codex implementation checkpoint for Claude — 2026-10-21

This is an implementation checkpoint, not completion of the runtime or library
roadmap. Codex leads implementation; Claude's most useful next contribution is
reviewing the concrete patches and resolving the targeted reference-device
questions below. No new credentials or physical-device experiments were used in
this batch. Phone app sources were not changed.

## Observable acceptance target

A malformed synthetic VoIP push B must leave an already connected call A alive
with the same UUID. A must still accept a native mute transaction and end cleanly.
The result must come from the actual Expo/native/JS app on a fresh simulator, with
strict provenance, a genuine CallKit baseline, and failure-sensitive evidence.

## Branches and concrete changes

| PR | Implemented in this checkpoint | Remaining scope |
| --- | --- | --- |
| [Simulator #2](https://github.com/ziahamza/callkit-simulator/pull/2) | Executable discovery harness; strict versioned conformance evidence; retained-action and callback checks; process receipts; owned-device cleanup; old/new SDK lanes | Production Swift engine, complete profiles, release artifact and delivery/bootstrap lifecycle |
| [Library #1](https://github.com/ziahamza/expo-callkit-telecom/pull/1) | Original upstream #29 with attribution; typed Objective-C PushKit metadata adapter; conservative typed optional-push policy; real native/JS regression and accessible example controls | Placeholder lifecycle bounds, generation-safe session publication, APNs/device qualification |
| [Library #4](https://github.com/ziahamza/expo-callkit-telecom/pull/4) | Pinned macOS workflow, real Release Expo build/XCTest, frozen installs, private raw test logs and public structured summaries | Resolve exact older-compiler failure; replace discovery checkout with versioned runtime release when available |
| [Library #8](https://github.com/ziahamza/expo-callkit-telecom/pull/8) | Integration update is pending hosted gate resolution | Never merge into the fork's upstream-mirroring main |

Library #4 is stacked on #1 because its native test genuinely depends on #1's
adapter and regression fixture. The other draft workstreams remain open. No new
upstream posts or PRs were made. The original upstream #29 commits by Tor Håkon
Ingerson Moen / t0rs are preserved, rather than presenting that fix as new work.
No CallX or GetStream mock code was imported.

## Measured evidence

### Simulator discovery

- Local Xcode/SDK 27.1, iOS 27.0: source `5515602` passes all three scenarios.
  Genuine CallKit accepts the report, tears down the call and rejects the later
  answer. The injected prototype delivers real actions and observer state,
  including mute, DTMF, hold, group, outgoing, timeout and cleanup.
- Retained-answer timeout: **59.648 seconds**. Late fulfillment is correlated to
  the same action ID; premature completion is rejected by the evidence gate.
- Hosted [39511363331](https://github.com/ziahamza/callkit-simulator/actions/runs/39511363331):
  both Xcode **26.3 / SDK 26.2 / legacy PushKit** and **26.6 / SDK 26.5 / metadata
  PushKit** pass genuine, runtime and push scenarios on macOS 26.6.2 with the
  Xcode 26.6 host and **iOS 26.5 runtime**. Source head `77c4f03`; actual synthetic
  merge checkout `7e7db7f09dd430a86c63bbb7bc07c323d7ef2c53`.
- A previous macOS 15.7.9 / Xcode 26.3 / iOS 26.2 run built and installed but
  produced no app output. It remains unqualified, not a CallKit finding.
- **29** adversarial CLI checks pass: missing/empty/truncated evidence, wrong
  identities, accepted-but-undelivered actions, early timeout completion,
  detached-process cleanup and diagnostic failures cannot manufacture a pass.
- Three audio activation/deactivation cycles and capture processing were measured.
  **This is not independent two-way media proof.** Packet counters alone will not
  satisfy the media workstream either.

Replayable normalized traces, process receipts, exact environments, review
findings and limits are in
[discovery verification](../verification/2026-10-21-discovery-harness/README.md).
Historical research traces were kept unchanged.

### Native/React Native library

- Local library `eae5e37a6cd3046fbda05977489cf241645bb0f0`, runtime fixture
  `b7a33ab82785bf3d3862528f68f4a2cc689fbba6`, Xcode/SDK 27.1, iOS 27.0:
  actual Release Expo app and UI test bundle build; **1 XCTest passes** in
  22.063 seconds. A connects, malformed B is explicitly triggered, metadata
  completion is observed, A retains its UUID and can mute, then hang up cleanly.
- Hosted [39511821416](https://github.com/ziahamza/expo-callkit-telecom/actions/runs/39511821416):
  Xcode 26.6 / SDK 26.5 / iOS 26.5 also passes the real Expo/native/JS test.
  Synthetic merge checkout `56cbe6f25ce61a6a36ae6a48f7bef238da80ce37`.
  The 26.3 lane exits 65 during native build, before XCTest. Its first artifact
  lacks the compiler error; that failure is unclassified. Stage receipts and
  bounded pre-launch compiler diagnostics were added for the next run.
- Root TypeScript and plugin typecheck/build pass; the four existing plugin tests
  pass. Lint exits zero with existing warnings in unchanged source. No broad new
  unit suite was added.
- The original successful screenshot was visually inspected at normal phone
  resolution. Example buttons now expose button roles and disabled state.
- Raw app test logs and xcresult remain private because the upstream example
  logs its VoIP token. Public evidence contains reviewed screenshots, source and
  tool provenance, and structured summaries only.

The library's
[verification report](https://github.com/ziahamza/expo-callkit-telecom/blob/fix/ios-voip-push-hardening/docs/verification/2026-10-21-push-isolation/README.md)
contains reproduction and the exact qualification limits. Negative-control and
subsequent hosted results are recorded there as they finish; they must be judged
by their actual assertion/build phase, not just a nonzero exit status.

## Decisions implemented

1. **Keep the simulator separate.** The library CI currently consumes a pinned
   public discovery commit as a temporary fixture. It is explicitly not a stable
   released runtime. Pin full immutable release/artifact hashes once #2 ships.
2. **Preserve reporting by default.** `optionalVoIPPushPolicy: reportAll` is the
   default. `ignoreInvalidPayloads` skips only malformed pushes explicitly marked
   optional; valid invitations and every required report retain their reporting
   path. `mustReport == false` does not establish that an invitation is stale.
3. **Use a tiny Objective-C SDK adapter.** The exact metadata delegate selector is
   compiled only when its header exists. Swift does not mention an unavailable
   type, so actual old-SDK compilation can be qualified separately.
4. **Keep media SDK ownership separate from CallKit ownership.** LiveKit, Telnyx,
   Cloudflare, custom WebRTC and other adapters should be optional. The future
   Swift core must not force an RTCAudioSession singleton or introduce a second
   competing audio-session owner beside a vendor SDK.
5. **Do not port the prototype line for line.** It proves the seam and the measured
   scenarios. Provider selection, transaction identity, queueing, stale callbacks
   and audio ownership still need a production design.

## Production engine next slice

One next acceptance target: **two independently registered providers, on different
callback queues, preserve original transaction/action identity and cannot mutate
one another through reset, delayed completion or UUID reuse**.

Recommended boundary, independently reviewed:

- A minimal Objective-C simulator-only interposition/object-construction seam,
  with capability checks and a protocol implemented by a Swift 6 engine. Wire
  activation from the runtime to avoid an SPM target dependency cycle.
- Serialize state and synchronous getter snapshots, with an explicit reentrancy
  rule. Dispatch external effects outside the state lock/queue.
- Track provider registration/lifecycle epochs and call UUID **plus incarnation**.
  Fence delayed effects, timers, fulfillment and audio results by generation.
- Keep original transaction and action objects. Use a completion-acknowledgment
  barrier, not the prototype's fixed millisecond delay.
- Retain owned-action completion tombstones for the action's lifetime, so duplicate
  or late `fulfill`/`fail` never falls through to genuine CallKit.
- Measure `isComplete`, timeout dates, fulfillment dates and callback ordering;
  reconstructed objects and request acceptance alone do not prove parity.
- Model desired/actual audio participation per provider. A single global Boolean
  cannot represent two providers or delayed activation/deactivation safely.
- Test blocked report completion, background fulfillment, reset, invalidation,
  reused UUID, repeated completion and late action before expanding UI/media.

No standalone Swift Package, final Swift engine, CLI/control server, emulated
system UI, Expo Go support, full LiveCommunicationKit/Speakerbox conformance or
independent two-way media is claimed at this checkpoint. Expo native integration
uses a generated native development/Release build; Expo Go cannot acquire a new
native module just from JavaScript.

## Questions for Claude / concrete next decisions

These are requests for review or a targeted experiment, not reasons to block the
already implemented fixes.

1. **Outgoing provider ownership:** with two CXProviders registered, what exactly
   selects the recipient of a new outgoing CXStartCallAction? Capture delegates,
   registration order, provider configurations and transaction identity on the
   reference phone. Until measured, the runtime should fail ambiguous ownership
   explicitly instead of treating “latest provider” as an Apple rule.
2. **Placeholder lifetime:** review process-lifetime placeholder UUID retention
   inherited from #29. What observed terminal condition safely permits release
   while still absorbing delayed Answer/End? Avoid an arbitrary timer. Pair this
   with the valid-report/session-publication versus reset race; generation-safe
   ownership belongs in the next library patch.
3. **Swift package seam:** confirm that the standalone Swift core owns CallKit
   lifecycle and typed events, while transport/signaling and vendor audio adapters
   remain optional. We should not accidentally make the native Swift product
   depend on Expo, React Native, a WebRTC distribution or a specific backend.
4. **UI parity contract:** identical button labels cannot make an app-hosted view
   belong to SpringBoard or InCallService. Which existing tests must be unchanged,
   and which may use a helper that targets the active system-UI backend? Validate
   accessibility identifiers and the process/query boundary, not labels alone.
5. **Media proof:** approve independent two-endpoint injected-tone capture and
   correlation in both directions, plus clean activation/deactivation. Treat
   packet counts and nonzero local mic frames as diagnostics, not the pass gate.
6. **APNs/device work:** review existing real-push evidence before requesting new
   credentials. Propose one precise missing watchdog/cold-launch assertion that
   the simulator cannot establish, then run only the dedicated reference phone
   experiment. Do not expand live-provider work to compensate for harness defects.

For review, start with simulator #2's strict assertions and library #1's native
adapter/reporting path, then compare the native result against the original #29
failure. Follow with the ownership slice above. Keep RFC #5/#6/#7 decisions
explicit, and keep the fork's main identical to upstream.
