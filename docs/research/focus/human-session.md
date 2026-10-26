# Focus harness: unattended execution and one-time microphone permission

There are **no manual QA rows** in this harness. Hamza already approved changing Auto-Answer Calls and Auto-Lock on the iPhone 13, with restoration, and using the Mac microphone. Do not request that approval again. The only remaining human interaction is clicking **Allow** on the first macOS microphone permission prompt. Missing permission produces `mic permission pending` and visual-only evidence; it does not hold a row open waiting for a person.

Claude owns device execution. This lane compiled generic iOS and dry-ran the host tools without using a device or recording microphone input. Build/dry-run success does not qualify installed-OS selectors or Auto-Answer behavior.

## Claude's automated sequence

1. Build/sign the dedicated probe and test runner with the approved sandbox team, all app/extension App Groups and development APNs capabilities. Set `FOCUS_DEVICE` to the dedicated iPhone 13 and `FOCUS_XCTESTRUN` to that **signed device** build's `.xctestrun`. Generic unsigned products cannot be installed.
2. Load the [documented sandbox APNs environment](../../../discovery/device/README.md) privately. Use an owner-only persistent `FOCUS_WORK`, or ignored `spikes/focus/out`. Preserve its journal across invocations and capacity/session restarts.
3. Run `spikes/focus/run.sh C00 --listen`. The listener requests the Mac permission once and exits if pending. Re-run C00 after authorization settles. It must establish a quiet/positive RMS contrast and a visible call surface before negative observations qualify. No one judges ringing by ear.
4. Run F01–F16 and applicable control/activity rows, e.g. `spikes/focus/run.sh F09 --listen`. The runner applies owned Focus/list settings, arms the app, sends once, fetches report/survival/UI/audio evidence, disarms and restores. Unknown Focus state or changed selectors stop the row; missing evidence is unqualified.
5. For locked/cold answering, run `spikes/focus/run.sh F01 --locked-auto-answer --listen`. Approved Settings automation journals original Auto-Answer/delay and Auto-Lock, selects on/3 seconds and 30 seconds, terminates the probe, ends XCUITest, waits 45 seconds, then sends a cold push. Native `JoinConversationAction` records whether Auto-Answer applied to that LCK call. Actual physical lock is not inferred solely from the elapsed timer.
6. Live Activity rows collect inventory/state/content and `contentUpdates`, send a silent APNs update, assert the latest synthetic text in Notification Center and save a screenshot. L09 waits past stale-date and expects **Updates delayed**. No live visual QA session is required.
7. Run `spikes/focus/run.sh restore-all` after interruption. The host journal restores original Focus, deletes only owned test objects, and restores Auto-Answer/delay and Auto-Lock. Initially undetermined app permissions require uninstalling this **disposable probe only**, after traces are fetched; the runner does that reset. Failed restoration is non-success: preserve the journal and stop the batch.

## Automatic evidence and limits

| Evidence | Result / limit |
| --- | --- |
| Report | Domain/code chain, entry/result times, invitation UUID, completion and available survival samples |
| Call surfaces | Timestamped SpringBoard/InCallService observations; negative queries require C00 qualification |
| Acoustics | Calibrated energy above baseline with acquisition coverage; ambient noise/placement can cause false positives/negatives. A proxy for ringtone/buzz energy, not a semantic classifier or guaranteed vibration measurement |
| Locked answer | Setting readbacks, no live XCUITest during auto-lock wait, cold report and Join callback; actual lock remains unverified when unavailable |
| Transcript | Native current/applied content observations and exact Notification Center assertion/PNG; suspension can defer native stream logging until foreground |
| Unsupported/dependent row | Automatic `skipped-dependency-or-unsupported`, with reason; no human reassignment or false pass |

Original C03/C04/C07–C11, L05–L08/L10–L16 and T01–T06 need additional policy/fault/backend adapters or unavailable hardware. The CLI enumerates these limits automatically. It does not invent an AI/SIP backend or fabricate device security-policy outcomes. Automation and device qualification are separate milestones.

If device security prevents reopening Settings after auto-lock, preserve recovery state and report restoration failure. Do not ask Hamza to drive test steps or count the row as passed. Keep screenshots, receipts, tokens and RMS envelopes private and out of git; no raw audio is saved.
