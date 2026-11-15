import { setTimeout as sleep } from 'node:timers/promises';
import type { ReceiverHealth } from './peer-window.ts';

export interface SilenceTick extends ReceiverHealth { samples: number; energy: number }
export interface SilenceWindow {
  startMs: number;
  endMs: number;
  observedMs: number;
  ticksMs: number[];
  gaps: { fromMs: number; toMs: number; lengthMs: number; eventLoopLagMs: number }[];
  verdict: 'silent' | 'unobserved' | 'leak' | 'unavailable';
}
export class SilenceObservationError extends Error {
  readonly reason: Exclude<SilenceWindow['verdict'], 'silent'>;
  readonly windows: SilenceWindow[];
  constructor(reason: Exclude<SilenceWindow['verdict'], 'silent'>, windows: SilenceWindow[]) {
    super(`Silence observation: ${reason}`);
    this.reason = reason;
    this.windows = windows;
  }
}
/** Select a complete continuous window inside the caller's existing monotonic deadline. */
export async function observeSilence(
  read: () => SilenceTick,
  options: { durationMs: number; deadlineMs: number; gapLimitMs: number },
  timing = { now: () => performance.now(), pause: (ms: number) => sleep(ms) },
): Promise<SilenceWindow[]> {
  const windows: SilenceWindow[] = [];
  let start = timing.now(), last = start, expectedTick = start;
  if (![options.durationMs, options.deadlineMs, options.gapLimitMs, start].every(Number.isFinite) ||
    options.durationMs <= 0 || options.gapLimitMs <= 0) throw new Error('Invalid silence observation bounds');
  let baseline = read();
  let window: SilenceWindow = { startMs: start, endMs: start, observedMs: 0, ticksMs: [start], gaps: [], verdict: 'unobserved' };
  const finish = (verdict: SilenceWindow['verdict']) => {
    window.verdict = verdict;
    windows.push(window);
  };
  while (true) {
    const current = timing.now(), tick = read(), gap = current - last;
    window.endMs = current;
    if (current !== last) window.ticksMs.push(current);
    if (gap > options.gapLimitMs) window.gaps.push({ fromMs: last, toMs: current, lengthMs: gap,
      eventLoopLagMs: Math.max(0, current - expectedTick) });
    else window.observedMs += gap;
    // Test observed PCM before retiring an unobserved window: a gap cannot erase a leak.
    const samples = tick.samples - baseline.samples, energy = tick.energy - baseline.energy;
    if (samples < 0 || energy < 0 || !Number.isFinite(energy) || !Number.isFinite(samples) ||
      !(tick.connected && tick.readerLive && tick.trackAvailable)) {
      finish('unavailable'); throw new SilenceObservationError('unavailable', windows);
    }
    if (samples > 0 && Math.sqrt(energy / samples) >= 0.001) {
      finish('leak'); throw new SilenceObservationError('leak', windows);
    }
    if (current > options.deadlineMs) {
      finish('unobserved'); throw new SilenceObservationError('unobserved', windows);
    }
    if (gap > options.gapLimitMs) {
      finish('unobserved');
      if (current >= options.deadlineMs) throw new SilenceObservationError('unobserved', windows);
      start = current; baseline = tick;
      window = { startMs: start, endMs: start, observedMs: 0, ticksMs: [start], gaps: [], verdict: 'unobserved' };
    } else if (current - start >= options.durationMs) {
      finish('silent'); return windows;
    }
    if (current >= options.deadlineMs) {
      finish('unobserved'); throw new SilenceObservationError('unobserved', windows);
    }
    last = current;
    const pauseMs = Math.min(50, options.deadlineMs - current, options.durationMs - (current - start));
    expectedTick = current + pauseMs;
    await timing.pause(pauseMs);
  }
}
