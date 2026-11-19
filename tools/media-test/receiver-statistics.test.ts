import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Room } from '@livekit/rtc-node';
import { receiverStatistics, senderAudioStatistics } from './receiver-statistics.ts';

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

test('sender counters keep retired and replacement audio streams separate', async () => {
  const row = (id: string, ssrc: number, packetsSent: bigint, kind = 'audio') => ({ stats: {
    case: 'outboundRtp', value: { stream: { kind, ssrc }, rtc: { id, timestamp: 10n },
      sent: { packetsSent, bytesSent: packetsSent * 20n } },
  } });
  const stats = await room('subscriberStats').getRtcStats();
  const inspect = (rows: unknown[]) => senderAudioStatistics({ ...stats,
    publisherStats: rows as typeof stats.publisherStats });
  assert.deepEqual(inspect([row('retired', 5, 30n), row('replacement', 6, 12n), row('camera', 7, 5n, 'video')]), [
    { streamID: 'retired', ssrc: 5, timestamp: 10, packetsSent: 30, bytesSent: 600 },
    { streamID: 'replacement', ssrc: 6, timestamp: 10, packetsSent: 12, bytesSent: 240 },
  ]);
  assert.deepEqual(inspect([]), []);
});
