# Device pass (Claude, iPhone 13, iOS 27.0, October 23, 2026)

Real sandbox APNs, genuine LiveCommunicationKit (LCK), no runtime. Details and traces: `docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md`. This covers the M-Stable device item (§4.D and #22).

## What the device says

1. **PushKit's in-process deadline is about 4.4 s.**
   - It runs from delivery, regardless of completion.
   - A report starting at 3.15 s survives. One due at 5 s is killed at about 4.4 s (`-[PKPushRegistry _terminateAppIfThereAreUnhandledVoIPPushes]`).
2. **The SDK's PushKit fix works end to end on a locked cold launch.**
   - The report started at 0 ms, the delegate returned at 55 ms, and the report finished at 191 ms.
   - Answering on the lock screen delivered the join on main. `didActivate` came 236 ms after the join callback.
   - Every LCK delegate callback arrived on main (this supports `@preconcurrency` main-actor isolation).
3. **FB16655952 did not reproduce on iOS 27.0.** A deferred report (88 ms late) neither crashed nor was killed. Keep the "entered" design anyway.
4. **Filtered calls:**
   - `com.apple.CallKit.error.incomingcall` code 3 after about 2 s;
   - the app survives with `mustReport` true;
   - a repeat from the same number 69 s later was still filtered, so don't design around "repeated calls".
5. **`mustReport` is false while a call is active,** in the foreground and in the background.
6. **The mute echo arrives 8–17 ms after the app *fulfills* its mute.** `main`'s echo filter (#26) is correct for this, and the runtime's echo-after-fulfillment model matches.

## For the SDK thread

- **Close #22.** This pass covers it, so M-Stable's device item is done.
- **Hard rule:** nothing may delay the start of the LCK report (main, the JS runtime, React Native boot, metadata persistence). Add a CI assertion that a cold-launch push starts the report within 500 ms in the simulator.
- **Runtime:** enforce the about 4.4 s unhandled-push termination in the push lane, as an `ios-27.0` profile value, citing `late-report-5s`. The simulator must fail a too-late report the way a device does.
- **Filtered outcome:** keep mapping the domain string and code; no CallKit symbols. The native hook may run, because the app is alive after a filtered report.
- **Profile latencies:** cold-launch report about 190 ms; join to `didActivate` about 236 ms. Use these as reference values, not assertions.

## For the inspector thread (M4)

Show device reference values next to simulator measurements:

| Measurement | Device reference |
| --- | --- |
| Push to report done | about 190 ms |
| Join to `didActivate` | about 236 ms |
| Mute echo after fulfillment | 8–17 ms |
| PushKit kill deadline | about 4.4 s |

Plot actions against their deadlines (LCK actions: 30 s).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
