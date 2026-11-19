import assert from 'node:assert/strict';
import { test } from 'node:test';
import { bestFixedGridMarkerDiagnostic, createMarker, markerSamples, emissionSamples, markerSlotConfidences } from '../../expo/src/testing/marker.ts';
import { measureMarker } from './marker-evidence.ts';
import { detectionVector, pcm16LE, decodedPCM16, insertedDrifts, deletedDrifts } from '../../expo/test/contracts/detection-vectors.ts';

const marker = createMarker('confidence-controls:fromDevice');
const rate = 48_000;
const pcm = () => markerSamples(marker, rate, rate * 0.72);
const measure = (samples: Float32Array) => measureMarker({ sampleRate: rate,
  channels: [Array.from(samples)], formatChanged: false }, marker);

test('per-slot margins accompany a complete marker through gain and int16 quantization', () => {
  const evidence = measure(pcm().map(value => Math.round(value * 0.3 * 32767) / 32768));
  assert.equal(evidence.complete, true);
  assert.equal(evidence.channels[0]!.slots.length, 12);
  assert.ok(evidence.channels[0]!.slots.every(slot => slot.margin > 0.19));
});

test('one corrupted slot fails even when the other eleven and total energy are strong', () => {
  const samples = pcm();
  for (let i = 10 * 2880; i < 11 * 2880; i++) samples[i] = 0.2 * Math.sin(2 * Math.PI * 2300 * i / rate);
  const evidence = measure(samples);
  assert.equal(evidence.complete, false);
  assert.equal(evidence.channels[0]!.slots.length, 12);
  assert.ok(evidence.channels[0]!.slots[10]!.margin < 0);
});

test('cached fixed-grid diagnostics match the full score at fractional millisecond sample offsets', () => {
  const sampleRate = 44_100;
  const samples = new Float32Array(sampleRate * 0.76);
  samples.set(markerSamples(marker, sampleRate, sampleRate * 0.72), 308);
  samples.fill(0, sampleRate * 0.66);
  const offsets = Array.from({ length: 41 }, (_, ms) => Math.floor(ms * sampleRate / 1000));
  const rows = offsets.map(offset => ({ offset, scores: markerSlotConfidences(samples, sampleRate, marker, offset) }));
  const best = rows.reduce((left, right) => Math.min(...right.scores) > Math.min(...left.scores) ? right : left);
  assert.deepEqual(bestFixedGridMarkerDiagnostic(samples, sampleRate, marker), best);
});

test('a sub-threshold slot, attenuation below the energy floor and truncation cannot pass', () => {
  const samples = pcm();
  const frequency = marker.frequencies[10]!;
  for (let i = 10 * 2880; i < 11 * 2880; i++) samples[i] =
    0.2 * Math.sin(2 * Math.PI * frequency * i / rate) + 0.12 * Math.sin(2 * Math.PI * 2300 * i / rate);
  assert.equal(measure(samples).complete, false);
  assert.equal(measure(pcm().map(value => value * 0.01)).complete, false);
  assert.equal(measure(pcm().subarray(0, -1)).complete, false);
});

test('wrong identity and a silent second channel cannot be hidden by correct first-channel energy', () => {
  const samples = Array.from(pcm());
  assert.equal(measureMarker({ sampleRate: rate, channels: [samples], formatChanged: false },
    createMarker('wrong-phase')).complete, false);
  assert.equal(measureMarker({ sampleRate: rate, channels: [samples, samples.map(() => 0)],
    formatChanged: false }, marker).complete, false);
});

test('fixture coverage includes post-roll without changing the marker detector', () => {
  const full = measure(emissionSamples(marker, rate, rate * 1.2));
  assert.equal(full.complete, true);
  assert.equal(full.postRollObserved, true);
  const truncated = measure(emissionSamples(marker, rate, rate * 0.97));
  assert.equal(truncated.complete, true);
  assert.equal(truncated.postRollObserved, false);
});

test('fixture scores and margins follow the published chosen starts in either drift direction', () => {
  for (const change of [40, -40] as const) {
    const pcm = decodedPCM16(pcm16LE(detectionVector(48000, change)));
    const result = measureMarker({ sampleRate: 48000, channels: [Array.from(pcm)], formatChanged: false }, createMarker('parity-v2'));
    assert.ok(result.complete);
    assert.equal(result.channels[0]!.alignment, 'elastic');
    assert.deepEqual(result.channels[0]!.slots.map(slot => slot.driftMs), (change === 40 ? insertedDrifts : deletedDrifts)[48000]);
    assert.ok(result.channels[0]!.slots.every(slot => slot.confidence >= 0.8 && slot.margin >= 0));
  }
});

test('first clean cycle skips a complete cycle carrying receiver loss or concealment', () => {
  for (const impairment of ['packetsLost', 'concealedSamples'] as const) {
    const samples = emissionSamples(marker, rate, rate * 3);
    const transport = Array.from({ length: 7 }, (_, i) => ({ sample: i * rate / 2, timestamp: i,
      streamID: 'receiver', packetsLost: 0, concealedSamples: 0, insertedSamples: 0, removedSamples: 0,
      [impairment]: i > 0 ? 1 : 0 }));
    const result = measureMarker({ sampleRate: rate, channels: [Array.from(samples)], formatChanged: false, transport }, marker);
    assert.ok(result.clean && result.complete && result.postRollObserved);
    assert.equal(result.channels[0]!.cycles[0]!.transport.state, 'impaired');
    assert.ok(!result.channels[0]!.cycles[0]!.accepted);
    assert.ok(result.channels[0]!.offsetSamples >= rate * 1.02);
  }
});

test('retaining the full duplex window preserves a clean cycle beyond a truncated uplink', () => {
  const samples = new Float32Array(4 * rate);
  const leadIn = 0.18 * rate;
  samples.set(emissionSamples(marker, rate, samples.length - leadIn), leadIn);
  const transport = Array.from({ length: 41 }, (_, index) => ({
    sample: index * rate / 10, timestamp: index, streamID: 'receiver',
    packetsLost: 0, concealedSamples: index >= 13 ? 480 : 0, insertedSamples: 0, removedSamples: 0,
  }));
  const observe = (pcm: Float32Array) => measureMarker({
    sampleRate: rate, channels: [Array.from(pcm)], formatChanged: false, transport,
  }, marker, 'host-poll');
  const truncated = observe(samples.subarray(0, 3 * rate));
  const full = observe(samples);
  assert.equal(truncated.clean, false);
  assert.equal(full.clean, true);
  assert.ok(full.channels[0]!.cycles.filter(cycle => cycle.complete && cycle.transport.concealed === 480).length >= 2);
  const accepted = full.channels[0]!.cycles.find(cycle => cycle.accepted);
  assert.ok(accepted && accepted.transport.requiredEndSample > 3 * rate);
});

test('a rejected first cycle does not hide a later unchanged clean emission', () => {
  const samples = emissionSamples(marker, rate, rate * 3);
  samples.fill(0, rate * 0.75, rate * 0.81);
  const transport = [0, 3].map(second => ({ sample: second * rate, timestamp: second, streamID: 'receiver',
    packetsLost: 0, concealedSamples: 0, insertedSamples: 0, removedSamples: 0 }));
  const result = measureMarker({ sampleRate: rate, channels: [Array.from(samples)], formatChanged: false, transport }, marker);
  assert.ok(result.clean);
  assert.ok(result.channels[0]!.cycles.some(cycle => !cycle.complete));
  assert.ok(result.channels[0]!.offsetSamples >= rate * 1.02);
});
test('missing counter coverage and impairment in every cycle cannot qualify as clean', () => {
  const samples = emissionSamples(marker, rate, rate * 3);
  for (const transport of [[], [0, 3].map(second => ({ sample: second * rate, timestamp: second, streamID: 'receiver',
    packetsLost: second, concealedSamples: second, insertedSamples: 0, removedSamples: 0 }))]) {
    const result = measureMarker({ sampleRate: rate, channels: [Array.from(samples)], formatChanged: false, transport }, marker);
    assert.equal(result.clean, false); assert.equal(result.complete, false);
  }
});

test('stale receiver reports cannot certify a later cycle as clean', () => {
  const samples = emissionSamples(marker, rate, rate * 3);
  const transport = [0, 3].map(second => ({ sample: second * rate, timestamp: 1, streamID: 'receiver',
    packetsLost: 0, concealedSamples: 0, insertedSamples: 0, removedSamples: 0 }));
  const result = measureMarker({ sampleRate: rate, channels: [Array.from(samples)], formatChanged: false, transport }, marker);
  assert.equal(result.clean, false);
});
