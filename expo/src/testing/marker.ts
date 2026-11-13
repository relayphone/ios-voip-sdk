import { MediaTestError } from "./errors.ts";
import type { MarkerDetection, MediaMarker } from "./types.ts";

const tones = [650, 950, 1350, 1850] as const;
/** A four-slot sync followed by the fixture/phase identity encoded in eight slots (the low sixteen hash bits). */
export function createMarker(id: string): MediaMarker {
  if (!id || id.length > 4096) throw new MediaTestError("invalid_arguments", "Invalid marker identity");
  let hash = 2166136261;
  for (const point of new TextEncoder().encode(id)) hash = Math.imul(hash ^ point, 16777619) >>> 0;
  const frequencies: number[] = [...tones];
  for (let shift = 0; shift < 16; shift += 2) frequencies.push(tones[(hash >>> shift) & 3]!);
  return Object.freeze({ id, profile: "tones-v2", slotMs: 60, frequencies: Object.freeze(frequencies) });
}
function validMarker(marker: MediaMarker): void {
  const expected = createMarker(marker.id);
  if (marker.profile !== expected.profile || marker.slotMs !== expected.slotMs ||
      marker.frequencies.length !== expected.frequencies.length ||
      marker.frequencies.some((tone, i) => tone !== expected.frequencies[i]))
    throw new MediaTestError("invalid_arguments", "Marker must use the tones-v2 profile");
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
  const slotSamples = sampleRate / 50 * 3;
  for (let i = 0; i < count; i++) {
    const position = offset + i;
    const slot = Math.floor(position / slotSamples) % marker.frequencies.length;
    const local = position % slotSamples;
    const fade = Math.min(1, Math.min(local, slotSamples - local) / (sampleRate / 200));
    const envelope = 0.5 * (1 - Math.cos(Math.PI * fade));
    pcm[i] = 0.2 * envelope * Math.sin(2 * Math.PI * marker.frequencies[slot]! * local / sampleRate);
  }
  return pcm;
}
/** Repeating 1020 ms emission: 150 ms of 400 Hz, the unchanged marker, then 150 ms of 400 Hz. */
export function emissionSamples(marker: MediaMarker, sampleRate: number, count: number, offset = 0): Float32Array {
  validRate(sampleRate); validMarker(marker);
  if (!Number.isSafeInteger(count) || count < 0 || count > sampleRate * 60 ||
      !Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(offset + count))
    throw new MediaTestError("invalid_arguments", "Invalid emission sample range");
  const pcm = new Float32Array(count);
  const pre = Math.round(sampleRate * 3 / 20);
  const markerLength = sampleRate / 50 * 36;
  const post = pre + markerLength;
  const cycle = sampleRate / 50 * 51;
  for (let written = 0; written < count;) {
    const position = (offset + written) % cycle;
    const inMarker = position >= pre && position < post;
    const end = position < pre ? pre : inMarker ? post : cycle;
    const length = Math.min(count - written, end - position);
    if (inMarker) pcm.set(markerSamples(marker, sampleRate, length, position - pre), written);
    else for (let i = 0; i < length; i++) {
      const local = position + i - (position < pre ? 0 : post);
      const edge = position < pre ? local : cycle - position - i;
      const fade = Math.min(1, edge / (sampleRate / 200));
      const envelope = 0.5 * (1 - Math.cos(Math.PI * fade));
      pcm[written + i] = 0.2 * envelope * Math.sin(2 * Math.PI * 400 * local / sampleRate);
    }
    written += length;
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
/** Complete ordered marker with local slot alignment; signal and confidence threshold are unchanged. */
export function detectMarker(pcm: Float32Array, sampleRate: number, marker: MediaMarker): MarkerDetection | null {
  validRate(sampleRate); validMarker(marker);
  if (pcm.length > sampleRate * 60) throw new MediaTestError("invalid_arguments", "Capture exceeds 60 seconds");
  const slotSamples = sampleRate / 50 * 3;
  const length = slotSamples * marker.frequencies.length;
  // Cache actual 20 ms scores. Neighboring candidate paths reuse the same windows.
  const cache = new Map<number, Map<number, number>>();
  const score = (millisecond: number, frequency: number): number => {
    const start = Math.floor(millisecond * sampleRate / 1000);
    if (start < 0 || start + slotSamples > pcm.length) return -1;
    let values = cache.get(frequency);
    if (!values) { values = new Map(); cache.set(frequency, values); }
    const cached = values.get(millisecond);
    if (cached !== undefined) return cached;
    const result = toneConfidence(pcm, start + sampleRate / 50, sampleRate / 50, frequency, sampleRate);
    values.set(millisecond, result);
    return result;
  };
  const shifts = [0, ...Array.from({ length: 15 }, (_, index) => [-index - 1, index + 1]).flat()];
  // Pure tones can differ by floating-point roundoff. Ties favor the smallest local shift.
  const epsilon = 1e-12;
  for (let firstMs = 0; ; firstMs++) {
    const offset = Math.floor(firstMs * sampleRate / 1000);
    if (offset + length > pcm.length) break;
    let confidence = score(firstMs, marker.frequencies[0]!);
    if (confidence < 0.8) continue;
    const searchEnd = firstMs + marker.slotMs;
    let anchorMs = firstMs;
    // Choose slot zero before evaluating later slots. A failed drift cap cannot move the anchor.
    for (let candidate = firstMs + 1; candidate <= searchEnd; candidate++) {
      if (Math.floor(candidate * sampleRate / 1000) + length > pcm.length) break;
      const candidateScore = score(candidate, marker.frequencies[0]!);
      if (candidateScore > confidence + epsilon) { anchorMs = candidate; confidence = candidateScore; }
    }
    const anchor = Math.floor(anchorMs * sampleRate / 1000);
    const starts = [anchor];
    let previousMs = anchorMs;
    for (const frequency of marker.frequencies.slice(1)) {
      const expectedMs = previousMs + marker.slotMs;
      let chosenMs = expectedMs, chosenScore = -1;
      for (const shift of shifts) {
        const candidateMs = expectedMs + shift, candidateScore = score(candidateMs, frequency);
        if (candidateScore > chosenScore + epsilon || chosenScore < 0.8 && candidateScore >= 0.8) {
          chosenMs = candidateMs; chosenScore = candidateScore;
        }
        if (chosenScore >= 1 - epsilon) break;
      }
      confidence = Math.min(confidence, chosenScore);
      if (confidence < 0.8) break;
      starts.push(Math.floor(chosenMs * sampleRate / 1000));
      previousMs = chosenMs;
    }
    if (confidence >= 0.8 && starts.length === marker.frequencies.length &&
        Math.abs(starts.at(-1)! - anchor - slotSamples * (starts.length - 1)) <= slotSamples)
      return Object.freeze({ id: marker.id, offsetSamples: anchor, confidence, slotStarts: Object.freeze(starts) });
    firstMs = searchEnd;
  }
  return null;
}
