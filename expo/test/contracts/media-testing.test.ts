import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  createMediaTest, createMarker, markerSamples, emissionSamples, detectMarker, validateMediaReceipt, MediaTestError,
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
  return { ...target, schemaVersion: 1, profile: "tones-v2", conversationId: query.conversationId, fixtureId: query.fixtureId,
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

test("tones-v2 has twelve guarded sixty-millisecond slots", () => {
  const marker = createMarker("parity-v2");
  assert.equal(marker.profile, "tones-v2");
  assert.equal(marker.slotMs, 60);
  assert.equal(marker.frequencies.length, 12);
});

test("tones-v2 PCM16 LE parity vectors match at 8 and 48 kHz", () => {
  for (const [rate, expected] of [
    [8000, "7305be4e1d4ba73d2f2f876869fa5cb27c12bb91450081452139f41262f7c003"],
    [48000, "82f79efb9f1b24a5c839cd500f5c9ad291ef5969348c3d68b775fcef6f8fa3b4"],
  ] as const) {
    const pcm = markerSamples(createMarker("parity-v2"), rate, rate * 0.72);
    const bytes = Buffer.alloc(pcm.length * 2);
    pcm.forEach((value, index) => bytes.writeInt16LE(Math.round(value * 32767), index * 2));
    assert.equal(createHash("sha256").update(bytes).digest("hex"), expected);
  }
});

test("1020 ms emission PCM16 LE parity vectors match at 8 and 48 kHz", () => {
  for (const [rate, expected] of [
    [8000, "e339576ee90e3d72ef65c7a5e44ab4a74345be472fdcd39b8f25072448a5fbab"],
    [48000, "0a79ca1399b4fc018584bcf8e90be7c476618fab47f903b9670ce1282eafbaa1"],
  ] as const) {
    const pcm = emissionSamples(createMarker("parity-v2"), rate, rate / 50 * 51);
    const bytes = Buffer.alloc(pcm.length * 2);
    pcm.forEach((value, index) => bytes.writeInt16LE(Math.round(value * 32767), index * 2));
    assert.equal(createHash("sha256").update(bytes).digest("hex"), expected);
  }
});

test("emission preserves the marker bytes and chunk continuity across both rolls", () => {
  const marker = createMarker("emission");
  for (const rate of [8000, 8050, 44100, 48000]) {
    const cycle = rate / 50 * 51, pre = Math.round(rate * 3 / 20), length = rate / 50 * 36;
    const pcm = emissionSamples(marker, rate, cycle * 2);
    assert.deepEqual(pcm.slice(pre, pre + length), markerSamples(marker, rate, length));
    assert.deepEqual(pcm.slice(cycle), pcm.slice(0, cycle));
    const split = new Float32Array(pcm.length);
    for (let offset = 0; offset < pcm.length; offset += 137)
      split.set(emissionSamples(marker, rate, Math.min(137, pcm.length - offset), offset), offset);
    assert.deepEqual(split, pcm);
    assert.ok(pcm.slice(0, pre).some(value => Math.abs(value) > 0.19));
    assert.ok(pcm.slice(pre + length, cycle).some(value => Math.abs(value) > 0.19));
    assert.equal(pcm[0], 0);
  }
  assert.throws(() => emissionSamples(marker, 7999, 10), code("invalid_arguments"));
  assert.throws(() => emissionSamples(marker, 8000, 10, Number.MAX_SAFE_INTEGER), code("invalid_arguments"));
});

test("a truncated post-roll cannot excuse a missing or corrupted marker slot", () => {
  const rate = 48000, marker = createMarker("truncated-emission");
  const pcm = emissionSamples(marker, rate, rate * 0.97); // Last 50 ms of post-roll absent.
  assert.ok(detectMarker(pcm, rate, marker)!.confidence >= 0.8);
  const missing = pcm.slice();
  missing.fill(0, rate * 0.81, rate * 0.87); // The final marker slot, including its scored center.
  assert.equal(detectMarker(missing, rate, marker), null);
  const wrong = pcm.slice();
  for (let i = rate * 0.81; i < rate * 0.87; i++) wrong[i] = 0.2 * Math.sin(2 * Math.PI * 2300 * i / rate);
  assert.equal(detectMarker(wrong, rate, marker), null);
});

test("twenty-millisecond transition smear passes through the scoring guards", () => {
  for (const rate of [8000, 48000]) {
    const marker = createMarker("guarded-transition"), pcm = markerSamples(marker, rate, rate * 0.72);
    // A two-tap FIR spanning one codec frame mixes the previous tone into each transition.
    // Keep the original window length so a detector cannot evade the transition by shifting it.
    const smeared = pcm.map((value, index) => 0.3 * value +
      0.7 * (index < rate / 50 ? 0 : pcm[index - rate / 50]!));
    assert.ok(detectMarker(smeared, rate, marker)!.confidence >= 0.8);
    for (const kind of ["missing", "wrong", "quiet"] as const) {
      const damaged = pcm.slice();
      for (let index = rate * 0.24; index < rate * 0.30; index++) {
        damaged[index] = kind === "missing" ? 0 : kind === "quiet" ? damaged[index]! * 0.01
          : 0.2 * Math.sin(2 * Math.PI * 2300 * index / rate);
      }
      assert.equal(detectMarker(damaged, rate, marker), null, kind);
    }
  }
});

test("receipt profile and full 720 ms marker are mandatory", () => {
  const query = request(), receipt = evidence(query);
  const exact = { ...receipt, endedAtMs: 1720, sampleCount: 34560, frameCount: 36, monitorTicks: 36,
    marker: detectMarker(markerSamples(query.marker, 48000, 34560), 48000, query.marker) };
  assert.equal(validateMediaReceipt(exact, { ...query, durationMs: 720 }).expectation, "audio");
  assert.throws(() => validateMediaReceipt(exact, { ...query, durationMs: 719 }), code("audio_missing"));
  assert.throws(() => validateMediaReceipt({ ...exact, sampleCount: 34559 }, query), code("invalid_receipt"));
  for (const profile of ["tones-v1", "other", undefined]) {
    assert.throws(() => validateMediaReceipt({ ...receipt, profile }, query), code("invalid_receipt"));
    assert.throws(() => validateMediaReceipt({ ...evidence(request("silence"), true), profile }, request("silence")), code("invalid_receipt"));
  }
  assert.throws(() => validateMediaReceipt(receipt, { ...query,
    marker: { ...query.marker, slotMs: 20 } as unknown as typeof query.marker }), code("invalid_receipt"));
});

test("the phase marker survives attenuation, offset and native sample rates", () => {
  const marker = createMarker("run:phase-1");
  for (const rate of [8000, 16000, 44100, 48000]) {
    const offset = rate / 100;
    const pcm = new Float32Array(rate);
    pcm.set(markerSamples(marker, rate, rate - offset).map(value => value * 0.2), offset);
    const found = detectMarker(pcm, rate, marker);
    assert.ok(Math.abs(found!.offsetSamples - offset) <= rate / 50);
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
  const query = request(), original = evidence(query);
  const receipt = { ...original, marker: { ...original.marker!, offsetSamples: 480,
    slotStarts: original.marker!.slotStarts.map(start => start + 480) } };
  assert.equal(validateMediaReceipt(receipt, query).firstAudioAfterPhaseMs, 10);
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
    "import { createMarker, createMediaTest, emissionSamples } from '@relayphone/ios-voip-sdk/testing';",
    "console.log(createMarker('export-check').profile);",
    "if (emissionSamples(createMarker('export-check'), 8000, 8160).length !== 8160) throw new Error('emission export');",
    "try { await createMediaTest({conversationId:'call',fixtureId:'fixture'}); }",
    "catch(error) { console.log(error.code); }",
  ].join("\n");
  const output = execFileSync(process.execPath, ["--input-type=module", "-e", script], {
    cwd: fileURLToPath(new URL("../../", import.meta.url)), encoding: "utf8", timeout: 5000,
  });
  assert.equal(output, "tones-v2\nunavailable\n");
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

test("unstretched emissions have zero relative slot drift and receipts keep alignment", () => {
  for (const rate of [8000, 48000]) {
    const marker = createMarker("zero-drift"), found = detectMarker(emissionSamples(marker, rate, rate * 1.02), rate, marker)!;
    assert.ok(found);
    assert.deepEqual(found.slotStarts.map((start, index) => start - found.offsetSamples - index * rate * 0.06), Array(12).fill(0));
    assert.ok(Object.isFrozen(found.slotStarts));
  }
  const query = request(), receipt = evidence(query);
  const checked = validateMediaReceipt(receipt, query).receipt.marker!;
  assert.deepEqual(checked.slotStarts, receipt.marker!.slotStarts);
  assert.ok(Object.isFrozen(checked.slotStarts));
  for (const slotStarts of [undefined, [], receipt.marker!.slotStarts.slice(1),
    receipt.marker!.slotStarts.map((start, index) => start + (index === 5 ? 800 : 0)),
    receipt.marker!.slotStarts.map((start, index) => start + index * 300)])
    assert.throws(() => validateMediaReceipt({ ...receipt, marker: { ...receipt.marker!, slotStarts } }, query), code("invalid_receipt"));
});

test("wrong profile tones in any slot, arbitrary 400 Hz and seeded noise never detect", () => {
  const rate = 8000, marker = createMarker("wrong-each-slot"), pre = rate * 0.15;
  for (let slot = 0; slot < 12; slot++) {
    const pcm = emissionSamples(marker, rate, rate * 1.02);
    const frequency = [650, 950, 1350, 1850].find(value => value !== marker.frequencies[slot])!;
    for (let index = pre + slot * 480; index < pre + (slot + 1) * 480; index++)
      pcm[index] = 0.2 * Math.sin(2 * Math.PI * frequency * index / rate);
    assert.equal(detectMarker(pcm, rate, marker), null, `wrong slot ${slot}`);
  }
  let seed = 12345;
  const noise = Float32Array.from({ length: rate * 2 }, () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return (seed / 2 ** 32 - 0.5) * 0.4; });
  const tone = Float32Array.from({ length: rate * 2 }, (_, i) => 0.2 * Math.sin(2 * Math.PI * 400 * i / rate));
  assert.equal(detectMarker(noise, rate, marker), null);
  assert.equal(detectMarker(tone, rate, marker), null);
});

test("elastic timing tracks either direction and rejects cumulative alignment beyond the cap", () => {
  const rate = 8000, marker = createMarker("parity-v2"), pre = rate * 0.15;
  for (const scale of [0.8, 0.92, 1.08, 1.2]) {
    const count = Math.round(rate * 0.72 * scale), pcm = new Float32Array(pre + count + pre);
    const baseline = emissionSamples(marker, rate, rate * 1.02);
    pcm.set(baseline.subarray(0, pre));
    pcm.set(baseline.subarray(pre + rate * 0.72), pre + count);
    for (let index = 0; index < count; index++) {
      const slot = Math.min(11, Math.floor(index / (rate * 0.06 * scale)));
      const local = index - slot * rate * 0.06 * scale;
      const source = local / scale;
      const fade = Math.min(1, Math.min(source, rate * 0.06 - source) / (rate * 0.005));
      pcm[pre + index] = 0.2 * 0.5 * (1 - Math.cos(Math.PI * fade)) *
        Math.sin(2 * Math.PI * marker.frequencies[slot]! * local / rate);
    }
    const found = detectMarker(pcm, rate, marker);
    if (scale === 0.8 || scale === 1.2) assert.equal(found, null);
    else {
      assert.ok(found);
      const drift = found.slotStarts.at(-1)! - found.offsetSamples - 11 * rate * 0.06;
      assert.ok(scale < 1 ? drift < 0 : drift > 0);
      assert.ok(Math.abs(drift) <= rate * 0.06);
    }
  }
});
