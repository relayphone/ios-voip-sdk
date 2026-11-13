import { MediaTestError } from "./errors.ts";
import { createMarker } from "./marker.ts";
import { validateMediaReceipt } from "./receipt.ts";
import type {
  ExpectAudioOptions, ExpectSilenceOptions, MediaExpectation, MediaObservation,
  MediaPhase, MediaTest, MediaTestAdapter, MediaTestOptions, MediaTestResult,
} from "./types.ts";

let sessions = 0;

function identity(value: string, maximum: number): boolean {
  return typeof value === "string" && value.length > 0 && value.length <= maximum;
}
function duration(value: number): number {
  if (!Number.isSafeInteger(value) || value < 1 || value > 60_000)
    throw new MediaTestError("invalid_arguments", "Duration must be 1–60000 milliseconds");
  return value;
}
function observation(options: MediaExpectation): MediaObservation {
  const stage = options.stage ?? (options.direction === "toDevice" ? "output" : "farEnd");
  if (options.direction === "toDevice" && (stage === "output" || stage === "decoded"))
    return { direction: options.direction, stage };
  if (options.direction === "fromDevice" && stage === "farEnd") return { direction: options.direction, stage };
  throw new MediaTestError("invalid_arguments", "Observation stage does not match direction");
}
function bounded<T>(milliseconds: number, signal: AbortSignal, body: (signal: AbortSignal) => Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const controller = new AbortController();
    let finished = false;
    const complete = (settle: () => void) => {
      if (finished) return;
      finished = true; clearTimeout(timer); signal.removeEventListener("abort", abort); settle();
    };
    const abort = () => {
      controller.abort(); complete(() => reject(new MediaTestError("closed", "Media test closed")));
    };
    const timer = setTimeout(() => {
      controller.abort();
      complete(() => reject(new MediaTestError("deadline_exceeded", "Media observation did not complete")));
    }, milliseconds);
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) { abort(); return; }
    Promise.resolve().then(() => body(controller.signal)).then(
      value => complete(() => resolve(value)),
      error => complete(() => reject(error instanceof MediaTestError ? error :
        new MediaTestError("adapter_failed", "Media testing adapter failed"))),
    );
  });
}
/**
 * Open a test against the app's actual call media. Adapters are supplied by the platform test kit.
 * Without an installed adapter, this rejects with unavailable; it never fabricates evidence.
 * No LiveKit runtime is imported by this contract-only entry point.
 */
export async function createMediaTest(options: MediaTestOptions, adapter?: MediaTestAdapter): Promise<MediaTest> {
  if (!identity(options.conversationId, 256) || !identity(options.fixtureId, 128))
    throw new MediaTestError("invalid_arguments", "Conversation and fixture identities are required");
  if (!adapter) throw new MediaTestError("unavailable", "No media testing adapter is installed");
  const scope = Object.freeze({ conversationId: options.conversationId, fixtureId: options.fixtureId });
  const lifetime = new AbortController();
  const connection = await bounded(3000, lifetime.signal, async signal => {
    const opened = await adapter.open(scope, signal);
    if (signal.aborted) { await opened.close(); throw new MediaTestError("closed", "Media test closed while opening"); }
    return opened;
  });
  if (!identity(connection.sessionId, 128)) {
    await bounded(3000, lifetime.signal, () => connection.close());
    throw new MediaTestError("invalid_receipt", "Missing media test session identity");
  }
  const instance = ++sessions;
  let phase: MediaPhase | undefined;
  let generation = 0;
  let queue = Promise.resolve();
  let closing: Promise<void> | undefined;
  function enqueue<T>(body: () => Promise<T>): Promise<T> {
    const result = queue.then(() => {
      if (lifetime.signal.aborted) throw new MediaTestError("closed", "Media test closed");
      return body();
    });
    queue = result.then(() => {}, () => {});
    return result;
  }
  async function expect(expectation: "audio" | "silence", options: MediaExpectation, milliseconds: number): Promise<MediaTestResult> {
    if (!phase) throw new MediaTestError("phase_required", "Begin an acknowledged phase before observing audio");
    const target = observation(options);
    const capability = connection.capabilities.find(value => value.direction === target.direction && value.stage === target.stage);
    if (!capability) throw new MediaTestError("capability_missing", `No ${target.direction} ${target.stage} observation`);
    const expectedDomain = target.direction === "toDevice" ? "nativeMonotonic" : "peerMonotonic";
    if (capability.domain !== expectedDomain || !phase.anchors.some(anchor =>
      anchor.clock.domain === capability.domain && anchor.clock.id === capability.id))
      throw new MediaTestError("capability_missing", "No acknowledged observer clock");
    const request = Object.freeze({ ...scope, ...target, phase, clock: Object.freeze({ domain: capability.domain, id: capability.id }),
      marker: createMarker(phase.id), expectation, durationMs: duration(milliseconds) });
    const receipt = await bounded(milliseconds, lifetime.signal, signal => connection.read(request, signal));
    return validateMediaReceipt(receipt, request);
  }
  return Object.freeze({
    beginPhase(label: string) {
      return enqueue(async () => {
        if (!identity(label, 64)) throw new MediaTestError("invalid_arguments", "Invalid phase label");
        const id = JSON.stringify([scope.fixtureId, scope.conversationId, connection.sessionId, instance, ++generation]);
        // Invalid acknowledgements retire the previous phase too.
        phase = undefined;
        const ack = await bounded(3000, lifetime.signal, signal => connection.beginPhase(id, label, signal));
        if (!ack || ack.id !== id || ack.label !== label || !Array.isArray(ack.anchors) || !ack.anchors.length ||
            ack.anchors.some(anchor => !anchor || !anchor.clock || !Number.isFinite(anchor.atMs) || !identity(anchor.clock.id, 128) ||
              !["nativeMonotonic", "peerMonotonic"].includes(anchor.clock.domain)))
          throw new MediaTestError("invalid_receipt", "Invalid phase acknowledgement");
        const keys = ack.anchors.map(anchor => `${anchor.clock.domain}:${anchor.clock.id}`);
        if (new Set(keys).size !== keys.length) throw new MediaTestError("invalid_receipt", "Duplicate phase clock");
        phase = Object.freeze({ id, label, anchors: Object.freeze(ack.anchors.map(anchor =>
          Object.freeze({ atMs: anchor.atMs, clock: Object.freeze({ ...anchor.clock }) }))) });
        return phase;
      });
    },
    expectAudio(options: ExpectAudioOptions) { return enqueue(() => expect("audio", options, options.within)); },
    expectSilence(options: ExpectSilenceOptions) { return enqueue(() => expect("silence", options, options.for)); },
    close() {
      if (!closing) {
        lifetime.abort();
        closing = queue.then(() => bounded(3000, new AbortController().signal, () => connection.close()));
      }
      return closing;
    },
  });
}
