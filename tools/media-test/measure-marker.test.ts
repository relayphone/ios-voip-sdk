import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createMarker, emissionSamples, markerSamples } from '../../expo/src/testing/marker.ts';
import { markerReport } from './marker-evidence.ts';
import { measureMarkerAsync } from './measure-marker.ts';

test('owned analysis worker retains slot scores while the packet clock keeps running', async () => {
  const marker = createMarker('worker-clock'), rate = 48_000;
  let ticks = 0;
  const clock = setInterval(() => ticks++, 5);
  try {
    const result = await measureMarkerAsync({ sampleRate: rate, channels: [Array.from(emissionSamples(marker, rate, rate * 2))], formatChanged: false }, marker);
    assert.ok(ticks >= 2);
    assert.ok(result.complete && result.postRollObserved);
    assert.deepEqual(result.channels[0]!.slots.map(slot => slot.driftMs), Array(12).fill(0));
  } finally { clearInterval(clock); }
});
test('a failed analysis worker cannot fabricate marker or silence evidence', async () => {
  await assert.rejects(measureMarkerAsync({ sampleRate: 48_000, channels: [], formatChanged: false }, createMarker('missing')));
});

test('only host poll coverage can use the nearest edge reports and the summary shows both bounds', async () => {
  const marker = createMarker('worker-edges'), sampleRate = 48_000;
  const samples = new Float32Array(sampleRate);
  samples.set(markerSamples(marker, sampleRate, 34_560));
  const capture = { sampleRate, channels: [Array.from(samples)], formatChanged: false,
    transport: [2880, 40_000].map((sample, timestamp) => ({
      sample, timestamp, streamID: 'uplink', packetsLost: 0, concealedSamples: 0, insertedSamples: 0, removedSamples: 0,
    })) };
  const strict = await measureMarkerAsync(capture, marker);
  assert.equal(strict.clean, false);
  assert.match(markerReport('Host uplink', strict), /Cycle 0–34560 samples: unavailable/);
  assert.match(markerReport('Host uplink', strict),
    /Required counter bounds: 0–42720 samples\. First counter: 2880\. Last counter: 40000\./);
  const relaxed = await measureMarkerAsync(capture, marker, 'host-poll');
  assert.ok(relaxed.clean && relaxed.complete && relaxed.postRollObserved);
});
