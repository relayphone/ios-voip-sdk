/** Counter snapshots are tied to observed PCM positions, never wall-clock guessed marker starts. */
export interface TransportSnapshot {
  sample: number;
  streamID: string;
  timestamp: number;
  packetsLost: number;
  concealedSamples: number;
  insertedSamples: number;
  removedSamples: number;
}
/** A whole overlapping counter interval is impaired when loss/concealment changes. */
export function cycleTransport(rows: readonly TransportSnapshot[] | undefined, start: number, end: number) {
  let lost = 0, concealed = 0, inserted = 0, removed = 0;
  if (!rows) return { state: 'unavailable' as const, lost, concealed, inserted, removed };
  let covered = rows.some(row => row.sample <= start) && rows.some(row => row.sample >= end);
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1]!, b = rows[i]!;
    if (b.sample <= start || a.sample >= end) continue;
    if (b.timestamp <= a.timestamp || b.streamID !== a.streamID || b.sample < a.sample || [b.concealedSamples - a.concealedSamples, b.insertedSamples - a.insertedSamples,
      b.removedSamples - a.removedSamples].some(delta => delta < 0)) covered = false;
    lost += Math.abs(b.packetsLost - a.packetsLost);
    concealed += Math.max(0, b.concealedSamples - a.concealedSamples);
    inserted += Math.max(0, b.insertedSamples - a.insertedSamples);
    removed += Math.max(0, b.removedSamples - a.removedSamples);
  }
  return { state: lost || concealed ? 'impaired' as const : covered ? 'clean' as const : 'unavailable' as const,
    lost, concealed, inserted, removed };
}
