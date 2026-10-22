# LCK local native preparation

**Latest measured result:** all four local native LCK cases pass at clean source
`f106e73`, including genuine framework-image provider classification. See
[the red/green correction handoff](../../progress/2026-10-22-codex-lck-post-end-unmute.md)
and [the green receipt binding](native-green-f106e73/receipt-binding.json).
Hosted CI remains pending. The older preparation failure below is retained as
historical evidence; it is not the current local acceptance result.

**Measured: preparation failed before the probe was launched. Native LCK
acceptance is pending.** No incoming, outgoing, action, state or audio journey
was measured by this attempt.

`local-preparation-d924b34/` records the attempt from clean source
`d924b3487c748984ac0d9e53e44e40bf516a18d0`, using `CKSIM_ONLY=lck` and one
run-owned simulator. The probe compiled with the measured LCK source. The
simulator runtime package built for arm64 and x86_64 as version 0.1.1, with
`sourceDirty=false`. Saved metadata identifies iOS 27.0 build 24A434 and Xcode
27.1 build 27A9275.

The app-install preparation phase exhausted its 180-second budget after 184
seconds and exited 142. The four LCK launches were never reached. The
`preparation-receipt.json` is a preparation record, not a successful scenario
receipt; it explicitly records zero executed journeys and no acceptance pass.
Its hashes bind the copied manifest, build information and preparation metadata.
The ignored capture retains the package and full build log; binaries are not
duplicated in this evidence directory.

Cleanup initially remained open for the owned simulator
`00C40DF9-E9B6-42B0-AC0C-16072CBF17CE`. Initial shutdown/delete calls timed out,
as did a 60-second delete retry. After the separate root build was stopped, a
bounded query/delete/query retry still timed out at 30/60/30 seconds. The
simulator directory remained present. The temporary probe/runtime build
directory was removed. No global CoreSimulator service was restarted and no
other simulator was changed. `cleanup-confirmation.json` records this unresolved
status at that time; it does not claim successful cleanup.

A later bounded retry from source `9c52550` completed successfully after host
build load stopped. `cleanup-confirmed-9c52550.json` records an owned-device query,
shutdown and delete returning zero, followed by a successful query with no match.
The owned simulator directory and temporary build directory were both absent.
Only the run-owned simulator was operated on; native LCK acceptance remains
pending.

The branch subsequently integrated the acknowledged-launch supervisor fix.
That fix was not exercised by this attempt, which stopped before launch.
Hosted CI or a later local run must produce all four complete, process-bound LCK
captures and pass their conformance checks before B can be called accepted.
