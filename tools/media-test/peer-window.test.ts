import assert from 'node:assert/strict';
import { test } from 'node:test';
import { monitorReceiver, ReceiverObservationError } from './peer-window.ts';
const healthy = { connected: true, readerLive: true, trackAvailable: true };
function clock() { let now = 0; return { now: () => now, pause: async () => { now += 50; } }; }
test('muted publication can have no samples while its observer remains independently live', async () => {
  await monitorReceiver(() => healthy, clock());
});
for (const key of ['connected', 'readerLive', 'trackAvailable'] as const) {
  test('a missing ' + key + ' cannot read as silence', async () => {
    const time = clock();
    await assert.rejects(monitorReceiver(() => ({ ...healthy, [key]: time.now() < 500 }), time), error => {
      assert.ok(error instanceof ReceiverObservationError);
      assert.equal(error.reason, 'unavailable');
      assert.deepEqual(error.health, { ...healthy, [key]: false });
      assert.equal(error.gapMs, 50);
      return true;
    });
  });
}
test('a stopped observer cannot claim a full window', async () => {
  let now = 0;
  await assert.rejects(monitorReceiver(() => healthy, { now: () => now, pause: async () => { now += 1000; } }), error => {
    assert.ok(error instanceof ReceiverObservationError);
    assert.equal(error.reason, 'final-gap');
    assert.deepEqual(error.health, healthy);
    assert.equal(error.gapMs, 1000);
    return true;
  });
});
test('a scheduling gap inside the window reports its duration without accepting coverage', async () => {
  let now = 0;
  await assert.rejects(monitorReceiver(() => healthy, { now: () => now, pause: async () => { now += 300; } }), error => {
    assert.ok(error instanceof ReceiverObservationError);
    assert.equal(error.reason, 'coverage-gap');
    assert.equal(error.gapMs, 300);
    return true;
  });
});
test('health lost at the final observation cannot qualify the window', async () => {
  const time = clock();
  await assert.rejects(monitorReceiver(() => ({ ...healthy, readerLive: time.now() < 1000 }), time), error => {
    assert.ok(error instanceof ReceiverObservationError);
    assert.equal(error.reason, 'stopped');
    assert.equal(error.health.readerLive, false);
    return true;
  });
});
