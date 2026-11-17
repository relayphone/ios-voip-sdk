# Software-audio testing contract

`@relayphone/ios-voip-sdk/testing` defines one TypeScript interface for platform media test
adapters. It imports no LiveKit runtime. The platform adapter must observe the app's real call
media; a second test room cannot stand in for it. Calling `createMediaTest` without an adapter
rejects with `MediaTestError` code `unavailable`. Native media hooks and a far-end peer are
separate integrations.

Reference silence observations share the example's explicit 30-second result deadline.
The host exposes its remaining budget to the native observer; request latency is subtracted
before setting a native deadline. A scheduling gap retires an attempt as `unobserved` and
starts another full-duration attempt within that same budget. Observed leakage fails immediately,
including in an attempt containing a gap. No short suffix or expired attempt can pass.

Host observer ticks retain the 250 ms continuity limit. Native PCM uses elapsed monotonic time
minus accumulated delivered frame duration to measure uncovered time against 40 ms, while
also retaining the separate 250 ms callback liveness check. Receipts include each attempted
window's coverage, gaps and verdict, plus tick timestamps and scheduler lag. Deadline failures
retain available native checkpoints, including unfinished attempts, and identify a missing
final report explicitly.

The reference iOS adapter evaluates repeated emissions within its existing acquisition deadline.
It retains per-candidate confidences and receiver statistics, skips spans with loss or concealment,
and accepts the first complete clean cycle. Missing or stale receiver counters cannot prove clean
coverage. The 0.8 rule, amplitudes, signal, drift limits and all deadlines remain unchanged.

## Journey terminal phases

The iOS and Android journeys use the same terminal oracle. Immediately before each end,
begin a fresh shared-contract phase and require `expectAudio` in both directions. Retain
those receipts alongside the terminal evidence; audio must have been demonstrably live.

For a local end, the SDK's own published conversation state must reach `ended` with reason
`local` within the existing deadline. The native adapter's teardown receipt must show the tap
uninstalled, engine stopped, room disconnected and audio session released, on its acknowledged
monotonic clock. Reuse cleanup evidence, adding a field only when an observation is missing.

`MediaObservationClock` supplies one identity and origin to the native probe and teardown
recorder. Construct it once per adapter and pass it through `observationClock:`; callback
seconds and release milliseconds then refer to the same origin. A phase source can call
`MarkerAudioEngine.replaceMarker(frequencies:)` to start a new tones-v2 cycle in the actual
PCM source at a render boundary, while the cumulative generated sample count continues.

The native example retains `teardown.clockID`, `startedAtMs`, `observedAtMs` and an ordered
`observations` array with each release event's `atMs`. All four events must be measured in the
same attempt. Partial evidence is retained on failure; a producer's completion flag is insufficient.

Independently, the harness peer must observe the app's audio publication removed and its
participant disconnected within the deadline. After both events, retain the peer's receive
capture and check that no marker from any emitted phase arrives. Preserve event identities, track SIDs,
same-clock timestamps, observation endpoint and overflow counters; missing or truncated evidence
cannot pass. This lifecycle evidence proves that the app stopped sending. It does not establish
PCM silence when no track remains.

For the far-end leave variant, the peer leaves and the SDK must publish `ended` with reason
`remoteEnded`, followed by the same native release evidence within the existing deadlines.
There must be no stray reconnect. The departed peer cannot observe the app's subsequent departure;
retain the peer's leave evidence and the app's SDK state and teardown receipt for this variant.

Once teardown removes the tap, device silence correctly returns `unobserved`. It is never an
end-success oracle. Do not synthesize silent PCM or keep call audio active after deactivation.
All preceding phases retain the unchanged first-clean-cycle, silence-window and deadline rules.

## Installing the optional iOS hooks

The root Swift package contains the production SDK and resolves no LiveKit dependency.
For media tests, check out this repository and add `MediaTesting/` as a **local Swift package**.
SwiftPM cannot select a nested package using the repository URL alone. The nested package
depends on the root checkout by relative path and pins LiveKit Swift to 2.19.0:

```swift
dependencies: [
  .package(name: "VoIPMediaTesting", path: "../ios-voip-sdk/MediaTesting")
],
targets: [
  .testTarget(name: "AppMediaTests", dependencies: [
    .product(name: "VoIPMediaTesting", package: "VoIPMediaTesting")
  ])
]
```

Use that same local root checkout for any SDK products selected by the test consumer.
Import `VoIPMediaTesting` only under `#if DEBUG && os(iOS) && targetEnvironment(simulator)`;
the hooks are excluded from Release and physical-device builds.

CocoaPods continues to offer the optional `pod 'IosVoipSDK/MediaTesting'` subspec;
it is not part of the default installation. Expo's native reference example selects
`VoIPConversations/MediaTesting`, which vendors the same sources. Neither default CocoaPods
installation adds LiveKit. The `/testing` TypeScript contract is independent of both native
installation choices.

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

`expectSilence({ direction, for, within? })` separates the required continuous silent duration
(`for`) from the observation budget (`within`, default **30000 ms**). Both must be positive
integer milliseconds, at most 60000, with `within >= for`. The budget starts at the acknowledged
phase anchor, so another read in the same phase does not restart it. A duration above 30000 ms
requires an explicit larger `within`.

**Migration:** callers that supplied only `for` now get windowed retries within 30 seconds.
Pass `within: for` for the previous strict-from-anchor behavior. Adapters receive `durationMs`
for the required duration and `withinMs` for the phase budget; they must retain every attempt,
including gapped, unfinished and leaking intervals, rather than returning only the final suffix.

Silence receipts require an ordered, nonoverlapping `silenceWindows` array. Every window uses
the receipt's observer clock and contains the `MediaCapture` fields (timestamps, original PCM
counts/levels, overflow and independent monitoring evidence), plus `coveredMs`, a `gaps` array
of `{ startedAtMs, endedAtMs }`, and a `silent`, `unobserved` or `leak` verdict. Coverage cannot
exceed the interval minus its reported gaps. Every attempt must lie inside
`[phase anchor, phase anchor + within]`. The receipt's top-level capture fields describe the
first qualifying silent window, or the final attempt when none qualified.

The validator checks all attempts for leakage before accepting the first continuous window
covering at least `for`. RMS/peak limits remain **0.003/0.01**, and the observer gap limit remains
**40 ms** with no overflow. Missing PCM alone proves nothing. A leak in any attempt fails with
`audio_leak`, even when that attempt was gapped or a later window is clean. No qualifying window
within the budget fails with `unobserved`. These errors retain the validated history in
`MediaTestError.receipt`; a timed-out adapter may have no receipt, which is not silence evidence.
The arrays, gaps and measurements returned by validation are immutable copies.

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
the audio deadline or remaining silence budget. Silence read waits conservatively subtract the
entire phase-acknowledgement round trip. These delivery bounds do not extend the receipt's phase deadline.

## Synthetic capture configuration

The media test kit keeps **AGC enabled, with AEC and noise suppression disabled** for
synthetic capture on both platforms: Debug iOS Simulator and Android `emulatorTest` builds only.
The iOS fixture explicitly requests software processing and verifies active AGC plus inactive
AEC/NS, including their requested state, in its receipt. Production capture defaults are unchanged.

The kit verifies audio flow each way, mute, hold and reconnect gates, and software timing.
Synthetic capture has no acoustic path from speaker to microphone, so echo cancellation has
no echo to cancel and can suppress near-end tones shared with the far-end render. Noise
suppression can remove non-speech tones too. Noise suppression and echo cancellation fidelity
remain device and speech QA. Every slot's confidence, margin and chosen timing is still
required, with unchanged complete-marker thresholds, deadlines and gates.

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

The native feasibility receipt includes a bounded processing timeline with requested and software-active AEC, NS and AGC values. Unknown requests stay explicit. Monotonic read-start and read-completion timestamps cover capture-options application, engine transitions, the first three source-render/output callbacks after each graph connection, acquisition samples and the exact `checkRead` snapshot used by the processing gate. A dropped-entry count reports diagnostic overflow. Initial callback snapshots synchronously query the shared WebRTC processing state; their measured read duration exposes the diagnostic cost. These observations do not acknowledge application or relax the processing gate.

When the native check fails, the host saves its receipt and raw PCM and reports that native phase directly before evaluating subsequent marker gates.

Native `MediaAudioProbe.snapshot(_:)` reads bounded PCM, observation counters and
`MediaPCMCallbackEvidence` together under one lock. Each callback row preserves its
shared-clock entry time in seconds, per-channel sample offset and frame count, actual
rate/channel count, original energy across all channels and maximum absolute sample.
History is bounded to 8192 rows per stage and probe window; `droppedFrames` reports
overflow, which consumers must reject. Beginning a window or retiring a gapped native
silence attempt resets the callback history alongside PCM and counters. The example
command mailbox includes these rows for host window selection; rows never fill missing
intervals or change the shared-contract coverage, RMS or peak thresholds.

The example's success, failure and journey receipts also include `startup`, a
`MediaStartupEvidence.Receipt` with the same observation clock identity. It retains the
first `prepareEntered`, `roomConnectRequested`, connection outcome, `captureOptionsApplied`,
`prepareCompleted`, `activationEntered`, `activationEnqueued`, `activationHandlerEntered`
and `engineAvailabilityObserved` events. Preparation completion is recorded after the
statistics await and successful return from preparation. Activation entry and the stream's
actual enqueue result (`enqueued`, `dropped` or `terminated`) are separate from handler entry.
The handler may run before the post-yield enqueue receipt is recorded; enqueue never implies
consumption. Connection failure contains only the error type
name; engine availability is read after the activation attempt as `running` or `unavailable`.
`tapInstalled` and `firstCallback` are observed independently for decoded and output PCM.
At most thirteen rows are retained across probe-window resets. Taking a failure snapshot never
fills a missing stage or infers a callback. Startup diagnostics do not alter acquisition
deadlines or media gates.

The same startup receipt retains the latest observed SDK `audioActivated` and
`audioDeactivated` timestamps, without growing the timeline or filling absent events. Failure
and journey snapshots include `sdkAudioState`, with the shared clock identity, observation
time, SDK `isAudioActive` value, call status and typed call failure when present. An unavailable
client leaves the optional SDK flag absent and an unavailable call remains explicit; neither becomes inactive.
These are SDK observations, not a second measurement of the platform audio session.
Ended calls leave the SDK's live call list, so the example separately retains the matching
SDK ended event. `callSource` and `callObservedAtMs` distinguish that earlier terminal
observation from a current live-call snapshot; unrelated calls never supply the status.

Host failure diagnostics distinguish unobserved prepare completion, activation never delivered,
activation enqueue failure, an enqueued command not consumed, and an activation attempt with
an unavailable engine. Missing engine outcome stays unobserved. Diagnostics neither qualify
audio nor override a failed media result; older receipts without the new boundaries retain
their uncertainty.

## Synthetic video source and calibration receipts

The optional `MediaTesting` package supplies a coarse luma marker with fixture, direction,
epoch, source counter, source-clock timestamp and an integrity digest. `VideoMarker` generates
and decodes actual pixel planes, including padded row strides. `VideoSourceLedger` preserves
up to 4096 original identities and freezes its final counter atomically at off/end. It rejects
further generation and never evicts old privacy evidence. New phases use new epochs.
Capture a typed source `anchor()` before a new measurement phase; its counter fence excludes
the dimension seed even if both share a rounded timestamp. Skipped ticks and rejected buffer
submissions remain explicit. Fixed-grid counters advance under load without catch-up bursts.

`SyntheticVideoCapture` exists only in DEBUG iOS simulator builds. It creates a LiveKit buffer
track with camera semantics, seeds its dimensions before publication, and uses a four-buffer
allocation ceiling. It opens no camera and has no camera fallback. The application owns
publication, hold/mute, unpublish and shutdown. Keep generating during hold and suppress the
ordinary publication gate; call `stop()` at the actual applied off/end boundary. Stop is
serialized with generation before any asynchronous media teardown. Use `try await stop()`;
it freezes the final counter/epoch, cancels any pending pacing sleep and joins pacing before
returning the ledger. Separately stop/unpublish the track. The ledger explicitly encodes the
final counter (null if none), final epoch, pacing completion and rejected post-stop captures.
Before stop, use `generated.last?.counter` for the latest generated counter. Ordinary builds expose only
`MediaVideoSupport.canCapture == false`, without the capture implementation or LiveKit import.

Retain `SyntheticVideoReceiver` while collecting decoded pixels, including the drain interval.
Its `VideoCalibration` recorder preserves corrupt, foreign and repeated arrivals. Only unique
ledger-matched frames count toward complete-window fps. First observed fresh-frame latency is
a same-clock upper bound on first delivery (attachment can miss an earlier frame); no
cross-process clock subtraction is allowed. Reports include the maximum on-phase gap,
generation-to-arrival residence, post-stop pre-boundary drain, every post-boundary counter,
process CPU/peak RSS samples and the decoder callback high-water mark. Internal encoder queues
are not directly observed. All resource fields are process-wide; sampling failure is nil.
Evidence overflow or an in-progress callback makes a report incomplete, never successful.
Each of at most 4096 callback rows retains geometry, original buffer type, media/RTP timestamps,
full-plane extrema/completeness and at most sixteen sample bytes per Y/U/V plane. Callback entry
uses the observation clock; media timestamps are reported without cross-clock subtraction.
An undecodable image is content-free only when all active Y samples are within ±2 of a common
value, retained U/V planes satisfy the same test, and geometry differs from both source profiles
(160×120 and 320×240). Padding is excluded. Content-free callbacks remain counted and reported,
but never contribute to first-frame, fps, continuity, residence or source drain. Their transport
origin is not inferred. Partial planes, source-sized uniform images and nonuniform undecodable
images remain ambiguous. The recorder keeps at most 96 KiB of one failing luma plane for diagnosis.
Ambiguous post-stop callbacks increment `ambiguousBoundaryFrames` and leave `preBoundaryDrainUs` nil;
zero recognized post-boundary counters cannot turn that ambiguity into a privacy pass.

Off/end requires zero post-boundary generated identities reaching the receiver, bounded
arrival of pre-boundary frames within a separately calibrated drain budget, and lifecycle
receipts for source stop, publication mute/unpublish, no republish and continued receiver
health. Corrupt or unmatched pixels cannot establish boundary order. An observer heartbeat
is a recorder scheduling observation, not proof by itself that a remote decoder stayed
attached. Keep actual track/room lifecycle evidence alongside it. Do not equate observer
removal with silence or discard pre-boundary arrivals after off. No numeric budget is frozen
by these types.

`VideoCaptureTests.roomCodecCalibration` is an opt-in same-process, two-room VP8 calibration
smoke. Supply a private JSON file in the simulator with `url`, `publisherToken`,
`subscriberToken`, `width` and `height`; set the test-process environment variable
`VIDEO_CALIBRATION_FIXTURE` to that file's path. Obtain the tokens from the existing fixture
server's `credentials` function for two identities in one room. Never print or retain the
credentials in test artifacts. The test emits one bounded `VIDEO_CALIBRATION` JSON line,
keeps the receiver attached during the two-second observation after unpublish, and closes
both rooms. The default profile is 320×240 at 10 fps, one VP8 layer; 160×120 is the fallback.
Both are experiment settings, not throughput claims. The bounded smoke supplies measurement
plumbing, not a substitute for repeated calibration across runner allocations and an
independent holdout. Retain timeout/invalid trials as such; never widen the existing audio,
result-acquisition or workflow deadlines to make a video measurement complete.


### Qualified iOS synthetic video profile

Use 160×120 at 10 fps, one VP8 layer. The portable marker layout and decode tolerance are
shared by Swift and the host peer. The iOS gates are frozen from the original training
observations and five complete holdout trials, including the two separately allocated
completion trials. 320×240 remains diagnostic; Android requires separate qualification.

| Gate | Frozen value |
| --- | --- |
| First independently decoded frame, conservative bound | 3000 ms |
| Maximum unique-frame inter-arrival/final on-phase gap | 1600 ms |
| Minimum unique fps in every complete one-second window | 3 |
| Identified pre-boundary source drain after off/end | 800 ms |

| Complete 160×120 trial | First-frame ms | Maximum gap ms | Minimum fps | Identified source drain ms |
| --- | --- | --- | --- | --- |
| first/off, allocation 30 | 340.437 | 165.242 | 8 | No source arrival after stop |
| re-enable/end, allocation 31 | 246.938 | 157.624 | 8 | No source arrival after stop |
| first/end, allocation 31 | 313.026 | 158.305 | 8 | 17.561 |
| re-enable/off, allocation 32 | 811.968 | 129.373 | 8 | No source arrival after stop |
| first/end, allocation 33 | 829.351 | 138.624 | 9 | 11.115 |

The candidate snapshot SHA-256 is
`e2f0fe87c7d3da92d09b4774fdea5128fda207a63a85fe35b083e10776ad8eaf`.
The rule was rounded-up 100 ms headroom covering the larger of twice nearest-rank P95 and
1.25 times the training maximum; the fps floor is the training minimum. Candidates were
unchanged throughout [the initial holdout](https://github.com/relayphone/ios-voip-sdk/actions/runs/44058115723)
and [the completion trials](https://github.com/relayphone/ios-voip-sdk/actions/runs/44066404246).
The initial run's setup failure and four not-run cases are retained outside completion quota.

These measurements qualify the standalone simulator source/codec profile with audio active.
They do not establish a combined journey's total duration, a physical camera, Android,
external-route audibility, or energy consumption. The existing acquisition/process deadlines
remain unchanged; separate bounded invocations must reuse the build when needed.

The example's existing native journey mailbox accepts `video` with `enabled` and
`source: 'app' | 'server'`. It uses the public SDK video API after session, call and current
phase validation; the host serializes `source` as `videoSource` in the native command.
Video commands are rejected after terminal arming. A command reply is
an acknowledgement, not a confirmed event. Its video evidence separately retains actual
SDK `videoChanged` callbacks, source and native observation time, plus the terminal event
after the call leaves the SDK snapshot. An initial connected snapshot has its own
`readySnapshot` kind and never invents a change event. The optional fixture `initialVideo`
flag configures the incoming call's initial state; omitted input preserves audio-only setup.

`readNativeVideoEvidence` reads that evidence from an already validated native mailbox
reply, enforcing the original clock, timestamp ordering, event origin and 256-row bound.
Overflow fails rather than evicting the initial anchor. An absent live call remains nil;
the event history survives. These controls do not publish video or establish decoded-media
success. Independent source/receiver receipts and all media gates are still required.

Setup and rejected-command receipts retain only an allowlisted operation/category and a
numeric error code. Raw error domains, descriptions, URLs and userInfo are excluded. The
host preserves those sanitized fields when retiring a failed or uncertain mailbox, so a
setup failure can identify itself without exposing fixture credentials.

For DEBUG simulator builds, the journey fixture can additionally supply a `syntheticVideo`
UUID. This opts into an app-owned 160×120/10 fps buffer source on the existing audio Room.
Confirmed SDK video state selects ordinary publication; audio-only setup stays off. Initial
video waits for the existing connected call, audio activation and Room readiness. Same-value
updates preserve the source. Hold mutes the publication while generation keeps ticking;
resume joins the held source and starts a new epoch/publication. Upgrading while already
held starts only the upstream source. Off/end freezes the source ledger and joins pacing
before unpublish or disconnect. Setup and publication errors retain sanitized video codes.

The additive `syntheticVideo` reply retains each epoch's seed fence, original source ledger,
publication SID and actual publication actions, plus independently decoded remote callback
observations from the expected `far-end` participant. Remote renderers remain attached
through unpublish/EOS and Room teardown until explicit mailbox close. Bounded heartbeats,
Room publication changes and replacement/late-subscription invalidation remain visible.
`VideoCalibration.observation()` exports receiver-only evidence on its own clock; it does
not infer source identity, synchronization or gate verdicts. Host source binding, transition
clock brackets, permission controls and complete SDK-driven journey assertions are still
required before these receipts establish decoded-media success.

`readNativeSyntheticVideo` validates the native synthetic receipts from a validated mailbox
reply: clock/fixture identity, bounded source epochs and receiver rows, original seed fences,
producer boundaries, full-plane provenance and lifecycle ordering. Source failures preserve
only sanitized codes. `bindNativeVideoSource` requires the independently subscribed native
participant and publication SID; an unpublished held-source epoch cannot supply that binding.
`bindNativeVideoReceiver` selects the actual reverse publication and checks decoded markers
against the far-end source ledger. Duplicate, content-free and ambiguous callbacks remain
present. Binding does not establish frame-rate, privacy, observation-health or journey passes.

`sampleNativeVideoClock` requests a fresh snapshot through the existing mailbox with the
caller's absolute deadline and cancellation signal. It retains host send/receive times around
the original native clock sample. `hostVideoBoundary` preserves the resulting uncertainty;
remote source timestamps remain on their own clock. Diagnostics retain native media/RTP
timestamps without using them as event or latency anchors. Unsafe numeric evidence fails.

The host `VideoPeer` uses the existing fixture Room and independent decoded `VideoStream`.
Its metadata retention is bounded at 4096 rows per series, with overflow invalidating the
observation. It retains no continuous video. The native stream/encoder's internal queues are
not directly measured. Read continuously; stalled observation coverage, stream failure,
wrong participant/publication/epoch and missing lifecycle evidence cannot qualify silence.
`assessVideo` consumes original source ledgers and confirmed-event anchors from its caller;
source or publication acknowledgements alone are never decoded-frame evidence. Native clock
samples must retain host send/receive brackets, refreshed at transitions; the full uncertainty
contributes to conservative first-frame/drain bounds. Media/RTP timestamps are diagnostic only.
The terminal evaluator receives the original confirmed event time separately from producer stop;
it reports their lag and rejects source content generated after that event. Source ledgers also
retain their participant/publication binding. Disposing or replacing an observer cannot qualify
a negative interval; first validate fresh source content and a complete on-window before off.
The original phase counter fence is mandatory: the dimension seed never supplies first-frame
or complete-window rate evidence, even when its timestamp matches the enable event.

For Android evaluation, pass `platform: 'android'` and an explicit `gates` object to
`assessVideo`. `VideoGateLimits` requires `firstMs`, `gapMs`, `minimumFPS`, `drainMs` and
`terminalCoverageMs`. All limits must be finite and positive; the fps floor is a whole
number at most 10, and terminal coverage must cover the drain budget. Missing Android
limits fail rather than borrowing iOS values. Omitted platform input (or explicit `ios`)
keeps the frozen iOS defaults above, including 800 ms terminal coverage. Explicit limits
apply only to that invocation. Android values require their own measurement and review;
the controls' synthetic values are not qualified candidates.

`measureVideo(receipt, source, options)` exports the same raw, conservative first-frame,
maximum-gap, fixed one-second unique-frame windows and terminal measurements without gate
verdicts. It retains integrity, producer/lifecycle and clock checks. Use
`identifiedPostBoundaryArrivals` and nullable `identifiedDrainMs` for calibration: no
identified arrival is distinct from a measured zero drain. `terminalObservedMs` is the
coverage after the latest possible confirmed boundary, so clock uncertainty is preserved.
The legacy `drainMs` field remains zero when a terminal receipt has no identified arrivals.
Neither API changes the 160×120/10 fps source profile, marker/classifier, original counter
fence, privacy checks or observer heartbeat limit. Increasing a platform drain/coverage
budget cannot make an unhealthy observer qualify.
