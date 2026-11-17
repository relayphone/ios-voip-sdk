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
export const HOST_RECEIVER_STATS_POLL_MS = 100;

/** A whole overlapping counter interval is impaired when loss/concealment changes. */
export function cycleTransport(rows: readonly TransportSnapshot[] | undefined, start: number, end: number,
  edgeToleranceSamples = 0) {
  let lost = 0, concealed = 0, inserted = 0, removed = 0;
  const first = rows?.[0]?.sample ?? null, last = rows?.at(-1)?.sample ?? null;
  const bounds = { requiredStartSample: start, requiredEndSample: end, firstCounterSample: first, lastCounterSample: last };
  if (!rows || first === null || last === null)
    return { state: 'unavailable' as const, lost, concealed, inserted, removed, ...bounds };
  // Only the outside edges of the receipt can use a nearest sample. A real interval must overlap the cycle.
  let covered = first < last && first < end && last > start &&
    first - start <= edgeToleranceSamples && end - last <= edgeToleranceSamples;
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
    lost, concealed, inserted, removed, ...bounds };
}
