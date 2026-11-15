import assert from "node:assert/strict";
import { test } from "node:test";
import { createMediaTest, createMarker, validateMediaReceipt, MediaTestError,
  type MediaReadRequest, type MediaReceipt, type MediaSilenceWindow, type MediaTestAdapter } from "../../src/testing/index.ts";

const clock = { domain: "peerMonotonic", id: "silence-peer" } as const;
function query(withinMs = 30000): MediaReadRequest {
  return { conversationId: "call" as MediaReadRequest["conversationId"], fixtureId: "silence",
    direction: "fromDevice", stage: "farEnd", clock, expectation: "silence", durationMs: 1000, withinMs,
    marker: createMarker("phase"), phase: { id: "phase", label: "mute", anchors: [{ clock, atMs: 0 }] } };
}
function window(startedAtMs = 0, endedAtMs = startedAtMs + 1000): MediaSilenceWindow {
  return { startedAtMs, endedAtMs, coveredMs: endedAtMs - startedAtMs, gaps: [], verdict: "silent",
    sampleRate: 48000, sampleCount: 0, frameCount: 0, overflowFrames: 0,
    monitorTicks: Math.ceil((endedAtMs - startedAtMs) / 20), maxGapMs: 20, rms: 0, peak: 0, marker: null };
}
function evidence(q: MediaReadRequest, windows: readonly MediaSilenceWindow[]): MediaReceipt {
  return { ...q, ...windows.at(-1)!, schemaVersion: 1, profile: "tones-v2", phaseId: q.phase.id,
    tap: "active", silenceWindows: windows };
}
function code(expected: string) {
  return (error: unknown) => { assert.ok(error instanceof MediaTestError); assert.equal(error.code, expected); return true; };
}
function adapter(read: (q: MediaReadRequest, signal: AbortSignal) => Promise<unknown>): MediaTestAdapter {
  return { open: async () => ({ sessionId: "silence-session", capabilities: [{ ...clock, direction: "fromDevice", stage: "farEnd" }],
    beginPhase: async (id, label) => ({ id, label, anchors: [{ clock, atMs: 0 }] }), read, close: async () => {} }) };
}


test("a leak anywhere fails even when a later window is clean and retains attempts", () => {
  const q = query();
  for (const leak of [{ rms: 0.004, peak: 0.01 }, { rms: 0, peak: 0.02 }, { verdict: "leak" as const }]) {
    const windows = [{ ...window(), sampleCount: 48000, frameCount: 50, ...leak }, window(1000)];
    assert.throws(() => validateMediaReceipt(evidence(q, windows), q), error => {
      assert.ok(code("audio_leak")(error));
      assert.equal((error as MediaTestError).receipt?.silenceWindows?.length, 2); return true;
    });
  }
});

test("no complete clean window in the budget fails as unobserved with all attempts", () => {
  const q = query(2000), windows = [{ ...window(0, 800), verdict: "unobserved" as const },
    { ...window(800, 2000), coveredMs: 900, maxGapMs: 300,
      gaps: [{ startedAtMs: 800, endedAtMs: 1100 }], verdict: "unobserved" as const }];
  assert.throws(() => validateMediaReceipt(evidence(q, windows), q), error => {
    assert.ok(code("unobserved")(error));
    assert.equal((error as MediaTestError).receipt?.silenceWindows?.length, 2); return true;
  });
});

test("window history rejects reordered, overlapping, out-of-budget and fabricated coverage", () => {
  const q = query(2000);
  for (const windows of [
    [window(1000), window()], [window(0, 1200), window(1000)], [window(-1)], [window(1001)],
    [{ ...window(), coveredMs: 1001 }], [{ ...window(), coveredMs: NaN }],
    [{ ...window(), gaps: [{ startedAtMs: -1, endedAtMs: 20 }] }],
    [{ ...window(), gaps: [{ startedAtMs: 100, endedAtMs: 90 }] }],
    [{ ...window(), gaps: [{ startedAtMs: 10, endedAtMs: 20 }, { startedAtMs: 15, endedAtMs: 30 }] }],
    [{ ...window(), coveredMs: 1000, gaps: [{ startedAtMs: 10, endedAtMs: 30 }] }],
  ]) assert.throws(() => validateMediaReceipt(evidence(q, windows), q), code("invalid_receipt"));
  assert.throws(() => validateMediaReceipt({ ...evidence(q, [window()]), silenceWindows: [] }, q), code("unobserved"));
  assert.throws(() => validateMediaReceipt({ ...evidence(q, [window()]), silenceWindows: undefined }, q), code("invalid_receipt"));
});

test("existing gap, PCM, monitoring and silence thresholds remain enforced", () => {
  const q = query();
  for (const change of [{ maxGapMs: 41 }, { overflowFrames: 1 }, { monitorTicks: 1 },
    { coveredMs: 999 }]) {
    const windows = [{ ...window(), ...change }];
    assert.throws(() => validateMediaReceipt(evidence(q, windows), q), code("unobserved"));
  }
  assert.equal(validateMediaReceipt(evidence(q, [{ ...window(), rms: 0.003, peak: 0.01,
    sampleCount: 48000, frameCount: 50 }]), q).expectation, "silence");
  assert.throws(() => validateMediaReceipt({ ...evidence(q, [window()]), tap: "missing" }, q), code("capability_missing"));
});

test("within equals for preserves strict-from-anchor behavior and first clean window wins", () => {
  const q = query(1000);
  assert.equal(validateMediaReceipt(evidence(q, [window()]), q).expectation, "silence");
  assert.throws(() => validateMediaReceipt(evidence(q, [window(1)]), q), code("invalid_receipt"));
  const both = [window(), window(1000)];
  assert.throws(() => validateMediaReceipt(evidence(query(), both), query()), code("invalid_receipt"));
});

test("silence durations and budgets are bounded integer milliseconds; default budget is 30 seconds", async () => {
  let reads = 0;
  const media = await createMediaTest(query(), adapter(async q => { reads++;
    assert.equal(q.durationMs, 1000); assert.equal(q.withinMs, 30000); return evidence(q, [window()]); }));
  try {
    await media.beginPhase("mute");
    for (const options of [{ for: 1000, within: 999 }, { for: 0 }, { for: 1.5 }, { for: 60001 },
      { for: 1, within: 60001 }, { for: 1, within: Infinity }, { for: 1, within: 1.5 },
      { for: 1, within: null as unknown as number }])
      await assert.rejects(media.expectSilence({ direction: "fromDevice", ...options }), code("invalid_arguments"));
    assert.equal(reads, 0);
    await media.expectSilence({ direction: "fromDevice", for: 1000 });
  } finally { await media.close(); }
});

test("silence reads use the budget rather than the required duration and abort as unobserved", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.mock.method(performance, "now", () => 0);
  const entered = Promise.withResolvers<AbortSignal>();
  const media = await createMediaTest(query(), adapter(async (_q, signal) => {
    entered.resolve(signal); return new Promise(() => {});
  }));
  try {
    await media.beginPhase("mute");
    const pending = media.expectSilence({ direction: "fromDevice", for: 1000, within: 2000 });
    const signal = await entered.promise;
    t.mock.timers.tick(1999);
    assert.equal(signal.aborted, false);
    t.mock.timers.tick(1);
    await assert.rejects(pending, code("unobserved"));
    assert.equal(signal.aborted, true);
  } finally { await media.close(); }
});

test("queued silence reads cannot renew a phase budget", async t => {
  let now = 0, reads = 0;
  t.mock.method(performance, "now", () => now);
  const media = await createMediaTest(query(), adapter(async q => { reads++; return evidence(q, [window()]); }));
  try {
    await media.beginPhase("mute");
    now = 500;
    await media.expectSilence({ direction: "fromDevice", for: 1000, within: 2000 });
    now = 2000;
    await assert.rejects(media.expectSilence({ direction: "fromDevice", for: 1000, within: 2000 }), code("unobserved"));
    assert.equal(reads, 1);
    await media.beginPhase("muted-again");
    await media.expectSilence({ direction: "fromDevice", for: 1000, within: 2000 });
    assert.equal(reads, 2);
  } finally { await media.close(); }
});

test("a full 60-second budget and duration are accepted", () => {
  const q = { ...query(60000), durationMs: 60000 };
  assert.equal(validateMediaReceipt(evidence(q, [window(0, 60000)]), q).expectation, "silence");
});
