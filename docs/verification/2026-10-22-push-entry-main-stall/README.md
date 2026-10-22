# PushKit entry while the SDK actor is blocked

**Measured host regression:** the previous production receiver awaited MainActor
before reaching its reporting dependency. The actual native delivery method and
delivery ticket returned after 2.005079 s while main was blocked; the reporting
facade first entered at 3.001280 s. The invariant failed with exit 1 and valid
single-report/completion cardinality. [Baseline receipt](baseline-red.json).

**Measured host result after the change:** the reporting dependency entered off
main at 0.000379 s, the native callback returned at 0.000424 s and completion ran
once at 0.000464 s. The host measured main blocked for 3.006523 s; state projection
remained at zero until main resumed, then ran once. Canonical UUID/payload and the
pending attempt were checked at report entry. [Green receipt](main-stall-green.json).

**Measured cache-order correction:** the whole production client also exposed a
foreground return race when observation delivery was deliberately held. Before
the fix, an already-reported duplicate and a joined success returned an empty
cache; a joined failure retained the previous live cache. Public return/catch
now sees the expected counts 1/1/0, with canonical payloads and the original error
preserved. [Red receipt](cache-order-red.json), [green receipt](cache-order-green.json).
These model a callback timing boundary; they do not measure real LCK ordering.

These timings describe a Foundation reporting facade. They do not measure LCK,
PushKit in an app, APNs or a physical device. The test compiles the exact current
receiver, incoming transport and native wait body, the actual native delivery
ticket, and the actual intake/models/wire decoder. It substitutes only the
framework report dependency and actor projection client.

[Host/compiler checks](host-checks.json) bind 116 code inputs and 19 successful
commands at working input digest
`4dc269abb4ed0377f50a24253003329da3196745284913b3d79f4df020b442cf`.
They include receiver-policy controls, missing/empty/substituted evidence gates,
store/core/projection/context controls, workflow syntax, full SDK simulator and
Release device typechecking, and both native probes' SDK typechecking. No app was
built or launched for these compiler checks. The SDK paths in command arguments
are redacted; exact private receipt digests and stream hashes remain bound.

The [intake controls](intake-controls.json) independently compile and run 13 groups
in debug and optimized builds. They cover concurrent identity/settlement, rollback,
foreground joins, required independent attempts, reset generations/tombstones,
late actual membership, alias isolation and reentrant error destruction. Earlier
red controls and intermediate candidate runs remain retained locally.

Reproduce the host controls with:

```sh
python3 Tests/VoIPSDK/run_incoming_delivery.py
python3 Tests/VoIPSDK/run_incoming_cache.py
bash Tests/VoIPSDK/run_incoming_intake.sh
python3 discovery/check_push_report_entry.py
python3 discovery/check_push_report_capture.py
```

**Proposed app acceptance:** CI must still run the five source-bound PushKit
entry cases and the genuine-LCK `duplicate-wrapper` compatibility contract on its
owned simulator. The latter checks public SDK results, the real LCK-to-provider
attempts and real end-action cleanup; it does not introspect NSError wrapping
depth or deliver an actual PushKit callback.

The transport's narrow framework interop assumption, conservative refusal of
ambiguous concurrent simulator attribution, and the bounded residual-object
reconciliation limit are recorded in the
[A1 handoff](../../progress/2026-10-22-codex-a1-push-entry.md).
Corrected-head locked and unlocked APNs cold launches remain for Claude's iPhone
measurements before beta. Earlier successful device runs do not qualify this fix.
