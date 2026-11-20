import type { Room } from '@livekit/rtc-node';
import type { TransportSnapshot } from './transport.ts';

type RoomStatistics = Awaited<ReturnType<Room['getRtcStats']>>;

export function senderAudioStatistics(stats: Pick<RoomStatistics, 'publisherStats'>) {
  return stats.publisherStats.flatMap(({ stats }) => {
    if (stats.case !== 'outboundRtp') return [];
    const { rtc, stream, sent } = stats.value;
    if (stream?.kind !== 'audio' || !rtc?.id || rtc.timestamp === undefined ||
        sent?.packetsSent === undefined || sent.bytesSent === undefined) return [];
    return [{ streamID: rtc.id, ssrc: stream.ssrc, timestamp: Number(rtc.timestamp),
      packetsSent: Number(sent.packetsSent), bytesSent: Number(sent.bytesSent) }];
  });
}
/** Uses the pinned SDK's public receiver statistics API, not signal-derived loss estimates. */
export async function receiverStatistics(room: Pick<Room, 'getRtcStats'>, sample: () => number,
  observe?: (stats: RoomStatistics) => void): Promise<TransportSnapshot | null> {
  const stats = await room.getRtcStats();
  observe?.(stats);
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
