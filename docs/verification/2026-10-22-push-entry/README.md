# PushKit report entry: host controls and local preflight

**Measured:** three local captures stopped before installation or app launch.
The [preflight receipt](preflight-failures.json) binds their source, bounded
commands, retained private outputs and independent simulator-deletion checks.
No native case passed or failed: none ran. These failures do not qualify the SDK's
PushKit ordering or reproduce FB16655952 on a device.

| Capture | Last successful phase | Failure | Cleanup |
| --- | --- | --- | --- |
| `a1-push-entry-20261022` | Terminal boot, 1:33 | `launchctl getenv` timed out | Shutdown/delete returned 0; independent absence |
| `a1-push-entry-getenv-20261022` | Terminal boot, 1:19 | Conservative parser refused `simctl getenv`'s exact missing-key response | Shutdown/delete returned 0; independent absence |
| `a1-push-entry-getenv-followup-20261022` | Boot/data migration, nonterminal at 2:56 | 180 s boot-status budget expired | Shutdown timed out; delete returned 0; independent absence |

The third capture progressed through LaunchServices, Keychain and managed
configuration migration; it did not reach terminal boot. Later host load varied
substantially. Its cause remains unmeasured. A fourth owned simulator was created
but never booted; it was deleted with an independent absence check. No global
`DYLD_INSERT_LIBRARIES` value was changed and no physical device or APNs was used.

**Measured host/compiler controls:** [host-checks.json](host-checks.json) binds the
exact changed runner/gates and seven successful commands. Synthetic complete
captures test missing, empty and substituted evidence. The unchanged production
Swift receiver and obligation methods also run in host facades. These controls
are separate from native acceptance.

**Proposed native acceptance:** the existing M0 CI job builds the source probe and
runs `sdk-required`, `sdk-duplicate`, `missing`, `deferred` and `optional` on its
fresh owned simulator. No additional simulator lifecycle or global setup is
introduced. Required reports must actually settle before both native boundaries;
the duplicate must use the same UUID and settle with statuses 0 then 2. Missing
and deferred reports must remain rejected by the normal rule. A separate fixture
validator requires their complete expected boundary/report/diagnostic sequence;
a terminal probe marker alone cannot qualify a negative control.

The runner retains source/build/installed hashes, real launcher and app PIDs,
run IDs, profile/session identity, console and runtime journals. The enclosing
M0 runner records deletion. The CI artifact's focused capture can be replayed from
its exact source checkout with:

```sh
python3 discovery/run_push_report_entry.py --validate /path/to/sdk-m0/push-entry
```

Native simulator acceptance is pending CI. This is deliberately in-app injection;
A5's push-initiated process launch and locked/unlocked iPhone cold launches remain
separate acceptance targets.
