# Discovery harness checkpoint — 2026-10-21

Acceptance: a fresh native run must reject missing or misleading evidence, finish
all three scenarios, and clean up its own app/simulator. This checkpoint executes
the Objective-C discovery prototype. It does **not** complete runtime PR #2.

Measured source: `5515602` (full SHA in `environment.txt`), Xcode 27.1,
iOS 27.0 simulator. `summary.json` records success for genuine, runtime and push.
The JSONL files contain only probe events; raw stderr/devtools logs are omitted.
Historical evidence under `docs/research/` was not edited.

- Genuine: incoming report accepted, then observed teardown and unknown-call
  answer result; no CallKit audio activation.
- Runtime: expected request results **and actual delegate deliveries**, ringing,
  answer, hold/unhold, two-call/group callbacks, outgoing state, cleanup and
  retained-answer expiry/late-fulfillment behavior pass the measured profile.
- Answer expiry: runtime-delivered end action at **59.648 seconds** after answer delivery.
- Audio: three activation/deactivation cycles; both capture probes process
  **48,000 frames at 48 kHz**, mono. This is capture processing, not independent
  two-way media proof.
- Push: the fixture becomes ready before registry creation. After delayed
  registration, metadata delivery reports `mustReport: true`, shadow reporting
  succeeds, the virtual call rings, and cleanup fulfills, publishes ended state
  and reaches an empty final snapshot.
- All process receipts succeed. Cleanup deletes the run-owned simulator; existing
  simulators, device settings, launchd environment and physical devices are untouched.
- All **29 adversarial CLI checks** pass. Both metadata and forced-legacy compile
  paths typecheck with the installed SDK. Hosted compiler qualification is below.

Replay the immutable native capture:

```sh
python3 discovery/summarize.py docs/verification/2026-10-21-discovery-harness --require-receipts
python3 discovery/check_harness.py
```

## Hosted compatibility evidence

[Run 39509248937](https://github.com/ziahamza/callkit-simulator/actions/runs/39509248937)
exercised source head `102605a` (checkout merge recorded in the uploaded environment).

| Host | Xcode | SDK / runtime | Result |
| --- | --- | --- | --- |
| Local Mac | 27.1 | 27.1 / 27.0 | All three scenarios pass at `5515602` |
| GitHub macOS 26 | 26.6 | 26.5 / 26.5 | All three scenarios pass at `102605a` |
| GitHub macOS 15.7.9 | 26.3 | 26.2 / 26.2 | Builds/signs/installs; no app output before the 200-second deadline; unqualified |

The failed legacy-host attempt is not a CallKit measurement. Console output was
empty and termination also timed out, so retained evidence cannot distinguish a
launch stall, initializer block or console attachment failure. A separate reviewer
confirmed this classification. The new gate records app entry and launcher PID,
attempts bounded recovery of the probe's container trace on failure, and selects
the compiler separately from the newer simulator host. It does not claim that the
macOS 15 / iOS 26.2 tuple is fixed. Subsequent runs qualify their exact tuples.

[Run 39511363331](https://github.com/ziahamza/callkit-simulator/actions/runs/39511363331)
passed **both** compiler lanes at source head `77c4f03` (actual PR merge checkout
`7e7db7f09dd430a86c63bbb7bc07c323d7ef2c53`). Both use macOS 26.6.2, Xcode 26.6's
simulator host and the iOS 26.5 runtime:

| Compiler | SDK | Push callback | Genuine / runtime / push |
| --- | --- | --- | --- |
| Xcode 26.3 | 26.2 | legacy | Pass / pass / pass |
| Xcode 26.6 | 26.5 | metadata | Pass / pass / pass |

The normalized probe events, receipts, summaries and environment are retained in
[`hosted-39511363331/`](hosted-39511363331/). Each lane replays through the strict
gate with `--require-receipts`. This qualifies old-SDK compilation and legacy
callback execution on the newer host/runtime; it does not qualify iOS 26.2 itself.

## Standards

Initial review found **[P2] cleanup only ran while the launcher was alive**:
a launcher could exit while its detached app survived. Cleanup now independently
stops the run-owned app after every successful launch. A real detached-child
adversarial case verifies it. **Resolved.**

The next review found no actionable standards issues; its nonblocking documentation
note identified a stale v1 profile name. The README now describes v2 and immutable
historical replay inputs. **Resolved.**

A final diagnostic-recovery review found that failed `cp` could hide the original
scenario exit status. Recovery is now best-effort; the 29th adversarial check drives
the extracted shell function with launcher exit 7 and copy exit 9, requiring 7.
**Resolved.**

The reviewers confirmed owned UUID targeting, preservation of existing injection,
read-only CI permissions, pinned actions and no introduced credentials.

## Spec

Review identified and reproduced these gaps:

1. **[P1] Request acceptance passed without mute/DTMF/group delivery or real
   two-call snapshots.** The gate now validates the complete callback inventory,
   call/action identities, payloads, fulfillment and substantive snapshots.
2. **[P1] Push cleanup passed without fulfilled/observed ended state.** It now
   requires both; live v2 additionally requires an empty final snapshot.
3. **[P2] Genuine control passed without a successful incoming report.** It now
   requires accepted report → observed teardown → unknown-call answer.
4. **[P1] The timeout scenario passed an immediately fulfilled answer.** It now
   requires retained-action evidence, rejects early completion, and correlates
   ordered late fulfillment by action ID in v2.
5. **[P2] Early push delivery could overtake the registration marker.** Registry
   setup, retention and its marker now execute atomically on MainActor.

All five are **resolved**. Fresh bounded review of `6ff278c...5515602` found no
actionable issues; its wrong-ID and premature-completion mutations were rejected.

Review summary: Standards — one P2 and one documentation note resolved, zero open;
Spec — five findings resolved (highest P1), zero open within this checkpoint.

## Limits and next gate

The spike still has the independently identified engine ownership/concurrency
limitations. It is not a production Swift runtime, a complete D1–D12 conformance
profile, or a release artifact. In particular, transaction acceptance and group
callbacks do not prove conference media. An eight-second unanswered-call probe
does not qualify the measured sixty-second device ring timeout.

The next engine slice must prove provider ownership, original transaction/action
identity, callback queues, a completion acknowledgment barrier, retained-action
tombstones, reset/invalidation fencing and per-provider audio participation.
The SDK-agnostic Swift core, linked SPM delivery, CLI/bootstrap lifecycle,
LiveCommunicationKit/Speakerbox conformance, system UI and independent two-way
media remain implementation work. No APNs/device qualification was performed here.
