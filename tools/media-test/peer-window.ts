import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

export interface ReceiverHealth { connected: boolean; readerLive: boolean; trackAvailable: boolean }
/** Monitor the observer independently of PCM, which can legitimately stop during publication mute. */
export async function monitorReceiver(
  read: () => ReceiverHealth,
  timing = { now: () => performance.now(), pause: () => sleep(50) },
): Promise<void> {
  const start = timing.now();
  let last = start;
  while (timing.now() - start < 1000) {
    const current = timing.now(), health = read();
    assert.ok(health.connected && health.readerLive && health.trackAvailable, 'Far-end receiver unavailable');
    assert.ok(current - last <= 250, 'Far-end observer coverage gap');
    last = current;
    await timing.pause();
  }
  const health = read();
  assert.ok(health.connected && health.readerLive && health.trackAvailable, 'Far-end receiver stopped');
  assert.ok(timing.now() - last <= 250, 'Far-end final observation missing');
}
