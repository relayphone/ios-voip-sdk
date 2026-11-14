import assert from 'node:assert/strict';
import { test } from 'node:test';
import { monitorReceiver } from './peer-window.ts';
const healthy = { connected: true, readerLive: true, trackAvailable: true };
function clock() { let now = 0; return { now: () => now, pause: async () => { now += 50; } }; }
test('muted publication can have no samples while its observer remains independently live', async () => {
  await monitorReceiver(() => healthy, clock());
});
for (const key of ['connected', 'readerLive', 'trackAvailable'] as const) {
  test('a missing ' + key + ' cannot read as silence', async () => {
    const time = clock();
    await assert.rejects(monitorReceiver(() => ({ ...healthy, [key]: time.now() < 500 }), time));
  });
}
test('a stopped observer cannot claim a full window', async () => {
  let now = 0;
  await assert.rejects(monitorReceiver(() => healthy, { now: () => now, pause: async () => { now += 1000; } }));
});
