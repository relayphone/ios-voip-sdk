import { detectMarker, markerSlotConfidences } from '../../expo/src/testing/marker.ts';
import type { MediaMarker } from '../../expo/src/testing/types.ts';

export interface PCMCapture {
  readonly sampleRate: number;
  readonly channels: readonly (readonly number[])[];
  readonly formatChanged: boolean;
}

/** Per-slot margins are diagnostics; only the unchanged complete-marker detector can pass. */
export function measureMarker(capture: PCMCapture, marker: MediaMarker) {
  if (capture.formatChanged || capture.channels.length === 0 || capture.channels.length > 8 ||
      !capture.channels.every(channel => channel.length === capture.channels[0]!.length &&
        channel.length <= capture.sampleRate * 3)) throw new Error('Invalid or discontinuous PCM capture');
  const channels = capture.channels.map(samples => {
    const pcm = Float32Array.from(samples);
    const detection = detectMarker(pcm, capture.sampleRate, marker);
    let offset = detection?.offsetSamples ?? 0;
    let slots: readonly number[] = [];
    const length = capture.sampleRate * marker.slotMs / 1000 * marker.frequencies.length;
    if (detection) slots = markerSlotConfidences(pcm, capture.sampleRate, marker, offset, detection.slotStarts);
    else {
      // Best complete candidate retained on failure, including every weak slot. Never a pass.
      let best = -1;
      for (let ms = 0; ; ms++) {
        const candidate = Math.floor(ms * capture.sampleRate / 1000);
        if (candidate + length > pcm.length) break;
        const scores = markerSlotConfidences(pcm, capture.sampleRate, marker, candidate);
        const confidence = Math.min(...scores);
        if (confidence > best) { best = confidence; offset = candidate; slots = scores; }
      }
    }
    const tailMs = detection ? (pcm.length - detection.slotStarts.at(-1)! - capture.sampleRate * marker.slotMs / 1000) / capture.sampleRate * 1000 : 0;
    // Cover 150 ms post-roll plus the detector's 20 ms alignment uncertainty.
    const postRollObserved = detection !== null && tailMs >= 170;
    const slotStarts = detection?.slotStarts ?? marker.frequencies.map((_, slot) => offset + slot * capture.sampleRate * marker.slotMs / 1000);
    return { complete: detection !== null, alignment: detection ? "elastic" : "fixed-grid diagnostic",
      postRollObserved, capturedTailMs: tailMs, offsetSamples: offset,
      slotStarts, finalDriftMs: (slotStarts.at(-1)! - offset) / capture.sampleRate * 1000 - (slotStarts.length - 1) * marker.slotMs,
      minimumConfidence: slots.length ? Math.min(...slots) : null,
      slots: slots.map((confidence, index) => ({ index, frequencyHz: marker.frequencies[index],
        startSamples: slotStarts[index], driftMs: (slotStarts[index]! - offset) / capture.sampleRate * 1000 - index * marker.slotMs,
        confidence, margin: confidence - 0.8 })) };
  });
  return { profile: marker.profile, markerId: marker.id, sampleRate: capture.sampleRate,
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
    report += '| Slot | Hz | Start sample | Drift ms | Confidence | Margin above 0.8 |\n| --- | --- | --- | --- | --- | --- |\n';
    for (const slot of channel.slots) report +=
      `| ${slot.index} | ${slot.frequencyHz} | ${slot.startSamples} | ${slot.driftMs} | ${slot.confidence.toFixed(6)} | ${slot.margin.toFixed(6)} |\n`;
  }
  return report;
}
