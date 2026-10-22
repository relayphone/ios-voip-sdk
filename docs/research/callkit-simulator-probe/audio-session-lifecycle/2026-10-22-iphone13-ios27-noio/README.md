# iOS 27 ordinary audio-session notification transport — no I/O

**Measured, October 22, 2026:** the iPhone 13 / iOS 27.0 completed all four ordinary audio-session operations with no engine or audio I/O: sync activate, sync deactivate, async activate, async deactivate. The independent raw listener, SDK Objective-C decoder, and actual Swift `SystemAudioSession.onLifecycle` consumer each observed **2 active and 4 inactive notifications**, with matching ordered, type-tagged scalar inventories. No resumption recommendation occurred; that path remains unmeasured.

The [verbatim 44-row trace](device-trace.jsonl), [derived receipt](receipt.json), and [file manifest](MANIFEST.json) bind run `8615D6C1-7C9C-450E-B56F-684DD5D07F35`, trusted PID `5692`, executable hash, source closure, and private capture/cleanup receipts. This is **PASS for the complete ordinary no-I/O fixture and its producer/decoder/Swift-consumer transport only**. A0.3, M2, LCK/system interruptions, and media-provider acceptance remain separate.

| Phase | Request / result / observation sequence | Observation duration | Main heartbeat ticks |
| --- | --- | --- | --- |
| Sync activate | 8 / 13 / 14 | 5001.310 ms | 235 |
| Sync deactivate | 15 / 19 / 24 | 5002.926 ms | 233 |
| Async activate | 25 / 26 / 31 | 5005.401 ms | 233 |
| Async deactivate | 32 / 36 / 41 | 5004.294 ms | 233 |

All four actual API result rows report success, `callMain=false`, and `callAudioQueue=true`. All nine operation-result, observation, and fixture-cleanup snapshots report `engineRunning=false`, `renderFrames=0`, and `renderCallbacks=0`. Observation snapshots intentionally leave operation-only result fields at their zero-initialized defaults; they do not report an additional API failure. The app was foreground before configuration and at every operation request, rather than continuously sampled.

Each activation phase delivered one active notification per stream; each deactivation phase delivered two inactive notifications per stream. Every raw inactive event carried an actual `AVAudioSessionDeactivationContext`, source `1`. Four raw route-change notifications are recorded separately. These counts describe this capture, not a universal promise about delivery counts or cross-listener ordering. The private NotificationCenter sentinel is synthetic and does not count as an AVAudioSession event. No context was fabricated or normalized.

The maximum sampled main heartbeat gap was **54.562 ms**. This packet does not qualify a main-thread stall threshold.

## Source and the earlier RED fixture

The run used the same already-built, signed Release executable `d7c1f3d9c5c1a450539c2677edcf1aa443a3fa3f92928b8d69c74c4afb7eca2b` and frozen source packet `b769cdfabed1785d6fcd4474fb29d8efcce9200c03db5c63da47e8e9942d03a8` as the [earlier silent-engine diagnostic](../2026-10-22-iphone13-ios27/README.md). The sole launch-mode change omitted `--silent-output`; the probe's existing false branch never starts an engine or source node. No rebuild, re-signing, SDK change, microphone capture, call, APNs push, route override, or volume command was involved.

This packet references the **14 unchanged source/project files** in the earlier packet instead of copying them again. `MANIFEST.json` binds that shared manifest and each source file hash. Its eight production audio files match frozen source commit `a212b9ea3a273c09e90f1b0fedb1f92b3a017312` and published M2 source commit `4dbb07c882c8d42ba4e51bb8eaf5327396a1c5ca`.

**The earlier silent-engine fixture remains RED, with its engine-stop cause UNKNOWN.** Its third-operation render failure, missing fourth operation, trace, receipt, and frozen validator are untouched. Completing this separate no-I/O mode does not explain that failure or qualify rendering.

This ordinary AVAudioSession app has no `ConversationManager`, simulator runtime, Expo bridge, or media-provider adapter. Its app-owned activation calls are diagnostic fixture operations. Under LCK, the SDK still waits for the genuine LCK delegate to authorize media. This capture does not measure LCK/cellular/system interruption, resumption recommendation, PushKit, provider media, or CI attestation.

## Capture and cleanup

The operator established absence of its own bundle before installing the frozen app, verified the current installed executable, and launched it through the trusted CLI result. It captured the new trace, rechecked the exact executable before stopping PID `5692`, obtained two independent PID-absence readbacks, uninstalled only its own app, and independently verified that bundle's absence. All 14 CLI commands exited successfully.

The stop command completed **30.718 seconds after the launch request**; first and independent PID-absence readbacks completed at **30.952** and **31.977 seconds**. The native cap remained 90 seconds. The operator elapsed time was 37.513 seconds, within its 360-second total / 240-second work / 120-second cleanup budget. No process or installed app remains from this run.

The public receipt contains only allowlisted derived values and SHA256 references to private build, launch, operator, validator, and cleanup records. Private operators, signing values, device identifiers/names, credentials, profiles, certificates, CLI JSON, and host logs are excluded. The public trace is copied verbatim after a field and private-value scan.

## Proposed manual reproduction

Use the [shared source packet's scratch-directory build and custody instructions](../2026-10-22-iphone13-ios27/README.md#proposed-manual-reproduction), retaining its bounds, partial-evidence handling, exact executable/PID checks, and independent cleanup. Build from a scratch copy of that source packet, not this four-file evidence directory. For this separate mode, omit `--silent-output`:

```bash
xcrun devicectl device process launch --device "$AUDIO_PROBE_DEVICE" --timeout 25 \
  --json-output "$AUDIO_PROBE_OUTPUT/launch.json" --terminate-existing \
  dev.iosvoipsdk.audio-lifecycle-probe -- --run-ordinary-audio-probe
```

Refuse inherited `DEVICECTL_CHILD_*` values and an existing installed app; create the local trace-copy destination before copying. Do not pass an empty `--environment-variables` option. These are proposed manual reproduction steps, not a qualification runner. They do not change either recorded run's result.
