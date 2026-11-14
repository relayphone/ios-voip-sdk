import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Room } from '@livekit/rtc-node';
import { receiverStatistics } from './receiver-statistics.ts';

function room(side: 'publisherStats' | 'subscriberStats', incomplete = false): Pick<Room, 'getRtcStats'> {
  return { async getRtcStats() {
    // Fake the SDK's response data; no native room or media is fabricated by these counters.
    return { publisherStats: [], subscriberStats: [], [side]: [{ stats: { case: 'inboundRtp', value: {
      stream: { kind: 'audio' }, rtc: { id: 'audio', timestamp: 10n },
      received: { packetsLost: 2n }, inbound: { concealedSamples: incomplete ? undefined : 480n,
        insertedSamplesForDeceleration: 960n, removedSamplesForAcceleration: 240n },
    } } }] } as unknown as Awaited<ReturnType<Room['getRtcStats']>>;
  } };
}
test('both unified and separate subscriber transports retain receiver counters', async () => {
  for (const side of ['publisherStats', 'subscriberStats'] as const) assert.deepEqual(
    await receiverStatistics(room(side), () => 48000), { sample: 48000, streamID: 'audio', timestamp: 10,
      packetsLost: 2, concealedSamples: 480, insertedSamples: 960, removedSamples: 240 });
});
test('missing receiver counters are unavailable, never invented zero loss', async () => {
  assert.equal(await receiverStatistics(room('publisherStats', true), () => 48000), null);
});
