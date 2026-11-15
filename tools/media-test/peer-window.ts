import { setTimeout as sleep } from 'node:timers/promises';

export interface ReceiverHealth { connected: boolean; readerLive: boolean; trackAvailable: boolean }
export interface ReceiverWindow {
  startMs: number;
  endMs: number;
  observedMs: number;
  ticksMs: number[];
  gaps: { fromMs: number; toMs: number; lengthMs: number; eventLoopLagMs: number }[];
  verdict: 'observed' | 'unobserved' | 'unavailable';
}
/** Only local observer state is retained; no transport configuration or credentials. */
export class ReceiverObservationError extends Error {
  readonly reason: 'unavailable' | 'stopped' | 'unobserved';
  readonly health: ReceiverHealth;
  readonly gapMs: number;
  readonly windows: ReceiverWindow[];
  constructor(reason: ReceiverObservationError['reason'], health: ReceiverHealth, gapMs: number,
    windows: ReceiverWindow[]) {
    super(`Far-end observer: ${reason}`);
    this.reason = reason;
    this.health = { ...health };
    this.gapMs = gapMs;
    this.windows = windows;
  }
}
/** Select the first full one-second receiver window within the caller's existing deadline. */
export async function monitorReceiver(
  read: () => ReceiverHealth,
  options: { deadlineMs: number },
  timing = { now: () => performance.now(), pause: (ms: number) => sleep(ms) },
): Promise<ReceiverWindow[]> {
  const windows: ReceiverWindow[] = [];
  let start = timing.now(), last = start, expectedTick = start;
  if (!Number.isFinite(start) || !Number.isFinite(options.deadlineMs)) throw new Error('Invalid receiver observation bounds');
  const begin = (): ReceiverWindow => ({ startMs: start, endMs: start, observedMs: 0,
    ticksMs: [start], gaps: [], verdict: 'unobserved' });
  let window = begin();
  const finish = (verdict: ReceiverWindow['verdict']) => { window.verdict = verdict; windows.push(window); };
  while (true) {
    const current = timing.now(), health = read(), gap = current - last;
    window.endMs = current;
    if (current !== last) window.ticksMs.push(current);
    if (gap > 250) window.gaps.push({ fromMs: last, toMs: current, lengthMs: gap,
      eventLoopLagMs: Math.max(0, current - expectedTick) });
    else window.observedMs = current - start;
    // An observed health failure is terminal, including on the tick returning from a stall.
    if (!(health.connected && health.readerLive && health.trackAvailable)) {
      finish('unavailable');
      throw new ReceiverObservationError(current - start >= 1000 ? 'stopped' : 'unavailable', health, gap, windows);
    }
    if (current > options.deadlineMs) {
      finish('unobserved'); throw new ReceiverObservationError('unobserved', health, gap, windows);
    }
    if (gap > 250) {
      finish('unobserved');
      if (current >= options.deadlineMs) throw new ReceiverObservationError('unobserved', health, gap, windows);
      start = current;
      window = begin();
    } else if (current - start >= 1000) {
      finish('observed'); return windows;
    }
    if (current >= options.deadlineMs) {
      finish('unobserved'); throw new ReceiverObservationError('unobserved', health, gap, windows);
    }
    last = current;
    const pauseMs = Math.min(50, options.deadlineMs - current, 1000 - (current - start));
    expectedTick = current + pauseMs;
    await timing.pause(pauseMs);
  }
}
