# R1 acceptance evidence

**Measured** with the shipped Swift runtime and actual CallKit report callbacks on an iOS 27.0 simulator.

| Capture | Engine | Result |
| --- | --- | --- |
| `red/` | Unchanged v0.1 engine | Completed scenario; checker rejects both nil-queue completions delivered off main |
| `green/` | Nil-queue fallback changed to `.main` | Four callbacks pass: nil/custom queue, each with success and duplicate error |

Each directory contains the supervisor receipt, raw console trace, engine journal, semantic result, run manifest and runtime build metadata. Receipt SHA-256 values bind the console and journal bytes. The dirty source-input digests distinguish the locally built engines; the green digest was recomputed from the final runtime inputs. Binary artifacts remain local. R5's loaded-image verification remains a separate acceptance target.

Replay the green acceptance from the repository root:

```sh
python3 discovery/report_threading_conformance.py docs/verification/2026-10-22-runtime-r1/green
```

The same command with `red` must fail with `nil queue incoming completion delivered off main`. `harness-checks.json` records the passing adversarial checks, including off-main success and duplicate-report mutations. The committed iPhone traces provide the reference: 19 of 19 completions on main.
