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

`createMarker`, `markerSamples` and `detectMarker` implement **`tones-v2`**, replacing the
unreleased `tones-v1`. Four sync slots (650/950/1350/1850 Hz) precede eight identity slots:
the low 16 bits of FNV-1a 32 over the UTF-8 ID, read two bits at a time, low bits first, mapped
onto those four tones. Each slot is 60 ms; all twelve slots form a **720 ms** marker.
Amplitude is 0.2 and phase restarts at each slot boundary. Rates must be 8000–96000 Hz and
divisible by 50. Generate chunks from absolute offsets to preserve the waveform.

Each slot has 5 ms raised-cosine fades. For sample `n` within an `L = rate * 0.060` sample slot,
let `u = min(1, min(n, L - n) / (rate * 0.005))`. The Float32 sample is
`0.2 * (1 - cos(π*u)) / 2 * sin(2*π*frequency*n/rate)`; slots occupy `[0, L)`.
Detection scores only the central 20 ms, with 20 ms guards on both sides, using normalized
Goertzel confidence and the unchanged mean-square energy floor of 0.0001. **Every slot must
score at least 0.8; the complete marker is required.** The search advances by approximately
1 ms and keeps the first complete detection, improving its minimum confidence within one slot
of that candidate. Slot zero starts that candidate. Each later slot chooses the best central
20 ms score within ±15 ms of the previous chosen start plus 60 ms, in 1 ms steps. The final
chosen start may drift at most ±60 ms from slot zero plus 11×60 ms. Confidence differences at
most 1e-12 count as numerical ties: prefer no local shift, then the smaller absolute shift,
then the earlier start. The >=0.8 acceptance threshold never uses that tolerance.

`MarkerDetection.slotStarts` contains all twelve absolute sample offsets within the captured
PCM; its first value equals `offsetSamples`. Receipts preserve a frozen copy and reject missing
starts, out-of-capture slots, local shifts beyond ±15 ms and final drift beyond ±60 ms. The
last aligned start plus 60 ms determines the received marker end, including deadline validation.
Chosen scoring starts expose alignment changes; they are not physical tone-onset measurements. Guard time makes the marker-start estimate uncertain by up to 20 ms; it is not a
physical onset measurement. Neither energy alone nor a partial identity establishes audio.
Receipts carry `profile: "tones-v2"`; validation rejects absent/other receipt profiles and
incompatible requested marker shapes, including on silence assertions. Every aligned slot must fit in the capture, and the final aligned slot end must fit the deadline.

These are the SHA-256 parity vectors for **`createMarker("parity-v2")`**, one 720 ms cycle.
Convert the returned Float32 samples to signed PCM16 with `Math.round(sample * 32767)` (nearest,
half toward positive infinity), then write little-endian. Hash exactly those bytes, without a
WAV header. Each implementation must reproduce both vectors.

| Rate | Samples | PCM16 LE SHA-256 |
| --- | --- | --- |
| 8000 Hz | 5760 | `7305be4e1d4ba73d2f2f876869fa5cb27c12bb91450081452139f41262f7c003` |
| 48000 Hz | 34560 | `82f79efb9f1b24a5c839cd500f5c9ad291ef5969348c3d68b775fcef6f8fa3b4` |

Every source uses **`emissionSamples(marker, rate, count, offset)`** to emit a repeating
**1020 ms** cycle: a 150 ms 400 Hz pre-roll, the unchanged 720 ms marker, and a 150 ms
400 Hz post-roll. Both rolls have amplitude 0.2; their phase starts at zero. Only the first
5 ms of the pre-roll and last 5 ms of the post-roll use raised-cosine fades. The inner roll
edges are not faded. The marker bytes, profile, detector and thresholds remain unchanged.
Offsets address the entire repeating emission, so chunking must not restart its pre-roll.

For precise cross-platform sampling, cycle length is `rate / 50 * 51`, pre-roll length is
`round(rate * 3 / 20)`, and marker length is `rate / 50 * 36`. Post-roll consumes the remaining
cycle samples. For uncommon supported rates with half-sample roll boundaries, the pre-roll is
rounded to the nearest sample (ties upward); the total cycle stays exactly 1020 ms. For roll
sample `n`, use the same raised-cosine formula above with `u = min(1, n/(rate*0.005))` on
pre-roll and `u = min(1, (postLength-n)/(rate*0.005))` on post-roll, multiplying a 400 Hz sine.

Emission parity vectors use `createMarker("parity-v2")`, 1020 ms and the same PCM16 LE conversion:

| Rate | Samples | Emission PCM16 LE SHA-256 |
| --- | --- | --- |
| 8000 Hz | 8160 | `e339576ee90e3d72ef65c7a5e44ab4a74345be472fdcd39b8f25072448a5fbab` |
| 48000 Hz | 48960 | `0a79ca1399b4fc018584bcf8e90be7c476618fab47f903b9670ce1282eafbaa1` |

Capture windows must include the post-roll so the last marker slot is not the last received
audio. The unchanged detector checks only the twelve marker slots: a truncated post-roll can
still yield a marker when every slot passes, and can never excuse a missing or wrong slot.
The generator does not establish capture coverage; platform fixtures must measure it.

This is a content marker, not a cryptographic identity. PCM gaps do not establish RTP packet
loss. RMS/peak silence limits remain 0.003/0.01. Transition-settling, missing-slot, wrong-tone,
low-energy and parity controls exercise the profile; real processing/Opus qualification is a
separate platform requirement.

Adapters implement `MediaTestAdapter` and `MediaTestConnection`. They own permissions, test-build
exclusion, capture taps, receipt production, cancellation and native cleanup. `read` receives the
full phase, expected marker, observation stage and duration, and returns serialized evidence;
`validateMediaReceipt` rejects malformed, stale, mismatched or incomplete evidence. Credentials
and raw PCM stay out of JavaScript receipts. Run `npm run typecheck --prefix expo` and
`npm test --prefix expo` to exercise the contract and its failing controls.
