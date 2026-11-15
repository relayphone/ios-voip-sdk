import assert from "node:assert/strict";
import { test } from "node:test";
import { createMediaTest, createMarker, validateMediaReceipt, MediaTestError,
  type MediaReadRequest, type MediaReceipt, type MediaSilenceWindow, type MediaTestAdapter } from "../expo/src/testing/index.ts";

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


import { observeSilence } from "./media-test/silence-window.ts";

test("reproduction: a retired gap then a complete clean window passes the shared contract", async () => {
  let now = 0, first = true;
  const observed = await observeSilence(() => ({ connected: true, readerLive: true, trackAvailable: true, samples: 0, energy: 0 }),
    { durationMs: 1000, deadlineMs: 30000, gapLimitMs: 250 },
    { now: () => now, pause: async ms => { now += first ? 300 : Math.min(ms, 20); first = false; } });
  assert.deepEqual(observed.map(w => w.verdict), ["unobserved", "silent"]);
  const windows: MediaSilenceWindow[] = observed.map(w => ({ ...window(w.startMs, w.endMs),
    coveredMs: w.observedMs, monitorTicks: w.ticksMs.length,
    maxGapMs: Math.max(...w.ticksMs.slice(1).map((tick, i) => tick - w.ticksMs[i]!)),
    gaps: w.gaps.map(g => ({ startedAtMs: g.fromMs, endedAtMs: g.toMs })),
    verdict: w.verdict === "silent" ? "silent" : "unobserved" }));
  const media = await createMediaTest(query(), adapter(async q => evidence(q, windows)));
  try {
    await media.beginPhase("mute");
    const result = await media.expectSilence({ direction: "fromDevice", for: 1000 });
    assert.equal(result.receipt.startedAtMs, 300);
    assert.deepEqual(result.receipt.silenceWindows?.map(w => w.verdict), ["unobserved", "silent"]);
    assert.ok(Object.isFrozen(result.receipt.silenceWindows));
    assert.ok(Object.isFrozen(result.receipt.silenceWindows![0]!.gaps[0]));
  } finally { await media.close(); }
});
