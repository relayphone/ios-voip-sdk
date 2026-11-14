import { MediaTestError } from "./errors.ts";
import { preferMarkerPath } from "./marker-path.ts";
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
  // Preserve the existing slot-zero anchor's numerical tie rule.
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
    // One optimal prefix per (slot, cumulative drift): future costs depend only on this state.
    interface Path { movement: number; sum: number; minimum: number; starts: readonly number[] }
    let paths = new Map<number, Path>([[0, { movement: 0, sum: confidence, minimum: confidence, starts: [anchorMs] }]]);
    for (let slot = 1; slot < marker.frequencies.length && paths.size; slot++) {
      const next = new Map<number, Path>();
      const step = marker.frequencies[slot] === marker.frequencies[slot - 1] ? 0 : 15;
      for (const [previousDrift, prefix] of paths) {
        for (let drift = Math.max(-60, previousDrift - step); drift <= Math.min(60, previousDrift + step); drift++) {
          const start = anchorMs + slot * marker.slotMs + drift;
          const value = score(start, marker.frequencies[slot]!);
          if (value < 0.8) continue;
          const path: Path = { movement: prefix.movement + Math.abs(drift - previousDrift),
            sum: prefix.sum + value, minimum: Math.min(prefix.minimum, value), starts: [...prefix.starts, start] };
          const incumbent = next.get(drift);
          if (!incumbent || preferMarkerPath(path, incumbent)) next.set(drift, path);
        }
      }
      paths = next;
    }
    let chosen: Path | undefined;
    for (const path of paths.values()) if (!chosen || preferMarkerPath(path, chosen)) chosen = path;
    if (chosen) return Object.freeze({ id: marker.id, offsetSamples: anchor, confidence: chosen.minimum,
      slotStarts: Object.freeze(chosen.starts.map(ms => Math.floor(ms * sampleRate / 1000))) });
    firstMs = searchEnd;
  }
  return null;
}

/** Internal diagnostic companion: score the selected elastic starts, or a labelled fixed-grid candidate. */
export function markerSlotConfidences(pcm: Float32Array, sampleRate: number, marker: MediaMarker,
  offset: number, slotStarts?: readonly number[]): readonly number[] {
  validRate(sampleRate); validMarker(marker);
  const count = sampleRate / 50;
  const starts = slotStarts ?? marker.frequencies.map((_, slot) => offset + slot * count * 3);
  if (!Number.isSafeInteger(offset) || offset < 0 || starts.length !== marker.frequencies.length ||
      starts[0] !== offset || starts.some(start => !Number.isSafeInteger(start) || start < 0 || start + count * 3 > pcm.length))
    throw new MediaTestError("invalid_arguments", "Full aligned slot windows are required");
  return marker.frequencies.map((frequency, slot) => toneConfidence(pcm, starts[slot]! + count, count, frequency, sampleRate));
}
