# R4 native repair evidence

`local-preparation.json` records two unsuccessful local preparations. Neither
ran `cksim install`; neither qualifies repair behavior. Private receipt hashes
bind the run summaries without publishing inherited environment paths. Both
owned simulators and the temporary build were deleted.

`interruption-control.json` is a **measured synthetic control** of the durable
runner. A fake build launches a sleeping descendant; SIGTERM interrupts the
runner. Its owned process group terminates, the temporary build is removed, and
a failing receipt appears within the recorded interval. No simulator is used.
This tests fixture cleanup, not native repair behavior.

**Proposed:** hosted native acceptance is the Xcode 26.6 discovery job's
`Deleted-package simulator loader repair` step. Its separate
`callkit-repair-macos-26-xcode-26.6` artifact must carry a successful
`native-receipt.json`, bound source/CLI/fixture/package/helper hashes and the
actual simulator OS. Qualification remains pending until that job passes.
