import { bestFixedGridMarkerDiagnostic, markerCandidates, markerSlotConfidences } from '../../expo/src/testing/marker.ts';
import { cycleTransport, HOST_RECEIVER_STATS_POLL_MS, type TransportSnapshot } from './transport.ts';
import type { MediaMarker } from '../../expo/src/testing/types.ts';

export interface PCMCapture {
  readonly sampleRate: number;
  readonly channels: readonly (readonly number[])[];
  readonly formatChanged: boolean;
  readonly transport?: readonly TransportSnapshot[];
}
export type CounterCoverage = 'strict' | 'host-poll';

/** Per-slot margins are diagnostics; only the unchanged complete-marker detector can pass. */
export function measureMarker(capture: PCMCapture, marker: MediaMarker, counterCoverage: CounterCoverage = 'strict') {
  if (capture.formatChanged || capture.channels.length === 0 || capture.channels.length > 8 ||
      !capture.channels.every(channel => channel.length === capture.channels[0]!.length &&
        channel.length <= capture.sampleRate * 10)) throw new Error('Invalid or discontinuous PCM capture');
  if (capture.transport?.some(row => ![row.sample, row.timestamp, row.packetsLost, row.concealedSamples,
    row.insertedSamples, row.removedSamples].every(Number.isFinite) || !Number.isSafeInteger(row.sample) || row.sample < 0 ||
    [row.concealedSamples, row.insertedSamples, row.removedSamples].some(value => !Number.isSafeInteger(value) || value < 0)))
    throw new Error('Invalid receiver statistics');
  const edgeTolerance = counterCoverage === 'host-poll'
    ? Math.floor(capture.sampleRate * HOST_RECEIVER_STATS_POLL_MS / 1000) : 0;
  const channels = capture.channels.map(samples => {
    const pcm = Float32Array.from(samples);
    let detection: import('../../expo/src/testing/types.ts').MarkerDetection | null = null;
    const cycles = [];
    let clean = false;
    for (const candidate of markerCandidates(pcm, capture.sampleRate, marker)) {
      const found = candidate.detection;
      const end = (found?.slotStarts.at(-1) ?? candidate.anchor + 11 * capture.sampleRate * marker.slotMs / 1000)! + capture.sampleRate * marker.slotMs / 1000;
      const postRoll = pcm.length - end >= capture.sampleRate * 0.17;
      const transport = cycleTransport(capture.transport, Math.max(0, candidate.anchor - capture.sampleRate * 0.15),
        end + capture.sampleRate * 0.17, edgeTolerance);
      const scores = markerSlotConfidences(pcm, capture.sampleRate, marker, candidate.anchor, found?.slotStarts);
      const accepted = found !== null && postRoll && transport.state === 'clean';
      cycles.push({ syncQualified: candidate.syncQualified, anchorSamples: candidate.anchor, markerEndSample: end,
        complete: found !== null, postRollObserved: postRoll,
        alignment: found ? 'elastic' : 'fixed-grid diagnostic', slotStarts: found?.slotStarts,
        confidences: scores, transport, accepted });
      if (accepted || (found && !capture.transport)) { detection = found; clean = accepted; break; }
    }
    const { offset, scores: slots } = detection
      ? { offset: detection.offsetSamples, scores: markerSlotConfidences(pcm, capture.sampleRate, marker, detection.offsetSamples, detection.slotStarts) }
      : bestFixedGridMarkerDiagnostic(pcm, capture.sampleRate, marker);
    const tailMs = detection ? (pcm.length - detection.slotStarts.at(-1)! - capture.sampleRate * marker.slotMs / 1000) / capture.sampleRate * 1000 : 0;
    // Cover 150 ms post-roll plus the detector's 20 ms alignment uncertainty.
    const postRollObserved = detection !== null && tailMs >= 170;
    const slotStarts = detection?.slotStarts ?? marker.frequencies.map((_, slot) => offset + slot * capture.sampleRate * marker.slotMs / 1000);
    return { clean, cycles, complete: detection !== null, alignment: detection ? "elastic" : "fixed-grid diagnostic",
      postRollObserved, capturedTailMs: tailMs, offsetSamples: offset,
      slotStarts, finalDriftMs: (slotStarts.at(-1)! - offset) / capture.sampleRate * 1000 - (slotStarts.length - 1) * marker.slotMs,
      minimumConfidence: slots.length ? Math.min(...slots) : null,
      slots: slots.map((confidence, index) => ({ index, frequencyHz: marker.frequencies[index],
        startSamples: slotStarts[index], driftMs: (slotStarts[index]! - offset) / capture.sampleRate * 1000 - index * marker.slotMs,
        confidence, margin: confidence - 0.8 })) };
  });
  return { profile: marker.profile, markerId: marker.id, sampleRate: capture.sampleRate,
    clean: channels.every(channel => channel.clean),
    complete: channels.every(channel => channel.complete),
    postRollObserved: channels.every(channel => channel.postRollObserved), channels };
}

/** Every channel and slot is reported, including negative margins on rejected candidates. */
export function markerReport(label: string, evidence: ReturnType<typeof measureMarker> | null): string {
  if (!evidence) return `### ${label}\n\nMissing marker observation.\n`;
  let report = `### ${label}\n\nComplete marker: ${evidence.complete}.\n`;
  for (const [index, channel] of evidence.channels.entries()) {
    report += `\nChannel ${index}; minimum confidence ${channel.minimumConfidence ?? 'unavailable'}; post-roll covered: ${channel.postRollObserved}.\n\n`;
    report += `\nAlignment: ${channel.alignment}; final drift ${channel.finalDriftMs} ms.\n\n`;
    for (const cycle of channel.cycles) {
      const counters = cycle.transport;
      report += `Cycle ${cycle.anchorSamples}–${cycle.markerEndSample} samples: ${counters.state}; complete=${cycle.complete}, post-roll=${cycle.postRollObserved}, accepted=${cycle.accepted}.\n`;
      report += `Required counter bounds: ${counters.requiredStartSample}–${counters.requiredEndSample} samples. First counter: ${counters.firstCounterSample ?? 'unavailable'}. Last counter: ${counters.lastCounterSample ?? 'unavailable'}.\n`;
      report += `Loss=${counters.lost}, concealment=${counters.concealed}, inserted=${counters.inserted}, removed=${counters.removed}; confidences=${cycle.confidences.map(value => value.toFixed(6)).join(',')}.\n\n`;
    }
    report += '| Slot | Hz | Start sample | Drift ms | Confidence | Margin above 0.8 |\n| --- | --- | --- | --- | --- | --- |\n';
    for (const slot of channel.slots) report +=
      `| ${slot.index} | ${slot.frequencyHz} | ${slot.startSamples} | ${slot.driftMs} | ${slot.confidence.toFixed(6)} | ${slot.margin.toFixed(6)} |\n`;
  }
  return report;
}
