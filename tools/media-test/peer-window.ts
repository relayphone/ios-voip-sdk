import { setTimeout as sleep } from 'node:timers/promises';

export interface ReceiverHealth { connected: boolean; readerLive: boolean; trackAvailable: boolean }
/** Only local observer state is retained; no transport configuration or credentials. */
export class ReceiverObservationError extends Error {
  readonly reason: 'unavailable' | 'coverage-gap' | 'stopped' | 'final-gap';
  readonly health: ReceiverHealth;
  readonly gapMs: number;
  constructor(reason: ReceiverObservationError['reason'], health: ReceiverHealth, gapMs: number) {
    super(`Far-end observer: ${reason}`);
    this.reason = reason;
    this.health = { ...health };
    this.gapMs = gapMs;
  }
}
/** Monitor the observer independently of PCM, which can legitimately stop during publication mute. */
export async function monitorReceiver(
  read: () => ReceiverHealth,
  timing = { now: () => performance.now(), pause: () => sleep(50) },
): Promise<void> {
  const start = timing.now();
  let last = start;
  while (timing.now() - start < 1000) {
    const current = timing.now(), health = read();
    if (!(health.connected && health.readerLive && health.trackAvailable)) throw new ReceiverObservationError('unavailable', health, current - last);
    if (!(current - last <= 250)) throw new ReceiverObservationError('coverage-gap', health, current - last);
    last = current;
    await timing.pause();
  }
  const health = read();
  if (!(health.connected && health.readerLive && health.trackAvailable)) throw new ReceiverObservationError('stopped', health, timing.now() - last);
  if (!(timing.now() - last <= 250)) throw new ReceiverObservationError('final-gap', health, timing.now() - last);
}
