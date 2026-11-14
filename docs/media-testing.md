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

## Synthetic capture configuration

The media test kit keeps **AEC and AGC enabled and noise suppression disabled** for synthetic
capture on both platforms: Debug iOS Simulator builds and Android `emulatorTest` builds only.
The iOS fixture explicitly requests WebRTC software processing and verifies the requested and
active AEC/AGC state, plus inactive NS, in its receipt. Production media configuration is unchanged.

The kit verifies audio in both directions, publication/output gates and timing. Synthetic tones
are not speech and can be removed by noise suppression; this kit does not grade NS fidelity.
Noise-suppression quality remains part of device and speech QA. A failure with NS disabled still
requires per-slot confidence, margins and chosen timing evidence; AEC and AGC stay enabled.
The complete-marker threshold and timing limits below remain unchanged.

## Marker profile

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
score at least 0.8; the complete marker is required.** The search advances by approximately 1 ms. For slot zero, find the first passing sync window,
then select its best score within one 60 ms neighbourhood **before** aligning later slots.
Do not move this anchor after a failed drift cap; continue searching after that neighbourhood.
This prevents an over-cap waveform from passing by moving slot zero later. A complete path
exists only when every subsequent slot scores at least 0.8 and its start is on the 1 ms grid,
within ±15 ms of the previous chosen start plus 60 ms. At every slot, cumulative drift from
slot zero plus `k*60` ms must remain within ±60 ms. **Drift may change only at a tone
transition:** equal consecutive expected tones require equal drift.

Dynamic programming over (slot, cumulative drift) selects exactly, in order: least total
movement `Σ|d_k − d_(k−1)|`, highest sum of slot confidences, then the lexicographically
earliest start sequence. Keep one optimal prefix per state; future transitions depend only
on that state. There are at most 12 × 121 × 31 transitions per anchor. Slot-zero confidence
differences at most 1e-12 retain its earlier anchor. Path confidence sums within 1e-9 count
as equal and fall through to the earliest-start sequence, avoiding cross-language sin/cos
roundoff changing the selected path.
No tolerance applies to the >=0.8 gate. Unstretched emissions keep twelve zero drifts.

`MarkerDetection.slotStarts` contains all twelve absolute sample offsets within the captured
PCM; its first value equals `offsetSamples`. Receipts preserve a frozen copy and reject missing
starts, out-of-capture slots, local shifts beyond ±15 ms, any cumulative drift beyond ±60 ms,
and drift changes between equal expected tones. The
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

### Pitch-preserving detection vectors

The reference generator is `expo/test/contracts/detection-vectors.ts`, using `parity-v2`.
It edits the full Float32 emission without resampling, then encodes PCM16 LE with the same
conversion as the parity vectors. Detection runs on PCM16 decoded as `sample / 32768`.

All edits occur **45 ms after the original start of the indicated zero-based marker slot**,
after its central [20,40) ms scoring window. For ±40 ms use slots `[2,5,8,10]`, at original
emission times `[315,495,675,795]` ms. For +80 ms use slots `[1,2,3,4,5,6,8,10]`, at
`[255,315,375,435,495,555,675,795]` ms. Adjust subsequent positions by accumulated edits.
Insertion copies the immediately preceding 10 ms; deletion removes the next 10 ms.

At the join, blend the first `F = rate/400` incoming samples in place with the unedited
continuation: `out[p+i] = (1-w)*before[p+i] + w*out[p+i]`, where `w = i/(F-1)`.
Each assignment rounds to Float32. The 2.5 ms linear crossfade removes no samples, so each
edit changes length by exactly 10 ms. An insertion's second join already has identical
continuation on both sides; its crossfade is a no-op. No original central scoring window is
edited. The generator fixes all sample positions and arithmetic for other implementations.

| Rate | Edit | Samples | Input PCM16 LE SHA-256 | Expected |
| --- | --- | --- | --- | --- |
| 8000 | +40 ms | 8480 | `8cc156f34b514ad4f15d11420771678c3e0f1e443281e8d374ef86e70839370b` | Detect |
| 8000 | -40 ms | 7840 | `cb31a159001ca9041fe6f1068bec30b77c3941ab467c39587616a4e140d8bdd5` | Detect |
| 8000 | +80 ms | 8800 | `4e1daed9aa5681e48fe244f491ba5cea969ed971a06126cc8557275f49b7f124` | Reject cap |
| 48000 | +40 ms | 50880 | `9df61e48608381ae9a50b8a297884397c72a18e603d3317926b0fb43d73b176a` | Detect |
| 48000 | -40 ms | 47040 | `02030079b20fcd511fec09037b09d4852ff30fdcd9ca30f86f920d945e95a939` | Detect |
| 48000 | +80 ms | 52800 | `62459596128b7f8e181c8ef1edd5a69039f37fdfa89a03e4f29e12d55aad7c14` | Reject cap |

Chosen per-slot drifts in milliseconds relative to slot zero plus `k*60`, under complete-path
selection with drift changes only at transitions, are:

| Rate | Edit | Selected drift list |
| --- | --- | --- |
| 8000 | +40 ms | `[0,0,0,10,10,10,20,20,30,30,30,33]` |
| 8000 | −40 ms | `[0,0,0,-7,-7,-7,-7,-7,-7,-7,-7,-7]` |
| 48000 | +40 ms | `[0,0,0,10,10,10,20,20,30,30,30,33]` |
| 48000 | −40 ms | `[0,0,0,-7,-7,-7,-7,-7,-7,-7,-7,-7]` |

The first slot offset remains 135 ms (1080/6480 samples). Both +80 ms inputs still reject;
no path or chosen drift list is returned. Their earlier rejected diagnostic alignment
`[0,0,10,20,30,40,50,60,60,70,70,80]` remains an invalid receipt control.
These are scoring starts, not physical edit counts: guards absorb some compression.

### Repeated-tone regression vectors (3a and 3b)

Canonical construction is `repeatedVector` in `expo/test/contracts/detection-vectors.ts`.
Vectors 3a-1 through 3a-3 use `createMarker("repeat-v2-8233")`, whose identity ends in seven
650 Hz slots and a 950 Hz slot. These model received PCM, rather than changing source emission:
start with the unchanged 1020 ms emission, then represent the repeated run [390,810) ms as
`0.2*sin(2π*650*(t−0.390))`, without intra-run amplitude notches. Delete [675,685) ms using
the same in-place 2.5 ms crossfade specified above. This is a 10 ms deletion inside the run.

After deletion, add a deterministic low-level 400 Hz render residual to sample `i`:
`0.002*(1+i/N)*sin(2π*400*i/rate)`, where `N` is the resulting sample count. Each assignment
rounds to Float32. Its increasing amplitude draws greedy confidence maxima backward through
the continuous run; legacy best-local selection rejects at both rates. Complete-path selection
detects with twelve zero drifts and minimum confidence above 0.99966. The 10 ms edit fits
within the scoring guards; a larger observable shift can be taken at an exit transition.

3a-2 replaces the later slot [800,860) ms with `0.2*sin(2π*1350*i/rate)` after adding the
residual. 3a-3 instead sets the edited slot [630,680) ms to zero. Both reject.
3a-4 is the final-slot alias counterexample: use the ordinary unedited emission for
`createMarker("wrong-each-slot")` and replace [810,870) ms with
`0.2*sin(2π*950*i/rate)`. It rejects: windows cannot slide within its final 650 Hz run.

Hash PCM16 LE bytes after all edits with the conversion above, then detect on decoded PCM16:

| Rate | Vector | Samples | Input PCM16 LE SHA-256 | Expected |
| --- | --- | --- | --- | --- |
| 8000 | 3a-1 (deleted) | 8080 | `dae143f33211f6fcf9617e2e4a99de5e00831e168adafa8a7b2d8fa041811a0b` | Detect, zero drift |
| 8000 | 3a-2 (wrong) | 8080 | `236233ac4ebee517862f86fda82eb5e9fe38b2168a42fd90df090ce837c0199f` | Reject |
| 8000 | 3a-3 (silent) | 8080 | `2ec6a4f8d98a1a85d5aa0bb29bd5f707c0dfd7102a78190761da7e8d19ba1531` | Reject |
| 8000 | 3a-4 (alias) | 8160 | `35770229b8db7382e249035c555d399962bcedf12cdcbd86d10367a1953a4b5e` | Reject |
| 48000 | 3a-1 (deleted) | 48480 | `67c9aaf0dc8265d63d8981ad26e800673597647ccd0bedbfe04596ee73cb9bb0` | Detect, zero drift |
| 48000 | 3a-2 (wrong) | 48480 | `4afd4bfc1fe255d655c19391cc60f18e8ec95c91f04fef7a9bb059c28f9a34ea` | Reject |
| 48000 | 3a-3 (silent) | 48480 | `2f7c12aecbb02fe41c280d382587dbd7f907cb433c08483b8bfef50fdd12673c` | Reject |
| 48000 | 3a-4 (alias) | 48960 | `b94c47f58ff2975a232ef00c4f2b0b13f41b92aae53c077cfeb102d04737d612` | Reject |

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
