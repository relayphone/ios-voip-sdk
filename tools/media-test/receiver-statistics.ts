import type { Room } from '@livekit/rtc-node';
import type { TransportSnapshot } from './transport.ts';
/** Uses the pinned SDK's public receiver statistics API, not signal-derived loss estimates. */
export async function receiverStatistics(room: Pick<Room, 'getRtcStats'>, sample: () => number): Promise<TransportSnapshot | null> {
  const stats = await room.getRtcStats();
  const row = [...stats.publisherStats, ...stats.subscriberStats].find(row => row.stats.case === 'inboundRtp' && row.stats.value.stream?.kind === 'audio')?.stats;
  if (row?.case !== 'inboundRtp') return null;
  const { received, inbound, rtc } = row.value;
  if (!rtc?.id || rtc.timestamp === undefined) return null;
  if (received?.packetsLost === undefined || inbound?.concealedSamples === undefined ||
      inbound.insertedSamplesForDeceleration === undefined || inbound.removedSamplesForAcceleration === undefined) return null;
  return { sample: sample(), packetsLost: Number(received.packetsLost), concealedSamples: Number(inbound.concealedSamples),
    insertedSamples: Number(inbound.insertedSamplesForDeceleration), removedSamples: Number(inbound.removedSamplesForAcceleration),
    streamID: rtc?.id ?? '', timestamp: Number(rtc?.timestamp ?? 0) };
}
