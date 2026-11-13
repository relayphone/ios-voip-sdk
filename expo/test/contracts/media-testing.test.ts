import assert from "node:assert/strict";
import { test } from "node:test";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  createMediaTest, createMarker, markerSamples, detectMarker, validateMediaReceipt, MediaTestError,
  type MediaCapability, type MediaReadRequest, type MediaReceipt, type MediaTestAdapter, type MediaObservation,
} from "../../src/testing/index.ts";

const native = { domain: "nativeMonotonic", id: "native-1" } as const;
const peer = { domain: "peerMonotonic", id: "peer-1" } as const;
const capabilities: readonly MediaCapability[] = [
  { direction: "toDevice", stage: "output", ...native },
  { direction: "toDevice", stage: "decoded", ...native },
  { direction: "fromDevice", stage: "farEnd", ...peer },
];
function request(expectation: "audio" | "silence" = "audio"): MediaReadRequest {
  return { conversationId: "call" as MediaReadRequest["conversationId"], fixtureId: "fixture",
    direction: "toDevice", stage: "output", expectation, durationMs: 1000, clock: native,
    phase: { id: "fixture:1", label: "answered", anchors: [{ clock: native, atMs: 1000 }] },
    marker: createMarker("fixture:1") };
}
function evidence(query: MediaReadRequest, silent = false): MediaReceipt {
  const rate = 48000;
  const pcm = silent ? new Float32Array(rate) : markerSamples(query.marker, rate, rate);
  let energy = 0, peak = 0;
  for (const value of pcm) { energy += value * value; peak = Math.max(peak, Math.abs(value)); }
  const start = query.phase.anchors.find(anchor => anchor.clock.id === query.clock.id)!.atMs;
  const target: MediaObservation = query.direction === "toDevice"
    ? { direction: query.direction, stage: query.stage } : { direction: query.direction, stage: query.stage };
  return { ...target, schemaVersion: 1, conversationId: query.conversationId, fixtureId: query.fixtureId,
    phaseId: query.phase.id, clock: query.clock,
    tap: "active", startedAtMs: start, endedAtMs: start + 1000,
    sampleRate: rate, sampleCount: pcm.length, frameCount: 50, overflowFrames: 0,
    monitorTicks: 50, maxGapMs: 20, rms: Math.sqrt(energy / pcm.length), peak,
    marker: detectMarker(pcm, rate, query.marker) };
}
function code(expected: string): (error: unknown) => boolean {
  return error => { assert.ok(error instanceof MediaTestError); assert.equal(error.code, expected); return true; };
}
function harness(available = capabilities) {
  let reads = 0, closes = 0, phases = 0;
  const requests: MediaReadRequest[] = [];
  let respond = async (query: MediaReadRequest, _signal: AbortSignal): Promise<unknown> => evidence(query, query.expectation === "silence");
  const adapter: MediaTestAdapter = {
    async open() { return {
      sessionId: "native-session",
      capabilities: available,
      async beginPhase(id, label) {
        phases++;
        return { id, label, anchors: [native, peer].map(clock => ({ clock, atMs: phases * 1000 })) };
      },
      async read(query, signal) { reads++; requests.push(query); return respond(query, signal); },
      async close() { closes++; },
    }; },
  };
  return { adapter, requests, get reads() { return reads; }, get closes() { return closes; },
    respond(next: typeof respond) { respond = next; } };
}

test("the phase marker survives attenuation, offset and native sample rates", () => {
  const marker = createMarker("run:phase-1");
  for (const rate of [8000, 16000, 44100, 48000]) {
    const offset = rate / 100;
    const pcm = new Float32Array(rate);
    pcm.set(markerSamples(marker, rate, rate - offset).map(value => value * 0.2), offset);
    const found = detectMarker(pcm, rate, marker);
    assert.ok(Math.abs(found!.offsetSamples - offset) <= Math.ceil(rate / 1000));
    assert.equal(found?.id, marker.id);
    assert.ok(found!.confidence >= 0.8);
  }
});
test("zero, wrong-phase, partial and constant-tone controls cannot pass marker detection", () => {
  const expected = createMarker("run:phase-1"), rate = 48000;
  const constant = Float32Array.from({ length: rate }, (_, i) => 0.2 * Math.sin(2 * Math.PI * 650 * i / rate));
  for (const pcm of [new Float32Array(rate), markerSamples(createMarker("run:phase-2"), rate, rate),
    markerSamples(expected, rate, 100), constant]) assert.equal(detectMarker(pcm, rate, expected), null);
  assert.throws(() => markerSamples(expected, 47999, 10), code("invalid_arguments"));
  assert.throws(() => markerSamples({ ...expected, frequencies: [] }, rate, 10), code("invalid_arguments"));
});
test("streamed sample chunks preserve the same marker waveform", () => {
  const marker = createMarker("chunked"), whole = markerSamples(marker, 48000, 48000);
  const split = new Float32Array(48000);
  for (let offset = 0; offset < 48000; offset += 480) split.set(markerSamples(marker, 48000, 480, offset), offset);
  assert.deepEqual(split, whole);
});
test("receipt validation uses matching observer clocks and a complete marker", () => {
  const query = request(), receipt = evidence(query);
  assert.equal(validateMediaReceipt(receipt, query).firstAudioAfterPhaseMs, 0);
  assert.ok(Object.isFrozen(validateMediaReceipt(receipt, query).receipt));
  assert.throws(() => validateMediaReceipt({ ...receipt, marker: { ...receipt.marker!, confidence: 0.2 } }, query), code("audio_missing"));
  assert.throws(() => validateMediaReceipt({ ...receipt, marker: { ...receipt.marker!, id: "other" } }, query), code("audio_missing"));
  assert.throws(() => validateMediaReceipt({ ...receipt, startedAtMs: 1900, endedAtMs: 2900 }, query), code("audio_missing"));
});
test("stale, cross-call, wrong-stage, missing and incomplete evidence controls fail", () => {
  const query = request(), receipt = evidence(query);
  for (const mutation of [
    { phaseId: "old" }, { fixtureId: "other" }, { conversationId: "other" }, { direction: "fromDevice" },
    { stage: "decoded" }, { clock: peer }, { schemaVersion: 2 }, { startedAtMs: 999 },
    { endedAtMs: 1000 }, { monitorTicks: 0 }, { maxGapMs: 200 }, { overflowFrames: 1 },
    { sampleCount: 0 }, { sampleRate: 7 }, { rms: NaN }, { peak: 2 },
  ]) assert.throws(() => validateMediaReceipt({ ...receipt, ...mutation, passed: true }, query), code("invalid_receipt"));
  assert.throws(() => validateMediaReceipt({ ...receipt, tap: "missing" }, query), code("capability_missing"));
  for (const missing of [null, {}, { ...receipt, marker: undefined }])
    assert.throws(() => validateMediaReceipt(missing, query), code("invalid_receipt"));
});
test("silence needs live monitoring; zero received samples alone are not proof", () => {
  const query = request("silence"), silent = evidence(query, true);
  assert.equal(validateMediaReceipt(silent, query).expectation, "silence");
  const noPackets = { ...silent, sampleCount: 0, frameCount: 0 };
  assert.equal(validateMediaReceipt(noPackets, query).expectation, "silence");
  assert.throws(() => validateMediaReceipt({ ...noPackets, monitorTicks: 0 }, query), code("invalid_receipt"));
  assert.throws(() => validateMediaReceipt({ ...noPackets, tap: "missing" }, query), code("capability_missing"));
  assert.throws(() => validateMediaReceipt({ ...silent, endedAtMs: 1500 }, query), code("invalid_receipt"));
  assert.throws(() => validateMediaReceipt({ ...silent, startedAtMs: 1010, endedAtMs: 2010 }, query), code("invalid_receipt"));
  assert.throws(() => validateMediaReceipt(evidence(query), query), code("audio_leak"));
  assert.throws(() => validateMediaReceipt({ ...silent, peak: 0.02 }, query), code("audio_leak"));
});
test("the same interface observes both directions and defaults to real output", async () => {
  const h = harness();
  const media = await createMediaTest(request(), h.adapter);
  try {
    await assert.rejects(media.expectAudio({ direction: "toDevice", within: 1000 }), code("phase_required"));
    const phase = await media.beginPhase("answered");
    assert.ok(Object.isFrozen(phase.anchors[0]?.clock));
    assert.equal((await media.expectAudio({ direction: "toDevice", within: 1000 })).receipt.stage, "output");
    assert.equal((await media.expectAudio({ direction: "fromDevice", within: 1000 })).receipt.stage, "farEnd");
    await media.beginPhase("muted");
    await media.expectSilence({ direction: "fromDevice", for: 1000 });
    assert.equal(h.requests[0]?.marker.id, phase.id);
    assert.notEqual(h.requests[2]?.marker.id, phase.id);
    assert.equal(h.requests[2]?.marker.id, h.requests[2]?.phase.id);
  } finally { await media.close(); }
  await media.close();
  assert.equal(h.closes, 1);
  await assert.rejects(media.beginPhase("later"), code("closed"));
});
test("missing output capability cannot fall back to decoded audio or silence", async () => {
  const h = harness(capabilities.filter(capability => capability.stage !== "output"));
  const media = await createMediaTest(request(), h.adapter);
  try {
    await media.beginPhase("answered");
    await assert.rejects(media.expectSilence({ direction: "toDevice", for: 1000 }), code("capability_missing"));
    assert.equal(h.reads, 0);
    await media.expectAudio({ direction: "toDevice", stage: "decoded", within: 1000 });
    // @ts-expect-error Invalid native/JavaScript input is also rejected at runtime.
    await assert.rejects(media.expectAudio({ direction: "toDevice", stage: "farEnd", within: 1000 }), code("invalid_arguments"));
    await assert.rejects(media.expectAudio({ direction: "fromDevice", within: 0 }), code("invalid_arguments"));
  } finally { await media.close(); }
  await assert.rejects(createMediaTest(request()), code("unavailable"));
});
test("beginPhase invalidates prior evidence rather than relabelling it", async () => {
  const h = harness(), media = await createMediaTest(request(), h.adapter);
  try {
    await media.beginPhase("answered");
    const previous = (await media.expectAudio({ direction: "toDevice", within: 1000 })).receipt;
    h.respond(async () => previous);
    await media.beginPhase("recovered");
    await assert.rejects(media.expectAudio({ direction: "toDevice", within: 1000 }), code("invalid_receipt"));
  } finally { await media.close(); }
});
test("close cancels an active read and permanently retires the test", async () => {
  const h = harness(), media = await createMediaTest(request(), h.adapter);
  let entered!: () => void;
  const active = new Promise<void>(resolve => { entered = resolve; });
  let aborted = false;
  h.respond(async (_query, signal) => {
    signal.addEventListener("abort", () => { aborted = true; }, { once: true });
    entered(); return await new Promise(() => {});
  });
  await media.beginPhase("answered");
  const read = media.expectAudio({ direction: "toDevice", within: 1000 });
  const rejected = assert.rejects(read, code("closed"));
  await active;
  await media.close(); await rejected;
  assert.equal(aborted, true);
  assert.equal(h.closes, 1);
});
test("unresponsive adapters have a bounded deadline", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const h = harness(), media = await createMediaTest(request(), h.adapter);
  try {
    await media.beginPhase("answered");
    h.respond(async () => await new Promise(() => {}));
    const pending = media.expectAudio({ direction: "toDevice", within: 1000 });
    const rejected = assert.rejects(pending, code("deadline_exceeded"));
    await Promise.resolve(); await Promise.resolve();
    t.mock.timers.tick(1000); await rejected;
  } finally { await media.close(); }
});
test("the built testing subpath loads without a native or LiveKit runtime", () => {
  const script = [
    "import { createMarker, createMediaTest } from '@relayphone/ios-voip-sdk/testing';",
    "console.log(createMarker('export-check').profile);",
    "try { await createMediaTest({conversationId:'call',fixtureId:'fixture'}); }",
    "catch(error) { console.log(error.code); }",
  ].join("\n");
  const output = execFileSync(process.execPath, ["--input-type=module", "-e", script], {
    cwd: fileURLToPath(new URL("../../", import.meta.url)), encoding: "utf8", timeout: 5000,
  });
  assert.equal(output, "tones-v1\nunavailable\n");
});
test("adapter errors are typed without exposing native payloads", async () => {
  const h = harness(), media = await createMediaTest(request(), h.adapter);
  try {
    await media.beginPhase("answered");
    h.respond(async () => { throw new Error("private native payload"); });
    await assert.rejects(media.expectAudio({ direction: "toDevice", within: 1000 }), error => {
      assert.ok(error instanceof MediaTestError);
      assert.equal(error.code, "adapter_failed");
      assert.equal(error.message.includes("private"), false);
      return true;
    });
  } finally { await media.close(); }
});
test("an open that finishes after its deadline closes its late native resource", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let finish!: (value: Awaited<ReturnType<MediaTestAdapter["open"]>>) => void;
  let closed = 0;
  const adapter: MediaTestAdapter = { open: async () => await new Promise(resolve => { finish = resolve; }) };
  const pending = createMediaTest(request(), adapter);
  const rejected = assert.rejects(pending, code("deadline_exceeded"));
  await Promise.resolve(); await Promise.resolve();
  t.mock.timers.tick(3000); await rejected;
  finish({ sessionId: "late-open", capabilities, async beginPhase() { throw new Error("unused"); },
    async read() { throw new Error("unused"); }, async close() { closed++; } });
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  assert.equal(closed, 1);
});
test("new sessions reject delayed PCM from an earlier call sharing the fixture", async () => {
  const h = harness();
  const first = await createMediaTest(request(), h.adapter);
  const oldPhase = await first.beginPhase("answered");
  const oldMarker = createMarker(oldPhase.id);
  await first.close();
  // Even a faulty test adapter reusing its ID cannot reuse the marker in this JS lifetime.
  const second = await createMediaTest(request(), h.adapter);
  try {
    const next = await second.beginPhase("answered");
    assert.notEqual(next.id, oldPhase.id);
    h.respond(async query => ({ ...evidence(query), marker: detectMarker(markerSamples(oldMarker, 48000, 48000), 48000, query.marker) }));
    await assert.rejects(second.expectAudio({ direction: "toDevice", within: 1000 }), code("audio_missing"));
  } finally { await second.close(); }
});
test("malformed marker profiles cannot manufacture a detection from silence", () => {
  const marker = createMarker("phase");
  for (const invalid of [
    { ...marker, frequencies: [] }, { ...marker, frequencies: [650] },
    { ...marker, frequencies: marker.frequencies.map(() => 650) },
    { ...marker, slotMs: 0 } as unknown as typeof marker,
    { ...marker, profile: "other" } as unknown as typeof marker,
  ]) assert.throws(() => detectMarker(new Float32Array(48000), 48000, invalid), code("invalid_arguments"));
});
test("missing session identity fails and closes the opened adapter", async () => {
  let closed = false;
  const adapter: MediaTestAdapter = { async open() { return {
    sessionId: "", capabilities, async beginPhase() { throw new Error("unused"); },
    async read() { throw new Error("unused"); }, async close() { closed = true; },
  }; } };
  await assert.rejects(createMediaTest(request(), adapter), code("invalid_receipt"));
  assert.equal(closed, true);
});
test("maximum accepted identities remain usable after phase JSON escaping", async () => {
  const base = request();
  const adapter: MediaTestAdapter = { async open() { return {
    sessionId: "\u0001".repeat(128), capabilities,
    async beginPhase(id, label) { return { id, label, anchors: [{ clock: native, atMs: 1000 }] }; },
    async read(query) { return evidence(query); }, async close() {},
  }; } };
  const media = await createMediaTest({ fixtureId: "\u0001".repeat(128),
    conversationId: "\u0001".repeat(256) as typeof base.conversationId }, adapter);
  try {
    const phase = await media.beginPhase("answered");
    assert.ok(phase.id.length > 1024);
    await media.expectAudio({ direction: "toDevice", within: 1000 });
  } finally { await media.close(); }
});
