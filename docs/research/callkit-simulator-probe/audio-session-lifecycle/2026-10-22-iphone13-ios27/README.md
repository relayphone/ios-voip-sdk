# iOS 27 ordinary audio-session diagnostic — RED

**Measured, October 22, 2026:** an iPhone 13 on iOS 27.0 delivered the new audio-session notifications to an independent raw listener, the SDK's Objective-C decoder, and an actual Swift `SystemAudioSession.onLifecycle` consumer. Their complete modern scalar inventories in this capture agree: **2 active and 3 inactive events**. Every raw inactive event carries an `AVAudioSessionDeactivationContext`, with source `1`.

**The four-operation fixture failed.** It completed sync activate/deactivate, then failed its render guard after async activation. Async deactivation was never requested. The frozen validator remains RED; this packet publishes the failure for review and does not complete A0.3 or M2.

## Measured observations

The [verbatim 37-row trace](device-trace.jsonl), [derived receipt](receipt.json), and [file manifest](MANIFEST.json) bind run `105C6DD8-5335-4413-B658-EA61C7ECFFC9`, trusted launch PID `5524`, the signed executable hash, source hashes, and private capture/cleanup receipts. The private operator's last CLI label is `trace-copy-0`: that copy succeeded. The subsequent strict validation rejected `experiment.failed`.

| Phase | Evidence in `sequence` | Measured result |
| --- | --- | --- |
| Sync activation | 8–14 | Session activation and engine start succeeded. During the 5010.198 ms observation, the output-only source rendered 240672 zero-filled frames in 218 callbacks. |
| Sync deactivation | 15–24 | Engine stopped before session deactivation; the API succeeded. Frames remained 240672 through the 5003.175 ms observation. Two typed inactive notifications were delivered. |
| Async activation | 25–31 | The API and initial engine start succeeded, with `engineRunning=true`. After 5013.695 ms, `engineRunning=false` and frames/callbacks remained 240672/218. Both render-guard conditions failed. |
| Failure and cleanup | 32–37 | The fixture reported `ProbeFailure`, stopped its engine, successfully deactivated the session, and closed the trace. Another typed inactive event arrived during cleanup. |

**The engine-stop cause is unknown.** Snapshot rows intentionally leave operation-only result fields at their zero-initialized defaults; their `sessionSuccess`, `ioSuccess`, or `callAudioQueue` values do not report another API call or prove a queue violation. The failure is the observed engine state and unchanged render count, evaluated by the unchanged guard in `probe/Probe.swift`.

The source node only zeroes output buffers and increments counters. It accesses no input node or tap, captures no microphone data, and uses no audio files, calls, PushKit, APNs, signaling, explicit route override, or volume controls. The private NotificationCenter sentinel is explicitly synthetic and is not counted as an AVAudioSession event.

**Measured cleanup:** the operator verified the current PID's exact installed executable before terminating it. Two subsequent PID queries were empty. It uninstalled only the owned probe, then independently verified that bundle's absence. Launch to the first PID-absence readback was 31.604 seconds, within the unchanged 90-second native cap. The operator receipt elapsed time was 36.358 seconds. No app remains installed from this run.

## Source and scope

The 14 source/project files are unchanged bytes from frozen source packet `b769cdfabed1785d6fcd4474fb29d8efcce9200c03db5c63da47e8e9942d03a8`. All eight files under `core/Sources` match both source commit `a212b9ea3a273c09e90f1b0fedb1f92b3a017312` and published M2 source commit `4dbb07c882c8d42ba4e51bb8eaf5327396a1c5ca`. The probe uses their actual configuration, serial audio queue, lifecycle decoder, and Swift consumer. No shipping SDK source was changed for this measurement.

This is a Release **ordinary AVAudioSession** application, with no `ConversationManager`, simulator runtime, Expo bridge, or media-provider adapter. Its app-owned activation calls are fixture operations; they are not a proposal to call `setActive` under LCK. The eight shared audio files do not make the rest of this composition equivalent to the SDK's LCK or simulator journeys. Earlier simulator captures, failed preparation attempts, and their operators remain private and retain their original results.

The capture establishes partial producer/decoder/Swift-consumer observations only. It does **not** qualify the full fixture, async deactivation, recommendation delivery, cellular/system/LCK interruption, PushKit, provider media, a main-thread stall threshold, or CI attestation. No notification contexts were fabricated. Repeating the run or changing the fixture is **proposed work**, requiring a separate bounded measurement; it cannot turn this capture green.

The public receipt contains only allowlisted derived fields and SHA256 references to immutable private build, launch, capture, and cleanup records. Private operators, device identifiers/names, signing configuration, profiles, certificates, CLI JSON, and raw host logs are intentionally excluded. The trace itself passed a strict field and private-value scan and is copied verbatim.

## Proposed manual reproduction

Use a dedicated, authorized device with iOS 27 or later and private signing values. The generic XcodeGen project has no team or device identifier. First copy this entire packet into an external or ignored scratch directory **before running `xcodegen generate`**; run the commands from that copy so generated projects, build outputs, and private signing artifacts stay outside the tracked checkout. Set `AUDIO_PROBE_DEVICE`, `AUDIO_PROBE_TEAM`, and an absolute scratch `AUDIO_PROBE_OUTPUT` privately. Refuse to overwrite an existing app with this bundle identifier. After installing your own probe, complete any device trust step by opening it without pressing **Run once**.

```bash
xcodegen generate
xcodebuild -project AudioLifecycleDeviceProbe.xcodeproj \
  -scheme AudioLifecycleDeviceProbe -configuration Release -sdk iphoneos \
  -destination "id=$AUDIO_PROBE_DEVICE" DEVELOPMENT_TEAM="$AUDIO_PROBE_TEAM" \
  -derivedDataPath "$AUDIO_PROBE_OUTPUT/DerivedData" -allowProvisioningUpdates build
```

Install only that newly built ordinary app with `devicectl device install app`. Before launch, refuse any nonempty inherited `DEVICECTL_CHILD_*` variable. Do not pass an empty `--environment-variables` option: that failed CLI parsing in an earlier private attempt.

```bash
mkdir -p "$AUDIO_PROBE_OUTPUT/Documents"
xcrun devicectl device process launch --device "$AUDIO_PROBE_DEVICE" --timeout 25 \
  --json-output "$AUDIO_PROBE_OUTPUT/launch.json" --terminate-existing \
  dev.iosvoipsdk.audio-lifecycle-probe -- --run-ordinary-audio-probe --silent-output

# Copy around 30 seconds after launch; the LOCAL destination must already exist.
xcrun devicectl device copy from --device "$AUDIO_PROBE_DEVICE" --timeout 8 \
  --source Documents --domain-type appDataContainer \
  --domain-identifier dev.iosvoipsdk.audio-lifecycle-probe \
  --destination "$AUDIO_PROBE_OUTPUT/Documents"
```

These are manual command examples, not a qualification runner. Enforce a 90-second launch-to-process-stop bound, retain partial evidence on the first failure, select a newly created trace by trusted launch PID/run ID/executable hash, and verify the exact installed executable before stopping that PID. Retain the trace before uninstalling your own app; independently verify both PID and bundle absence. The published failed capture remains the reference for this packet.
