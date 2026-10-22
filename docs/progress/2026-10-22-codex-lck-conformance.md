# B: prepared LCK runtime acceptance

Current status: **local four-case native acceptance passes at clean source
`f106e73` after the narrow LCK fulfilled-unmute correction**. Hosted CI remains
pending. See the [current handoff](2026-10-22-codex-lck-post-end-unmute.md) and
its bound red/green evidence. The preparation history below predates that run.

Historical preparation status: native LCK acceptance was pending. Offline checks passed. A later local
native preparation compiled the probe and runtime, but app installation timed
out before any LCK launch. The owned simulator was deleted successfully after an initially failed cleanup;
see the local attempt record below.

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

## Prepared A stack integration

Integrated B onto `10716e464ca63b58ad50d40dccd6e4af27219f37` (the prepared
R5/R6/R7/R8/R9/R4 stack) on `codex/runtime-lck-acceptance`. The original B change
cherry-picked cleanly as `6b21ea4`. R8 OS/compiler metadata, R9 manifest/version
binding, R6 shipping controls and R4 loading/repair documentation are preserved.
R2's final concrete ABI guards and native evidence were subsequently pulled in
through the R4 stack by merge `b2195ac` (R4 parent `b14611f`).

Measured integration red: the B synthetic fixture still had its original
pre-R8/R9 manifest and failed with `missing simulatorRuntimeID`. It now saves a
synthetic runtime inventory and compiler version, includes the current root
`VERSION` in the manifest and package `build-info.json`, and labels the copied
probe rows as synthetic iOS 26.5 execution against the iOS 27.0 device reference.
The positive fixture proves those OS identities remain distinct. B JSON results
now carry the validated environment and runtime version as well as the device
reference. No common validation contract was relaxed.

Independent integration review also found that shared equality comparisons could
accept consistently absent identities (`None == None`). Seven controls removed
PID/run/simulator/bundle identities consistently or removed the trace/scenario
contract or changed launcher status while rebinding hashes; all were observed
accepted before adding LCK-local strict fresh-capture assertions. The B gate now
requires a positive PID, nonempty IDs, the probe bundle, trace version 2, the
matching receipt scenario and a supported launcher exit status. The shared A
validators remain unchanged.

Measured offline on the integrated source:

| Check | Result |
| --- | --- |
| LCK controls | 13 tests pass |
| Image identity | 14 controls pass |
| OS/compiler environment | 9 tests pass |
| Release controls | 18 controls pass |
| Device oracles | 9 tests pass |
| CLI repair | 10 controls pass |
| CLI identity/package/session controls | 13 controls pass |
| Existing harness | 50 controls pass |
| Both workflow `actionlint` checks, shell syntax, Python compilation and whitespace | Pass |

Fresh native B qualification and capture-based shipping mutation controls remain
pending. No native build, simulator launch, push or PR was performed for this
integration. The remaining acceptance risk is actual LCK/framework behavior under
the integrated runtime; offline device replays do not establish that behavior.

`CKSIM_ONLY=lck` now selects all four serial LCK journeys in one run-owned
simulator and exits after their common comparison. Individual LCK diagnostics
and the default complete harness remain available. Measured offline: 13 LCK
controls, ten mocked filter controls, nine preflight/dispatch selections, shell
syntax and whitespace checks pass. Both workflows also pass `actionlint` after
the final R2 workflow merge. The B native run waits for the R4 simulator cleanup
release before allocating its simulator.

## Local native preparation attempt

After the final R2/R4 guards were integrated, clean source `d924b34` ran
`CKSIM_ONLY=lck` in one owned iOS 27.0 simulator. **Measured:** the probe compiled,
and the runtime package built for arm64/x86_64 as version 0.1.1 with
`sourceDirty=false`. App installation then exceeded its 180-second budget
(184 seconds elapsed, exit 142). No LCK scenario was launched, so this supplies
no native LCK behavior or acceptance result.

The temporary build directory was deleted. Simulator shutdown/delete cleanup
timed out, and a subsequent bounded query/delete/query attempt still timed out
after the root build load was reduced. Owned simulator
`00C40DF9-E9B6-42B0-AC0C-16072CBF17CE` remains unconfirmed for cleanup, with its
directory still present. No global simulator service or other simulator was
changed. Further local native attempts stopped at this infrastructure boundary.

The compact [preparation evidence](../verification/2026-10-22-runtime-lck/README.md)
binds the source, manifest, build metadata, failed phase and unresolved cleanup.
The branch also merged the later acknowledged-launch supervisor through R4
(`f5038e3`); that fix was not exercised because this attempt stopped before launch.
The next acceptance evidence must come from a successful hosted or local
four-case run with strict receipt/image/environment binding. No B success is
claimed from compilation or offline replay.

## Cleanup confirmation

Measured at source `9c52550`: a bounded owned-device query returned in 0.170
seconds; shutdown and delete returned zero in 3.204 and 0.162 seconds. A final
query returned zero in 0.134 seconds with no owned-device match. The simulator
and temporary build directories were absent. The supplemental
[cleanup receipt](../verification/2026-10-22-runtime-lck/cleanup-confirmed-9c52550.json)
preserves this outcome without replacing the earlier failed-preparation record.
No additional simulator run occurred. The 13 LCK controls, nine device-oracle
controls and shell syntax check pass again on this integrated head. Native
four-case acceptance remains pending.
