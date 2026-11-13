import { MediaTestError } from "./errors.ts";
import type { MarkerDetection, MediaMarker } from "./types.ts";

const tones = [650, 950, 1350, 1850] as const;
/** A four-slot sync followed by the fixture/phase identity encoded in sixteen slots. */
export function createMarker(id: string): MediaMarker {
  if (!id || id.length > 4096) throw new MediaTestError("invalid_arguments", "Invalid marker identity");
  let hash = 2166136261;
  for (const point of new TextEncoder().encode(id)) hash = Math.imul(hash ^ point, 16777619) >>> 0;
  const frequencies: number[] = [...tones];
  for (let shift = 0; shift < 32; shift += 2) frequencies.push(tones[(hash >>> shift) & 3]!);
  return Object.freeze({ id, profile: "tones-v1", slotMs: 20, frequencies: Object.freeze(frequencies) });
}
function validMarker(marker: MediaMarker): void {
  const expected = createMarker(marker.id);
  if (marker.profile !== expected.profile || marker.slotMs !== expected.slotMs ||
      marker.frequencies.length !== expected.frequencies.length ||
      marker.frequencies.some((tone, i) => tone !== expected.frequencies[i]))
    throw new MediaTestError("invalid_arguments", "Marker must use the tones-v1 profile");
}
function validRate(rate: number): void {
  if (!Number.isSafeInteger(rate) || rate < 8000 || rate > 96000 || rate % 50 !== 0)
    throw new MediaTestError("invalid_arguments", "Sample rate must support exact 20 ms slots");
}
/** Normalized mono PCM, paced by the native capture callback or host AudioSource. */
export function markerSamples(marker: MediaMarker, sampleRate: number, count: number, offset = 0): Float32Array {
  validRate(sampleRate); validMarker(marker);
  if (!Number.isSafeInteger(count) || count < 0 || count > sampleRate * 60 ||
      !Number.isSafeInteger(offset) || offset < 0)
    throw new MediaTestError("invalid_arguments", "Invalid marker sample range");
  const pcm = new Float32Array(count);
  const slotSamples = sampleRate / 50;
  for (let i = 0; i < count; i++) {
    const position = offset + i;
    const slot = Math.floor(position / slotSamples) % marker.frequencies.length;
    pcm[i] = 0.2 * Math.sin(2 * Math.PI * marker.frequencies[slot]! * position / sampleRate);
  }
  return pcm;
}
function toneConfidence(pcm: Float32Array, start: number, count: number, frequency: number, rate: number): number {
  const coefficient = 2 * Math.cos(2 * Math.PI * frequency / rate);
  let previous = 0, beforePrevious = 0, energy = 0;
  for (let i = start; i < start + count; i++) {
    const value = pcm[i]!;
    if (!Number.isFinite(value) || Math.abs(value) > 1) return 0;
    const next = value + coefficient * previous - beforePrevious;
    beforePrevious = previous; previous = next; energy += value * value;
  }
  if (energy < count * 0.0001) return 0;
  return Math.min(1, Math.max(0, 2 * (previous * previous + beforePrevious * beforePrevious -
    coefficient * previous * beforePrevious) / (count * energy)));
}
/** Find a complete phase-coded marker rather than accepting audio energy alone. Resolution: 1 ms. */
export function detectMarker(pcm: Float32Array, sampleRate: number, marker: MediaMarker): MarkerDetection | null {
  validRate(sampleRate); validMarker(marker);
  if (pcm.length > sampleRate * 60) throw new MediaTestError("invalid_arguments", "Capture exceeds 60 seconds");
  const slotSamples = sampleRate / 50;
  const length = slotSamples * marker.frequencies.length;
  const step = Math.max(1, Math.floor(sampleRate / 1000));
  let best: MarkerDetection | null = null;
  let searchEnd = Infinity;
  for (let offset = 0; offset + length <= pcm.length && offset <= searchEnd; offset += step) {
    let confidence = 1;
    for (const [slot, frequency] of marker.frequencies.entries()) {
      confidence = Math.min(confidence, toneConfidence(pcm, offset + slot * slotSamples, slotSamples, frequency, sampleRate));
      if (confidence < 0.8) break;
    }
    if (confidence >= 0.8) {
      if (!best) searchEnd = offset + slotSamples;
      if (!best || confidence > best.confidence + 0.0001)
        best = Object.freeze({ id: marker.id, offsetSamples: offset, confidence });
    }
  }
  return best;
}
