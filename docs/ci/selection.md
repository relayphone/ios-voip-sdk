# CI selection policy

Main pushes and the daily 03:20 UTC SDK/Runtime runs execute the complete suite.
Explicit manual dispatch retains full qualification. Pull requests use critical
journeys plus affected checks; the selector also understands merge-group events
for the later trigger rollout.

| Change | Automatic PR work |
| --- | --- |
| Documentation only | Selection tests and lightweight acceptance gates |
| SDK JavaScript | Host checks, shared producers, complete M0 and M1 critical journeys |
| Runtime/Inspector runner | Runtime and Inspector acceptance, helper controls |
| Shared compiled SDK inputs | Critical journeys plus affected contract, PushKit and legacy checks |
| Native dependency or fixture | Its device/Swift/Expo consumer as well as critical journeys |

The critical M1 worker retains the complete M0 prerequisites and all three M1
cases with their existing oracles. Other journey groups retain their complete
case sets when selected. Every worker owns its simulator and shared pre-app
budget. No product deadline or assertion is changed by selection.

SDK workflow execution edits select the changed optional jobs. Inherited
environment/default changes select all optional consumers. Comparison migrates
only the exact guards introduced by this policy; altered guards remain visible.
Missing workflow versions, unrecognized job boundaries and missing jobs fail
selection rather than silently skipping work. New source inputs conservatively
select critical SDK/Runtime checks.

The `plain-simulator` and `runtime-events` gates require every selected dependency
to succeed and every unselected dependency to be skipped. Selection must itself
succeed. A cancelled or unexpectedly skipped selected job is a failure. Main's
full policy selects every dependency, so main cannot pass through PR skips.

Only standard `ubuntu-latest`, `xcode-27` and `macos-26` runners are used. The journey
matrix permits five parallel workers; producer dependencies give shared builds
priority over longer independent consumers. Larger runners are not used.
