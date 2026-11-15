import { createMarker } from "./marker.ts";
import { MediaTestError } from "./errors.ts";
import type { MediaReadRequest, MediaReceipt, MediaTestResult, MediaObservation, MediaCapture, MediaMarker, MediaSilenceWindow } from "./types.ts";

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
function readCapture(value: unknown, expected: MediaMarker, continuous: boolean): MediaCapture {
  const data = object(value), slotMs = expected.slotMs;
  const startedAtMs = number(data.startedAtMs, "startedAtMs");
  const endedAtMs = number(data.endedAtMs, "endedAtMs");
  if (endedAtMs <= startedAtMs) invalid("Capture has no duration");
  const sampleRate = integer(data.sampleRate, "sampleRate", 8000);
  if (sampleRate > 96000 || sampleRate % 50 !== 0) invalid("Unsupported sample rate");
  const sampleCount = integer(data.sampleCount, "sampleCount");
  const slotSamples = sampleRate * slotMs / 1000;
  const frameCount = integer(data.frameCount, "frameCount");
  const overflowFrames = integer(data.overflowFrames, "overflowFrames");
  const monitorTicks = integer(data.monitorTicks, "monitorTicks");
  const maxGapMs = number(data.maxGapMs, "maxGapMs");
  const rms = number(data.rms, "rms"), peak = number(data.peak, "peak");
  if (maxGapMs < 0 || (continuous && (overflowFrames !== 0 || maxGapMs > 40))) invalid("Capture overflow or missing observation interval");
  if (sampleCount > sampleRate * 60 || endedAtMs - startedAtMs > 60_000 || frameCount > sampleCount)
    invalid("Capture exceeds bounds");
  if (rms < 0 || peak < rms || peak > 1 || (sampleCount === 0 && peak !== 0)) invalid("Invalid PCM levels");
  const measuredMs = endedAtMs - startedAtMs;
  if ((continuous && monitorTicks < Math.ceil(measuredMs / 40)) || sampleCount / sampleRate * 1000 > measuredMs + 20 ||
      ((sampleCount === 0) !== (frameCount === 0))) invalid("Capture has no continuous observer evidence");
  let marker: MediaReceipt["marker"] = null;
  if (data.marker !== null) {
    const detection = object(data.marker);
    const offsetSamples = integer(detection.offsetSamples, "offsetSamples");
    const confidence = number(detection.confidence, "confidence");
    if (offsetSamples >= sampleCount || confidence < 0 || confidence > 1) invalid("Invalid marker observation");
    if (!Array.isArray(detection.slotStarts) || detection.slotStarts.length !== expected.frequencies.length)
      invalid("A complete ordered slot alignment is required");
    const slotStarts = Array.from(detection.slotStarts, (value, index) => {
      const start = integer(value, "slot start");
      if (start + slotSamples > sampleCount || index === 0 && start !== offsetSamples)
        invalid("Slot alignment exceeds capture or disagrees with marker start");
      return start;
    });
    for (let index = 1; index < slotStarts.length; index++) {
      if (Math.abs(slotStarts[index]! - slotStarts[index - 1]! - slotSamples) > Math.ceil(sampleRate * 0.015))
        invalid("Slot alignment exceeds local drift limit");
      if (Math.abs(slotStarts[index]! - offsetSamples - slotSamples * index) > slotSamples)
        invalid("Slot alignment exceeds cumulative drift limit");
      if (expected.frequencies[index] === expected.frequencies[index - 1] &&
          slotStarts[index]! - slotStarts[index - 1]! !== slotSamples)
        invalid("Slot alignment changes drift inside a repeated tone");
    }
    marker = Object.freeze({ id: text(detection.id, "marker id", 4096), offsetSamples, confidence,
      slotStarts: Object.freeze(slotStarts) });
  }
  return Object.freeze({ startedAtMs, endedAtMs, sampleRate, sampleCount, frameCount, overflowFrames,
    monitorTicks, maxGapMs, rms, peak, marker });
}

function readWindows(value: unknown, expected: MediaMarker, anchor: number, within: number): readonly MediaSilenceWindow[] {
  if (!Array.isArray(value)) invalid("Silence requires every attempted window");
  let previousEnd = anchor;
  return Object.freeze(Array.from(value, item => {
    const data = object(item), capture = readCapture(data, expected, false);
    if (capture.startedAtMs < previousEnd || capture.endedAtMs > anchor + within)
      invalid("Silence windows must be ordered and inside the phase budget");
    previousEnd = capture.endedAtMs;
    const coveredMs = number(data.coveredMs, "coveredMs");
    if (!Array.isArray(data.gaps)) invalid("Silence window gaps are required");
    let gapEnd = capture.startedAtMs, uncovered = 0;
    const gaps = Object.freeze(Array.from(data.gaps, value => {
      const gap = object(value), startedAtMs = number(gap.startedAtMs, "gap start"), endedAtMs = number(gap.endedAtMs, "gap end");
      if (startedAtMs < gapEnd || endedAtMs <= startedAtMs || endedAtMs > capture.endedAtMs ||
          endedAtMs - startedAtMs > capture.maxGapMs) invalid("Invalid silence coverage gap");
      gapEnd = endedAtMs; uncovered += endedAtMs - startedAtMs;
      return Object.freeze({ startedAtMs, endedAtMs });
    }));
    if (coveredMs < 0 || coveredMs > capture.endedAtMs - capture.startedAtMs - uncovered)
      invalid("Silence coverage exceeds the observed interval");
    const verdict = data.verdict;
    if (verdict !== "silent" && verdict !== "unobserved" && verdict !== "leak") invalid("Invalid silence verdict");
    return Object.freeze({ ...capture, coveredMs, gaps, verdict });
  }));
}

function continuous(window: MediaSilenceWindow, duration: number): boolean {
  return window.verdict === "silent" && window.coveredMs >= duration && window.overflowFrames === 0 &&
    window.maxGapMs <= 40 && window.monitorTicks >= Math.ceil((window.endedAtMs - window.startedAtMs) / 40);
}
function sameCapture(a: MediaCapture, b: MediaCapture): boolean {
  const fields = ["startedAtMs", "endedAtMs", "sampleRate", "sampleCount", "frameCount", "overflowFrames",
    "monitorTicks", "maxGapMs", "rms", "peak"] as const;
  return fields.every(key => a[key] === b[key]) && (a.marker === b.marker || Boolean(a.marker && b.marker &&
    a.marker.id === b.marker.id && a.marker.offsetSamples === b.marker.offsetSamples && a.marker.confidence === b.marker.confidence &&
    a.marker.slotStarts.every((start, index) => start === b.marker!.slotStarts[index])));
}

/** Validate serialized evidence independently of any producer's passed flag. */
export function validateMediaReceipt(value: unknown, request: MediaReadRequest): MediaTestResult {
  const expected = createMarker(request.marker.id);
  if (request.marker.profile !== expected.profile || request.marker.slotMs !== expected.slotMs ||
      request.marker.frequencies.length !== expected.frequencies.length ||
      request.marker.frequencies.some((tone, index) => tone !== expected.frequencies[index]))
    invalid("Unsupported marker profile");
  const data = object(value), clock = object(data.clock);
  if (data.profile !== expected.profile) invalid("Unsupported receipt marker profile");
  for (const key of ["conversationId", "fixtureId", "direction", "stage"] as const)
    if (data[key] !== request[key]) invalid(`Mismatched ${key}`);
  if (data.schemaVersion !== 1 || data.phaseId !== request.phase.id) invalid("Stale or unsupported receipt");
  if (clock.domain !== request.clock.domain || clock.id !== request.clock.id) invalid("Mismatched observer clock");
  const anchor = request.phase.anchors.find(item => item.clock.domain === clock.domain && item.clock.id === clock.id);
  if (!anchor) invalid("Receipt has no acknowledged same-clock phase anchor");
  if (data.tap !== "active") throw new MediaTestError("capability_missing", "The required audio tap is missing");
  const capture = readCapture(data, expected, request.expectation === "audio");
  if (capture.startedAtMs < anchor.atMs) invalid("Capture precedes phase");
  const { startedAtMs, sampleRate, sampleCount, marker } = capture;
  const slotSamples = sampleRate * expected.slotMs / 1000;
  const within = request.withinMs === undefined ? 30000 : request.withinMs;
  if (request.expectation === "silence" && (!Number.isSafeInteger(request.durationMs) || request.durationMs < 1 ||
      !Number.isSafeInteger(within) || within < request.durationMs || within > 60000)) invalid("Invalid silence request budget");
  const silenceWindows = request.expectation === "silence" ? readWindows(data.silenceWindows, expected, anchor.atMs, within) : undefined;
  const target: MediaObservation = request.direction === "toDevice"
    ? { direction: request.direction, stage: request.stage } : { direction: request.direction, stage: request.stage };
  const receipt: MediaReceipt = Object.freeze({ ...target, ...capture,
    schemaVersion: 1, profile: expected.profile, conversationId: request.conversationId, fixtureId: request.fixtureId,
    phaseId: request.phase.id, clock: Object.freeze({ domain: anchor.clock.domain, id: anchor.clock.id }), tap: "active",
    ...(silenceWindows ? { silenceWindows } : {}),
  });
  const firstAudioAfterPhaseMs = marker && marker.id === request.marker.id && marker.confidence >= 0.8
    ? startedAtMs - anchor.atMs + marker.offsetSamples / sampleRate * 1000 : null;
  if (request.expectation === "audio") {
    const markerEnd = marker ? marker.slotStarts.at(-1)! + slotSamples : Infinity;
    const markerMs = marker ? (markerEnd - marker.offsetSamples) / sampleRate * 1000 : Infinity;
    if (firstAudioAfterPhaseMs === null || firstAudioAfterPhaseMs + markerMs > request.durationMs ||
        markerEnd > sampleCount)
      throw new MediaTestError("audio_missing", "No complete current-phase marker arrived within the deadline");
  } else {
    if (rmsLeak(capture) || silenceWindows!.some(window => window.verdict === "leak" || rmsLeak(window)))
      throw new MediaTestError("audio_leak", "Audio was present during a silence attempt", receipt);
    const selected = silenceWindows!.find(window => continuous(window, request.durationMs));
    if (!selected) throw new MediaTestError("unobserved", "No complete continuous silent window within the phase budget", receipt);
    if (!sameCapture(capture, selected)) invalid("Receipt must describe the first complete silent window");
  }
  return Object.freeze({ expectation: request.expectation, receipt, firstAudioAfterPhaseMs });
}
function rmsLeak(capture: MediaCapture): boolean {
  return capture.rms > 0.003 || capture.peak > 0.01 || capture.marker !== null;
}
