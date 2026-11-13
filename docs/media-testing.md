# Software-audio testing contract

`@relayphone/ios-voip-sdk/testing` defines one TypeScript interface for platform media test
adapters. It imports no LiveKit runtime. The platform adapter must observe the app's real call
media; a second test room cannot stand in for it. Calling `createMediaTest` without an adapter
rejects with `MediaTestError` code `unavailable`. Native media hooks and a far-end peer are
separate integrations.

```ts
import { createMediaTest } from '@relayphone/ios-voip-sdk/testing';

const media = await createMediaTest({ conversationId, fixtureId }, platformAdapter);
try {
  await media.beginPhase('answered');
  await media.expectAudio({ direction: 'toDevice', within: 3000 });
  await media.expectAudio({ direction: 'fromDevice', within: 3000 });
  await calls.setMuted(conversationId, true);
  // Begin after the platform has acknowledged the effective mute, not merely request acceptance.
  await media.beginPhase('muted');
  await media.expectSilence({ direction: 'fromDevice', for: 500 });
} finally {
  await media.close();
}
```

Directions are relative to the app. `toDevice` defaults to the post-output-gate observation;
`fromDevice` requires independent far-end reception. An explicit `stage: 'decoded'` checks
received decoded PCM and establishes no output or hold-silence claim. Missing output capability
never falls back to a decoder tap. Durations are integer milliseconds, bounded to 60 seconds.

Each open supplies a fresh native/host session UUID, including across JavaScript reloads. Phase
marker identity includes fixture, conversation, that UUID and per-runtime/session generations.
Each acknowledged phase also has observer-local monotonic clock anchors.
Assertions only accept that phase's fixture, conversation, direction, stage and clock. Never
subtract host and device timestamps. `firstAudioAfterPhaseMs` is a sample-clock marker-start
estimate anchored to the capture's first-frame observation, not calibrated one-way or acoustic
latency. The whole marker must fit within the deadline. Device and peer clocks stay separate.

A receipt reports observed PCM levels/counts separately from independent observer liveness.
A muted publication can deliver no PCM: silence can pass only with an active installed tap,
continuous monitor ticks covering the entire requested interval, no observation gap above
40 ms, and no overflow. Zero frames by themselves prove nothing. Monitor ticks attest that the
observer remains installed and running, including intervals without media; adapters must not
manufacture them from a stopped recording or fill missing PCM with zeroes. A missing tap throws
`capability_missing`; leaks throw `audio_leak`. Evidence is validated independently of a
producer's `passed` flag. Assertions are serialized; `close` cancels reads and is idempotent.
Open/phase acknowledgements and cleanup have 3-second delivery bounds; read waits are bounded by
the requested duration. These delivery bounds do not extend the receipt's phase deadline.

`createMarker`, `markerSamples` and `detectMarker` implement `tones-v1`: normalized mono PCM,
20 ms tone slots, four synchronization frequencies (650/950/1350/1850 Hz), then sixteen slots
encoding a 32-bit FNV-1a hash of the UTF-8 phase ID. A full cycle is 400 ms. Generate chunks from
absolute sample offsets so pacing does not restart the signal. Detection checks every slot,
requires at least 0.8 tone confidence and scans at approximately 1 ms resolution. This is a
content marker, not a cryptographic identity. Marker and silence thresholds are versioned here;
RMS/peak silence limits are 0.003/0.01. PCM gaps do not establish RTP packet loss.

Adapters implement `MediaTestAdapter` and `MediaTestConnection`. They own permissions, test-build
exclusion, capture taps, receipt production, cancellation and native cleanup. `read` receives the
full phase, expected marker, observation stage and duration, and returns serialized evidence;
`validateMediaReceipt` rejects malformed, stale, mismatched or incomplete evidence. Credentials
and raw PCM stay out of JavaScript receipts. Run `npm run typecheck --prefix expo` and
`npm test --prefix expo` to exercise the contract and its failing controls.
