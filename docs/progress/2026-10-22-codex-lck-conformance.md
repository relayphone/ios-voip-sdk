# B: prepared LCK runtime acceptance

Status: proposed integration, with measured offline checks. No native LCK build
or simulator run was performed for this change; the local simulator slot remains
reserved for R2. Native acceptance is pending after the runtime-fix stack lands.

## What is prepared

- The default harness compiles the exact measured
  `docs/research/callkit-simulator-probe/lck.swift` input. Its only transformation
  replaces one asserted `exit(0)` with `return`, retaining supervisor-owned
  termination, capture receipts and the engine journal. LCK launches create no
  unrelated `Probe`/`CXProvider`, including when a stale push-mode marker exists.
- Four runtime captures use `PROBE_MODE=lck` with `PROBE_LCK=basic`, `cx-after`,
  `lck-after`, and `two-managers`. `CKSIM_ONLY=lck-<scenario>` selects one bounded
  diagnostic; normal CI automatically runs all four through the existing
  `run.sh`, without a workflow edit.
- New `lck_conformance.py` requires process-bound receipts, journal hashes and
  R5 loaded-image/package identity checks. It derives expectations from the
  corresponding committed iPhone trace. R7's shared deadline reader pools all
  measured LCK samples; tolerances remain explicit qualification policy.
- Ordered receiver/kind/value streams preserve app action UUIDs and system mute
  echoes. Conversation UUIDs bind to outgoing request journeys and successful
  incoming reports. Per-manager state streams, observer states, snapshots,
  pending actions, main callbacks, final emptiness and audio ownership compare
  against the device. Audio callbacks bind to their request journey. Cross-manager
  state callback interleaving is not asserted as a platform contract.

## Measured evidence and limits

- Reference: the four
  `livecommunicationkit/2026-10-21-iphone13-ios27-lck-*.jsonl` device captures.
  Their 24 logged LCK actions all sampled 30 seconds remaining. These establish
  callback deadline expectations; no native runtime deadline result is claimed.
- Normal incoming idle callbacks precede successful report logging in `basic`,
  `cx-after`, and `lck-after`. The `basic` remote report log precedes its idle
  callback at the same `t_ms=12144`. The check enforces only source-established
  per-role order and reports the remote logging ambiguity separately.
- R3 remains deferred. Acceptance compares journeys through the final labeled
  snapshot, before invalidation starts in the measured source. Post-snapshot
  `didBegin`/`didReset` inventory is reported separately; unrelated late events
  fail. There is no full raw-trace parity or teardown-modeling claim.
- The measured CX tap logs only receiver and kind, without action UUID, call UUID,
  deadline, mute/pause values or tone/pause handlers. The comparator preserves
  that evidence limit rather than inferring invisible callbacks. LCK-to-CX action
  UUID mapping remains unmeasured; LCK app-to-delegate UUIDs are checked directly.
- Offline red/green checks were observed rejecting changed action receivers,
  deadline/queue/state/snapshot/audio/outcome mutations, unbound loaded-image
  identity, and extra non-lifecycle events after the journey boundary after their
  corresponding assertions were implemented.

Measured checks:

- `python3 discovery/check_lck_conformance.py -v`: 12 tests pass, including all
  four device replays with fresh UUIDs, action/echo/target/value/order controls,
  incoming ordering, audio binding, missing/empty/unbound evidence, CLI diagnostic
  selection, source-derived deadline changes and explicit R3 exclusion.
- `python3 discovery/check_oracles.py -v`: all nine R7 controls pass.
- `python3 discovery/check_harness.py`: all 49 existing harness controls pass;
  `python3 discovery/check_image_identity.py`: all 11 R5 identity controls pass.
- Shell syntax, Python compilation, immutable-source transformation and mocked
  default/diagnostic launch dispatch checks pass. The measured `lck.swift` SHA256
  stays `2b0e430ff81453258da9782b94e5f770a5e41700ee5a5db98580c8e049b006d3`.

No runtime engine behavior, workflow, upstream repository or license is changed.
The prepared branch includes R7 as a dependency; integrate only this acceptance
commit after R7. Resolve the expected harness overlaps with R2/R6/R8/R9/R4 in the
final stack, then obtain a fresh native red/green result before claiming B passed.
