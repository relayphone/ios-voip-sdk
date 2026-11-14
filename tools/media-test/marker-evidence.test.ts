import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createMarker, markerSamples, emissionSamples } from '../../expo/src/testing/marker.ts';
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
    assert.deepEqual(result.channels[0]!.slots.map(slot => slot.driftMs), change === 40 ? insertedDrifts : deletedDrifts);
    assert.ok(result.channels[0]!.slots.every(slot => slot.confidence >= 0.8 && slot.margin >= 0));
  }
});
