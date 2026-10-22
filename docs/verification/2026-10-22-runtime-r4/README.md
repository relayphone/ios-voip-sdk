# R4 native repair evidence

**Measured native acceptance:**
[`local-377c56d-native-green.json`](local-377c56d-native-green.json) records all
16 checks passing on one disposable iOS 27.0 simulator, built from clean source
`377c56d41cc78b9262831ef6f39f96ae4a82fd5e`. It binds the CLI, fixture, package
and full native receipt hash. Every expected environment comparison passed;
independent bounded inventory and filesystem checks confirm deletion of the
owned simulator, ownership state and build. Hosted CI for the revised source
remains pending.

[`local-3409795-preinstall-readback.json`](local-3409795-preinstall-readback.json)
preserves the earlier native failure before CLI installation.
[`local-3409795-launchd-cross-api.json`](local-3409795-launchd-cross-api.json)
records the measured API difference: ordinary marker-variable writes were
visible through both readers, but only `spawn … launchctl getenv` reflected the
DYLD update. See the progress note for the one-off probe's absent/empty decoder
limitation. No Apple implementation or Argent cause is asserted.

`local-preparation.json` records two unsuccessful local preparations. Neither
ran `cksim install`; neither qualifies repair behavior. Private receipt hashes
bind the run summaries without publishing inherited environment paths. Both
owned simulators and the temporary build were deleted.

`interruption-control.json` is a **measured synthetic control** of the durable
runner. A fake build launches a sleeping descendant; SIGTERM interrupts the
runner. Its owned process group terminates, the temporary build is removed, and
a failing receipt appears within the recorded interval. No simulator is used.
This tests fixture cleanup, not native repair behavior.

**Hosted acceptance pending:** the Xcode 26.6 discovery job's
`Deleted-package simulator loader repair` step. Its separate
`callkit-repair-macos-26-xcode-26.6` artifact must carry a successful
`native-receipt.json`, bound source/CLI/fixture/package/helper hashes and the
actual simulator OS. Hosted OS qualification remains pending until that job passes.
