import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createMarker, emissionSamples } from '../../expo/src/testing/marker.ts';
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
