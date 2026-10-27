# Focus harness: unattended execution and one-time microphone permission

There are **no manual QA rows** in this harness. Hamza already approved changing Auto-Answer Calls and Auto-Lock on the iPhone 13, with restoration, and using the Mac microphone. Do not request that approval again. The only remaining human interaction is clicking **Allow** on the first macOS microphone permission prompt. Missing permission produces `mic permission pending` and visual-only evidence; it does not hold a row open waiting for a person.

Claude owns device execution. This lane compiles generic iOS and dry-runs host tools without using a device or recording microphone input. Build/dry-run success does not qualify installed-OS selectors or Auto-Answer behavior. The new one-command [morning batch](../../../spikes/focus/README.md#morning-batch) signs using Xcode's account, checkpoints each row, yields to Phone through PAUSE, and restores at the end. Its only human interaction is the microphone permission click. The batch cannot read or change the physical Ring/Silent switch, so its position and both switch-specific outcomes remain unqualified without independent evidence.

## Claude's automated sequence

1. Set `FOCUS_DEVICE` to the approved iPhone 13's uppercase hardware UDID and load the [sandbox APNs environment](../../../discovery/device/README.md) privately. Use an owner-only persistent `FOCUS_WORK`, or ignored `spikes/focus/out`. The batch builds and signs its disposable app with Xcode's signed-in account; generic unsigned products cannot be installed.
2. Run `spikes/focus/morning-batch --dry-run` without a device, then `spikes/focus/morning-batch` in the approved device window. The supervisor verifies the iPhone 13, takes the cooperative device lock, checks Share Across Devices, runs the planned rows and restores settings. Real individual `run.sh` rows are rejected because they lack that process-group supervisor.
3. The listener requests Mac microphone permission once near the start and never hangs waiting for a person. C00 `--listen` is the last measurement: a positive calibrated control requires the expected visible call and energy contrast. Missing permission or evidence stays unqualified. No one judges ringing by ear.
4. Live Activity rows collect native inventory/content, transport and available system observations. L15 is a separate alerting push-to-start, never a silent start; the observer records what it can actually verify. Missing observations are unqualified.
5. PAUSE stops before the next row, restores the journal and releases the lock. After an interrupted failure, preserve the host and device journals. Direct `spikes/focus/run.sh restore-all` launches a lock-owning recovery supervisor using `FOCUS_DEVICE`, the original signed `FOCUS_XCTESTRUN` and the same `FOCUS_WORK`; it refuses an existing lock. If a hard crash left an owned lock, verify old subprocesses stopped and coordinate with Phone before removing only that stale lock and running supervised recovery. Failed restoration retains the new lock.

The locked/cold Auto-Answer adapter remains in the probe, but the current morning plan does not schedule that separate row. Device security, permission changes and actual lock state still need their own qualification; a direct unsupervised invocation is not available.

## Automatic evidence and limits

| Evidence | Result / limit |
| --- | --- |
| Report | Domain/code chain, entry/result times, invitation UUID, completion and available survival samples |
| Call surfaces | Timestamped SpringBoard/InCallService observations; negative queries require C00 qualification |
| Acoustics | Calibrated energy above baseline with acquisition coverage; ambient noise/placement can cause false positives/negatives. A proxy for ringtone/buzz energy, not a semantic classifier or guaranteed vibration measurement |
| Locked answer | Setting readbacks, no live XCUITest during auto-lock wait, cold report and Join callback; actual lock remains unverified when unavailable |
| Transcript | Native current/applied content observations and exact Notification Center assertion/PNG; suspension can defer native stream logging until foreground |
| Unsupported/dependent row | Automatic `skipped-dependency-or-unsupported`, with reason; no human reassignment or false pass |

The activity batch now attempts L01–L15 and records L16 as hardware N/A. Missing observations are unqualified, while system-token rotation, producer budgets, some privacy and lifecycle cases have explicitly labeled offline simulations. L15 uses a separately requested **alerting** push-to-start; it is not part of silent transcript mode. Actual secure Lock Screen/wake behavior, real Phone AI/SIP/backend behavior and sustained eight-hour expiry are not established by the synthetic unlocked-phone run. Original C03/C04/C07–C11 and T01–T06 still need policy/fault/backend adapters or unavailable hardware. The CLI does not fabricate security-policy outcomes. Automation and device qualification are separate milestones.

If device security prevents reopening Settings after auto-lock, preserve recovery state and report restoration failure. Do not ask Hamza to drive test steps or count the row as passed. Keep screenshots, receipts, tokens and RMS envelopes private and out of git; no raw audio is saved.
