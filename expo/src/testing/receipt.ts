import { createMarker } from "./marker.ts";
import { MediaTestError } from "./errors.ts";
import type { MediaReadRequest, MediaReceipt, MediaTestResult, MediaObservation, MediaCapture, MediaMarker, MediaSilenceWindow } from "./types.ts";

const invalid: (message: string) => never = message => {
  throw new MediaTestError("invalid_receipt", message);
};

function isEvidenceObject<Value>(value: Value): value is Value & object {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function object<Value>(value: Value) {
  if (!isEvidenceObject(value)) invalid("Expected an evidence object");
  return value;
}

function hasField<Value extends object, Key extends string>(value: Value, key: Key): value is Value & Record<Key, unknown> {
  return key in value;
}

function field<Value extends object, Key extends string>(value: Value, key: Key) {
  return hasField(value, key) ? value[key] : undefined;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function number(value: unknown, label: string) {
  if (!isFiniteNumber(value)) invalid(`${label} must be finite`);
  return value;
}
function integer(value: unknown, label: string, minimum = 0) {
  const result = number(value, label);
  if (!Number.isSafeInteger(result) || result < minimum) invalid(`${label} must be a nonnegative integer`);
  return result;
}
function isText(value: unknown): value is string {
  return typeof value === "string";
}
function text(value: unknown, label: string, maximum = 256) {
  if (!isText(value) || !value || value.length > maximum) invalid(`Invalid ${label}`);
  return value;
}
function readCapture(value: unknown, expected: MediaMarker, continuous: boolean) {
  const data = object(value), slotMs = expected.slotMs;
  const startedAtMs = number(field(data, "startedAtMs"), "startedAtMs");
  const endedAtMs = number(field(data, "endedAtMs"), "endedAtMs");
  if (endedAtMs <= startedAtMs) invalid("Capture has no duration");
  const sampleRate = integer(field(data, "sampleRate"), "sampleRate", 8000);
  if (sampleRate > 96000 || sampleRate % 50 !== 0) invalid("Unsupported sample rate");
  const sampleCount = integer(field(data, "sampleCount"), "sampleCount");
  const slotSamples = sampleRate * slotMs / 1000;
  const frameCount = integer(field(data, "frameCount"), "frameCount");
  const overflowFrames = integer(field(data, "overflowFrames"), "overflowFrames");
  const monitorTicks = integer(field(data, "monitorTicks"), "monitorTicks");
  const maxGapMs = number(field(data, "maxGapMs"), "maxGapMs");
  const rms = number(field(data, "rms"), "rms"), peak = number(field(data, "peak"), "peak");
  if (maxGapMs < 0 || (continuous && (overflowFrames !== 0 || maxGapMs > 40))) invalid("Capture overflow or missing observation interval");
  if (sampleCount > sampleRate * 60 || endedAtMs - startedAtMs > 60_000 || frameCount > sampleCount)
    invalid("Capture exceeds bounds");
  if (rms < 0 || peak < rms || peak > 1 || (sampleCount === 0 && peak !== 0)) invalid("Invalid PCM levels");
  const measuredMs = endedAtMs - startedAtMs;
  if ((continuous && monitorTicks < Math.ceil(measuredMs / 40)) || sampleCount / sampleRate * 1000 > measuredMs + 20 ||
      ((sampleCount === 0) !== (frameCount === 0))) invalid("Capture has no continuous observer evidence");
  let marker: MediaReceipt["marker"] = null;
  const rawMarker = field(data, "marker");
  if (rawMarker !== null) {
    const detection = object(rawMarker);
    const offsetSamples = integer(field(detection, "offsetSamples"), "offsetSamples");
    const confidence = number(field(detection, "confidence"), "confidence");
    if (offsetSamples >= sampleCount || confidence < 0 || confidence > 1) invalid("Invalid marker observation");
    const positions = field(detection, "slotStarts");
    if (!Array.isArray(positions) || positions.length !== expected.frequencies.length)
      invalid("A complete ordered slot alignment is required");
    const starts: readonly unknown[] = positions;
    const slotStarts = Array.from(starts, (value, index) => {
      const start = integer(value, "slot start");
      if (start + slotSamples > sampleCount || index === 0 && start !== offsetSamples)
        invalid("Slot alignment exceeds capture or disagrees with marker start");
      return start;
    });
    let previous = offsetSamples;
    for (const [index, start] of slotStarts.entries()) {
      if (index === 0) continue;
      const delta = start - previous;
      if (Math.abs(delta - slotSamples) > Math.ceil(sampleRate * 0.015))
        invalid("Slot alignment exceeds local drift limit");
      if (Math.abs(start - offsetSamples - slotSamples * index) > slotSamples)
        invalid("Slot alignment exceeds cumulative drift limit");
      if (expected.frequencies[index] === expected.frequencies[index - 1] && delta !== slotSamples)
        invalid("Slot alignment changes drift inside a repeated tone");
      previous = start;
    }
    marker = Object.freeze({ id: text(field(detection, "id"), "marker id", 4096), offsetSamples, confidence,
      slotStarts: Object.freeze(slotStarts) });
  }
  return Object.freeze({ startedAtMs, endedAtMs, sampleRate, sampleCount, frameCount, overflowFrames,
    monitorTicks, maxGapMs, rms, peak, marker }) satisfies MediaCapture;
}

function readWindows(value: unknown, expected: MediaMarker, anchor: number, within: number) {
  if (!Array.isArray(value)) invalid("Silence requires every attempted window");
  let previousEnd = anchor;
  const windows: readonly unknown[] = value;
  return Object.freeze(Array.from(windows, item => {
    const data = object(item);
    const capture = readCapture(data, expected, false);
    if (capture.startedAtMs < previousEnd || capture.endedAtMs > anchor + within)
      invalid("Silence windows must be ordered and inside the phase budget");
    previousEnd = capture.endedAtMs;
    const coveredMs = number(field(data, "coveredMs"), "coveredMs");
    const gapValues = field(data, "gaps");
    if (!Array.isArray(gapValues)) invalid("Silence window gaps are required");
    const entries: readonly unknown[] = gapValues;
    let gapEnd = capture.startedAtMs, uncovered = 0;
    const gaps = Object.freeze(Array.from(entries, value => {
      const gap = object(value);
      const startedAtMs = number(field(gap, "startedAtMs"), "gap start");
      const endedAtMs = number(field(gap, "endedAtMs"), "gap end");
      if (startedAtMs < gapEnd || endedAtMs <= startedAtMs || endedAtMs > capture.endedAtMs ||
          endedAtMs - startedAtMs > capture.maxGapMs) invalid("Invalid silence coverage gap");
      gapEnd = endedAtMs; uncovered += endedAtMs - startedAtMs;
      return Object.freeze({ startedAtMs, endedAtMs });
    }));
    if (coveredMs < 0 || coveredMs > capture.endedAtMs - capture.startedAtMs - uncovered)
      invalid("Silence coverage exceeds the observed interval");
    const verdict = field(data, "verdict");
    if (verdict !== "silent" && verdict !== "unobserved" && verdict !== "leak") invalid("Invalid silence verdict");
    return Object.freeze({ ...capture, coveredMs, gaps, verdict }) satisfies MediaSilenceWindow;
  }));
}

function continuous(window: MediaSilenceWindow, duration: number) {
  return window.verdict === "silent" && window.coveredMs >= duration && window.overflowFrames === 0 &&
    window.maxGapMs <= 40 && window.monitorTicks >= Math.ceil((window.endedAtMs - window.startedAtMs) / 40);
}
function sameCapture(a: MediaCapture, b: MediaCapture) {
  const fields = ["startedAtMs", "endedAtMs", "sampleRate", "sampleCount", "frameCount", "overflowFrames",
    "monitorTicks", "maxGapMs", "rms", "peak"] satisfies (keyof MediaCapture)[];
  const { marker: first } = a;
  const { marker: second } = b;
  return fields.every(key => a[key] === b[key]) && (first === second || (first !== null && second !== null &&
    first.id === second.id && first.offsetSamples === second.offsetSamples && first.confidence === second.confidence &&
    first.slotStarts.every((start, index) => start === second.slotStarts[index])));
}

/** Validate serialized evidence independently of any producer's passed flag. */
export function validateMediaReceipt(value: unknown, request: MediaReadRequest) {
  const expected = createMarker(request.marker.id);
  if (request.marker.profile !== expected.profile || request.marker.slotMs !== expected.slotMs ||
      request.marker.frequencies.length !== expected.frequencies.length ||
      request.marker.frequencies.some((tone, index) => tone !== expected.frequencies[index]))
    invalid("Unsupported marker profile");
  const data = object(value), clock = object(field(data, "clock"));
  if (field(data, "profile") !== expected.profile) invalid("Unsupported receipt marker profile");
  const identityFields = ["conversationId", "fixtureId", "direction", "stage"] satisfies (keyof MediaReadRequest)[];
  for (const key of identityFields)
    if (field(data, key) !== request[key]) invalid(`Mismatched ${key}`);
  if (field(data, "schemaVersion") !== 1 || field(data, "phaseId") !== request.phase.id) invalid("Stale or unsupported receipt");
  const domain = field(clock, "domain"), clockID = field(clock, "id");
  if (domain !== request.clock.domain || clockID !== request.clock.id) invalid("Mismatched observer clock");
  const anchor = request.phase.anchors.find(item => item.clock.domain === domain && item.clock.id === clockID);
  if (!anchor) invalid("Receipt has no acknowledged same-clock phase anchor");
  if (field(data, "tap") !== "active") throw new MediaTestError("capability_missing", "The required audio tap is missing");
  const capture = readCapture(data, expected, request.expectation === "audio");
  if (capture.startedAtMs < anchor.atMs) invalid("Capture precedes phase");
  const { startedAtMs, sampleRate, sampleCount, marker } = capture;
  const slotSamples = sampleRate * expected.slotMs / 1000;
  const within = request.withinMs === undefined ? 30000 : request.withinMs;
  if (request.expectation === "silence" && (!Number.isSafeInteger(request.durationMs) || request.durationMs < 1 ||
      !Number.isSafeInteger(within) || within < request.durationMs || within > 60000)) invalid("Invalid silence request budget");
  const silenceWindows = request.expectation === "silence" ? readWindows(field(data, "silenceWindows"), expected, anchor.atMs, within) : undefined;
  const target: MediaObservation = request.direction === "toDevice"
    ? { direction: request.direction, stage: request.stage } : { direction: request.direction, stage: request.stage };
  const receipt: MediaReceipt = Object.freeze({ ...target, ...capture,
    schemaVersion: 1, profile: expected.profile, conversationId: request.conversationId, fixtureId: request.fixtureId,
    phaseId: request.phase.id, clock: Object.freeze({ domain: anchor.clock.domain, id: anchor.clock.id }), tap: "active",
    ...(silenceWindows && { silenceWindows }),
  });
  const firstAudioAfterPhaseMs = marker && marker.id === request.marker.id && marker.confidence >= 0.8
    ? startedAtMs - anchor.atMs + marker.offsetSamples / sampleRate * 1000 : null;
  if (silenceWindows === undefined) {
    const lastSlot = marker?.slotStarts.at(-1);
    const markerEnd = lastSlot === undefined ? Infinity : lastSlot + slotSamples;
    const markerMs = marker ? (markerEnd - marker.offsetSamples) / sampleRate * 1000 : Infinity;
    if (firstAudioAfterPhaseMs === null || firstAudioAfterPhaseMs + markerMs > request.durationMs ||
        markerEnd > sampleCount)
      throw new MediaTestError("audio_missing", "No complete current-phase marker arrived within the deadline");
  } else {
    if (rmsLeak(capture) || silenceWindows.some(window => window.verdict === "leak" || rmsLeak(window)))
      throw new MediaTestError("audio_leak", "Audio was present during a silence attempt", receipt);
    const selected = silenceWindows.find(window => continuous(window, request.durationMs));
    if (!selected) throw new MediaTestError("unobserved", "No complete continuous silent window within the phase budget", receipt);
    if (!sameCapture(capture, selected)) invalid("Receipt must describe the first complete silent window");
  }
  return Object.freeze({ expectation: request.expectation, receipt, firstAudioAfterPhaseMs }) satisfies MediaTestResult;
}
function rmsLeak(capture: MediaCapture) {
  return capture.rms > 0.003 || capture.peak > 0.01 || capture.marker !== null;
}
