import assert from 'node:assert/strict';
import { test } from 'node:test';
import { monitorReceiver, ReceiverObservationError } from './peer-window.ts';
const healthy = { connected: true, readerLive: true, trackAvailable: true };
const budget = { deadlineMs: 30000 };
function clock(steps: number[] = []) {
  let now = 0;
  return { now: () => now, pause: async (ms: number) => { now += steps.shift() ?? ms; } };
}
test('muted publication can have no samples while its observer remains independently live', async () => {
  const windows = await monitorReceiver(() => healthy, budget, clock());
  assert.equal(windows.length, 1);
  assert.equal(windows[0].verdict, 'observed');
  assert.equal(windows[0].observedMs, 1000);
  assert.equal(windows[0].endMs, 1000);
});
for (const key of ['connected', 'readerLive', 'trackAvailable'] as const) {
  test('a missing ' + key + ' fails immediately, including a tick returning from a gap', async () => {
    for (const steps of [[], [500]]) {
      const time = clock(steps);
      await assert.rejects(monitorReceiver(() => ({ ...healthy, [key]: time.now() < 500 }), budget, time), error => {
        assert.ok(error instanceof ReceiverObservationError);
        assert.equal(error.reason, 'unavailable');
        assert.deepEqual(error.health, { ...healthy, [key]: false });
        assert.equal(error.windows.length, 1);
        assert.equal(error.windows[0].verdict, 'unavailable');
        assert.equal(time.now(), 500);
        return true;
      });
    }
  });
}
test('health lost at the final observation cannot qualify the window', async () => {
  const time = clock();
  await assert.rejects(monitorReceiver(() => ({ ...healthy, readerLive: time.now() < 1000 }), budget, time), error => {
    assert.ok(error instanceof ReceiverObservationError);
    assert.equal(error.reason, 'stopped');
    assert.equal(error.health.readerLive, false);
    return true;
  });
});
test('the reported 254.67 ms stall retires only its window within the existing budget', async () => {
  const windows = await monitorReceiver(() => healthy, budget, clock([254.67]));
  assert.deepEqual(windows.map(window => window.verdict), ['unobserved', 'observed']);
  assert.equal(windows[0].observedMs, 0);
  assert.deepEqual(windows[0].gaps, [{ fromMs: 0, toMs: 254.67, lengthMs: 254.67, eventLoopLagMs: 204.67 }]);
  assert.equal(windows[1].startMs, 254.67);
  assert.equal(windows[1].endMs, 1254.67);
  assert.equal(windows[1].observedMs, windows[1].endMs - windows[1].startMs);
  assert.ok(windows[1].observedMs >= 1000);
});
test('a final-tick gap also retries and preserves the complete attempt history', async () => {
  const windows = await monitorReceiver(() => healthy, budget, clock([...Array<number>(19).fill(50), 300]));
  assert.deepEqual(windows.map(window => window.verdict), ['unobserved', 'observed']);
  assert.equal(windows[0].observedMs, 950);
  assert.equal(windows[0].endMs, 1250);
  assert.equal(windows[1].endMs, 2250);
});
test('persistent stalls and a short clean suffix cannot extend the original deadline', async () => {
  for (const steps of [[300, 300, 300, 300], [254.67], [1001]]) {
    const time = clock(steps);
    await assert.rejects(monitorReceiver(() => healthy, { deadlineMs: 1000 }, time), error => {
      assert.ok(error instanceof ReceiverObservationError);
      assert.equal(error.reason, 'unobserved');
      assert.ok(error.windows.every(window => window.verdict === 'unobserved'));
      assert.ok(error.windows.at(-1)!.observedMs < 1000);
      assert.ok(time.now() >= 1000);
      return true;
    });
  }
});
test('the unchanged 250 ms limit and exact deadline are inclusive', async () => {
  const windows = await monitorReceiver(() => healthy, { deadlineMs: 1000 }, clock([250, 250, 250, 250]));
  assert.equal(windows.length, 1);
  assert.equal(windows[0].verdict, 'observed');
  assert.equal(windows[0].observedMs, 1000);
  assert.deepEqual(windows[0].gaps, []);
});
test('observed failure after a retired window is not erased by another clean attempt', async () => {
  const time = clock([300, 300]);
  await assert.rejects(monitorReceiver(() => ({ ...healthy, connected: time.now() < 600 }), budget, time), error => {
    assert.ok(error instanceof ReceiverObservationError);
    assert.deepEqual(error.windows.map(window => window.verdict), ['unobserved', 'unavailable']);
    assert.equal(time.now(), 600);
    return true;
  });
});
test('invalid deadlines reject before a receiver can qualify', async () => {
  for (const deadlineMs of [NaN, Infinity]) {
    await assert.rejects(monitorReceiver(() => healthy, { deadlineMs }, clock()), /Invalid receiver observation bounds/);
  }
});

test('successive publication windows share a deadline instead of renewing it', async () => {
  const time = clock([254.67]);
  const shared = { deadlineMs: 3000 };
  await monitorReceiver(() => healthy, shared, time);
  await monitorReceiver(() => healthy, shared, time);
  await assert.rejects(monitorReceiver(() => healthy, shared, time), error => {
    assert.ok(error instanceof ReceiverObservationError);
    assert.equal(error.reason, 'unobserved');
    assert.equal(time.now(), 3000);
    return true;
  });
});
