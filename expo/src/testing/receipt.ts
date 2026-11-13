import { createMarker } from "./marker.ts";
import { MediaTestError } from "./errors.ts";
import type { MediaReadRequest, MediaReceipt, MediaTestResult, MediaObservation } from "./types.ts";

function invalid(message: string): never { throw new MediaTestError("invalid_receipt", message); }
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid("Expected an evidence object");
  return value as Record<string, unknown>;
}
function number(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) invalid(`${label} must be finite`);
  return value;
}
function integer(value: unknown, label: string, minimum = 0): number {
  const result = number(value, label);
  if (!Number.isSafeInteger(result) || result < minimum) invalid(`${label} must be a nonnegative integer`);
  return result;
}
function text(value: unknown, label: string, maximum = 256): string {
  if (typeof value !== "string" || !value || value.length > maximum) invalid(`Invalid ${label}`);
  return value;
}
/** Validate serialized evidence independently of any producer's passed flag. */
export function validateMediaReceipt(value: unknown, request: MediaReadRequest): MediaTestResult {
  const expected = createMarker(request.marker.id);
  if (request.marker.profile !== expected.profile || request.marker.slotMs !== expected.slotMs ||
      request.marker.frequencies.length !== expected.frequencies.length ||
      request.marker.frequencies.some((tone, index) => tone !== expected.frequencies[index]))
    invalid("Unsupported marker profile");
  const markerMs = expected.frequencies.length * expected.slotMs;
  const data = object(value), clock = object(data.clock);
  if (data.profile !== expected.profile) invalid("Unsupported receipt marker profile");
  for (const key of ["conversationId", "fixtureId", "direction", "stage"] as const)
    if (data[key] !== request[key]) invalid(`Mismatched ${key}`);
  if (data.schemaVersion !== 1 || data.phaseId !== request.phase.id) invalid("Stale or unsupported receipt");
  if (clock.domain !== request.clock.domain || clock.id !== request.clock.id) invalid("Mismatched observer clock");
  const anchor = request.phase.anchors.find(item => item.clock.domain === clock.domain && item.clock.id === clock.id);
  if (!anchor) invalid("Receipt has no acknowledged same-clock phase anchor");
  if (data.tap !== "active") throw new MediaTestError("capability_missing", "The required audio tap is missing");
  const startedAtMs = number(data.startedAtMs, "startedAtMs");
  const endedAtMs = number(data.endedAtMs, "endedAtMs");
  if (startedAtMs < anchor.atMs || endedAtMs <= startedAtMs) invalid("Capture precedes phase or has no duration");
  const sampleRate = integer(data.sampleRate, "sampleRate", 8000);
  if (sampleRate > 96000 || sampleRate % 50 !== 0) invalid("Unsupported sample rate");
  const sampleCount = integer(data.sampleCount, "sampleCount");
  const frameCount = integer(data.frameCount, "frameCount");
  const overflowFrames = integer(data.overflowFrames, "overflowFrames");
  const monitorTicks = integer(data.monitorTicks, "monitorTicks", 1);
  const maxGapMs = number(data.maxGapMs, "maxGapMs");
  const rms = number(data.rms, "rms"), peak = number(data.peak, "peak");
  if (overflowFrames !== 0 || maxGapMs < 0 || maxGapMs > 40) invalid("Capture overflow or missing observation interval");
  if (sampleCount > sampleRate * 60 || endedAtMs - startedAtMs > 60_000 || frameCount > sampleCount)
    invalid("Capture exceeds bounds");
  if (rms < 0 || peak < rms || peak > 1 || (sampleCount === 0 && peak !== 0)) invalid("Invalid PCM levels");
  const measuredMs = endedAtMs - startedAtMs;
  if (monitorTicks < Math.ceil(measuredMs / 40) || sampleCount / sampleRate * 1000 > measuredMs + 20 ||
      ((sampleCount === 0) !== (frameCount === 0))) invalid("Capture has no continuous observer evidence");
  let marker: MediaReceipt["marker"] = null;
  if (data.marker !== null) {
    const detection = object(data.marker);
    const offsetSamples = integer(detection.offsetSamples, "offsetSamples");
    const confidence = number(detection.confidence, "confidence");
    if (offsetSamples >= sampleCount || confidence < 0 || confidence > 1) invalid("Invalid marker observation");
    marker = Object.freeze({ id: text(detection.id, "marker id", 4096), offsetSamples, confidence });
  }
  const target: MediaObservation = request.direction === "toDevice"
    ? { direction: request.direction, stage: request.stage } : { direction: request.direction, stage: request.stage };
  const receipt: MediaReceipt = Object.freeze({ ...target,
    schemaVersion: 1, profile: expected.profile, conversationId: request.conversationId, fixtureId: request.fixtureId,
    phaseId: request.phase.id,
    clock: Object.freeze({ domain: anchor.clock.domain, id: anchor.clock.id }), tap: "active",
    startedAtMs, endedAtMs, sampleRate, sampleCount, frameCount, overflowFrames, monitorTicks, maxGapMs, rms, peak, marker,
  });
  const firstAudioAfterPhaseMs = marker && marker.id === request.marker.id && marker.confidence >= 0.8
    ? startedAtMs - anchor.atMs + marker.offsetSamples / sampleRate * 1000 : null;
  if (request.expectation === "audio") {
    if (firstAudioAfterPhaseMs === null || firstAudioAfterPhaseMs + markerMs > request.durationMs ||
        marker!.offsetSamples + markerMs / 1000 * sampleRate > sampleCount)
      throw new MediaTestError("audio_missing", "No complete current-phase marker arrived within the deadline");
  } else {
    if (startedAtMs !== anchor.atMs || measuredMs < request.durationMs || endedAtMs - anchor.atMs < request.durationMs)
      invalid("Silence requires continuous coverage from the phase anchor");
    if (rms > 0.003 || peak > 0.01 || marker !== null)
      throw new MediaTestError("audio_leak", "Audio was present during the expected silence interval");
  }
  return Object.freeze({ expectation: request.expectation, receipt, firstAudioAfterPhaseMs });
}
