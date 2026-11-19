import type { Room } from '@livekit/rtc-node';
import type { TransportSnapshot } from './transport.ts';

type RoomStatistics = Awaited<ReturnType<Room['getRtcStats']>>;

export function senderAudioStatistics(stats: Pick<RoomStatistics, 'publisherStats'>) {
  const rows = stats.publisherStats.flatMap(({ stats }) => stats.case === 'outboundRtp' &&
    stats.value.stream?.kind === 'audio' && stats.value.rtc?.id && stats.value.rtc.timestamp !== undefined &&
    stats.value.sent?.packetsSent !== undefined && stats.value.sent.bytesSent !== undefined ? [{
      streamID: stats.value.rtc.id, ssrc: stats.value.stream.ssrc, timestamp: Number(stats.value.rtc.timestamp),
      packetsSent: Number(stats.value.sent.packetsSent), bytesSent: Number(stats.value.sent.bytesSent),
    }] : []);
  return rows.length === 1 ? rows[0] : undefined;
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
