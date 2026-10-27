# SDK acceptance jobs

The SDK workflow builds the simulator Release example once, alongside independent
core-probe and fixture producers. Portable evidence, shell and JavaScript checks
run on Ubuntu. Checks that compile Apple Foundation or SDK headers run in a
parallel Xcode job. Device-only inspections are independent of simulator journeys.

The journey matrix contains M1, contracts, PushKit entry and system controls.
Every group runs the complete M0 prerequisites and oracle; a separate M0-only
worker would duplicate those checks and occupy another macOS slot.
Each worker invokes the existing owned-simulator runner once, with a fresh run ID,
simulator and persisted preparation budget. Each retains its M0 prerequisites so
the existing source, binary, installed-byte and cleanup oracles stay intact.
Direct console supervision is unchanged; broader console-budget adoption remains
separate infrastructure work. The local runner defaults to the complete suite.

Component artifacts contain a tar archive plus a source/hash receipt. Transfer
verifies the committed source, architecture, complete file inventory, hashes,
executable modes and symlinks before creating a simulator. Only required SwiftPM
device objects are transferred; the DerivedData tree is discarded. Archive upload
does not recompress the already compressed tar payload.

Legacy audio waits only for its SDK27 fixture. The compatibility `plain-simulator`
gate requires every host/build/journey/legacy result to succeed, including every
matrix member; skipped or cancelled dependencies fail the gate.

Baseline [main5419149](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40296800038):
the old sequential job took33.87minutes; the SDK workflow took36.52minutes from
first job start through final legacy completion. PR descriptions and lane STATUS
reports record measured candidate/main timings. Targets are PR critical path
under15minutes and main full run under20. Path selection, caching and merge-group
support follow in separate changes after this graph qualifies on main.

Transfer artifacts include their producer role and workflow run ID and expire after one day. Their names stay stable across job reruns so a consumer can reuse successful producers from an earlier attempt; overwrite affects only that producer's artifact in the same run. Diagnostic artifacts also include the attempt and expire after three days. A transfer step has an eight-minute total bound and one upload retry; exhaustion fails the producer and strict aggregate. This recovery never launches or replays an app. Consumers still validate the original source/architecture/hash manifest.
