import assert from 'node:assert/strict';
import { test } from 'node:test';
import { observeSilence, SilenceObservationError } from './silence-window.ts';
const healthy = { connected: true, readerLive: true, trackAvailable: true };
function fixture(gaps: number[] = [], leakAt = Infinity) {
  let now = 0;
  return { timing: { now: () => now, pause: async (ms: number) => { now += gaps.shift() ?? ms; } },
    read: () => ({ ...healthy, samples: now, energy: now >= leakAt ? now * 0.01 : 0 }) };
}
const options = { durationMs: 1000, deadlineMs: 2000, gapLimitMs: 250 };
test('a stalled attempt is unobserved and the next full continuous window passes', async () => {
  const f = fixture([50, 389]);
  const windows = await observeSilence(f.read, options, f.timing);
  assert.deepEqual(windows.map(w => w.verdict), ['unobserved', 'silent']);
  assert.equal(windows[1]!.observedMs, 1000);
  assert.deepEqual(windows[0]!.gaps, [{ fromMs: 50, toMs: 439, lengthMs: 389, eventLoopLagMs: 339 }]);
  assert.deepEqual(windows[0]!.ticksMs, [0, 50, 439]);
});
test('observed leakage fails immediately even if a later clean window could fit', async () => {
  const f = fixture([], 100);
  await assert.rejects(observeSilence(f.read, options, f.timing), (e: unknown) => {
    assert.ok(e instanceof SilenceObservationError); assert.equal(e.reason, 'leak');
    assert.equal(e.windows.at(-1)!.endMs, 100); return true;
  });
});
test('a gap never discards leakage seen on its returning tick', async () => {
  const f = fixture([389], 100);
  await assert.rejects(observeSilence(f.read, options, f.timing), (e: unknown) => {
    assert.ok(e instanceof SilenceObservationError); assert.equal(e.reason, 'leak');
    assert.equal(e.windows[0]!.gaps.length, 1); return true;
  });
});
test('stalls through the original deadline fail as unobserved with all attempts', async () => {
  const f = fixture([400, 400, 400, 400, 400]);
  await assert.rejects(observeSilence(f.read, options, f.timing), (e: unknown) => {
    assert.ok(e instanceof SilenceObservationError); assert.equal(e.reason, 'unobserved');
    assert.ok(e.windows.every(w => w.verdict === 'unobserved')); assert.equal(e.windows.at(-1)!.endMs, 2000); return true;
  });
});
test('a short clean suffix cannot pass or extend the deadline', async () => {
  const f = fixture([1100]);
  await assert.rejects(observeSilence(f.read, options, f.timing), (e: unknown) => {
    assert.ok(e instanceof SilenceObservationError); assert.equal(e.reason, 'unobserved');
    assert.equal(e.windows.at(-1)!.observedMs, 900); return true;
  });
});
test('the original gap limit remains inclusive', async () => {
  const f = fixture([250, 250, 250, 250]);
  const windows = await observeSilence(f.read, options, f.timing);
  assert.equal(windows.length, 1); assert.equal(windows[0]!.verdict, 'silent');
  assert.equal(windows[0]!.observedMs, 1000);
});
test('observed leakage after an unobserved attempt still fails immediately', async () => {
  const f = fixture([389], 500);
  await assert.rejects(observeSilence(f.read, options, f.timing), (e: unknown) => {
    assert.ok(e instanceof SilenceObservationError); assert.equal(e.reason, 'leak');
    assert.deepEqual(e.windows.map(w => w.verdict), ['unobserved', 'leak']); return true;
  });
});
test('a missing reader never certifies silence', async () => {
  const f = fixture();
  await assert.rejects(observeSilence(() => ({ ...f.read(), readerLive: false }), options, f.timing), (e: unknown) => {
    assert.ok(e instanceof SilenceObservationError); assert.equal(e.reason, 'unavailable'); return true;
  });
});
