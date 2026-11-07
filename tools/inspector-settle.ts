import { setTimeout as sleep } from 'node:timers/promises';
import { run } from './command.ts';

/** Uses the final interval from top, rather than its first since-boot reading. */
export function idleCPU(output: string): number | undefined {
  const readings = [...output.matchAll(/CPU usage:[^\n]*?([\d.]+)% idle/g)];
  if (readings.length < 2) return undefined;
  const idle = Number(readings.at(-1)![1]);
  return Number.isFinite(idle) && idle >= 0 && idle <= 100 ? idle : undefined;
}

/** Matches only the requested program component of a launchctl service label. */
export function intelligenceService(output: string): string | undefined {
  for (const line of output.split('\n')) {
    const fields = line.trim().split(/\s+/);
    if (fields.length !== 3 || !/^(?:-|\d+)$/.test(fields[0]!)) continue;
    const label = fields[2]!;
    if (label.split('.').at(-1) === 'intelligencetasksd') return label;
  }
  return undefined;
}

/** Missing samples and readings below 30% break the consecutive-sample streak. */
export function settleStreak(previous: number, idle: number | undefined): number {
  return idle !== undefined && Number.isFinite(idle) && idle >= 30 && idle <= 100 ? previous + 1 : 0;
}

/** Waits for three ten-second samples, bounded by ten minutes including sampling. */
export async function settleHost(
  sample: (remaining: number) => number | undefined = remaining => idleCPU(
    run('top', ['-l', '2', '-s', '1', '-n', '0'], { timeout: Math.min(5, remaining / 1000) })),
  now: () => number = Date.now,
  wait: (milliseconds: number) => Promise<unknown> = sleep,
): Promise<number> {
  const start = now();
  const deadline = start + 600_000;
  let streak = 0;
  let next = start + 10_000;
  while (next < deadline) {
    await wait(Math.max(0, next - now()));
    if (now() >= deadline) break;
    let idle: number | undefined;
    try { idle = sample(deadline - now()); } catch { /* A failed reading breaks the streak. */ }
    streak = settleStreak(streak, idle);
    if (now() >= deadline) break;
    if (streak >= 3) return now() - start;
    next = Math.max(next + 10_000, now() + 1);
  }
  await wait(Math.max(0, deadline - now()));
  throw new Error('Host did not settle within 600s');
}

/** Best-effort optimization, scoped to the CI-created simulator and one service. */
export function stopIntelligenceService(
  device: string,
  log: (message: string) => void,
  execute: typeof run = run,
  capture: (output: string) => void = () => {},
): void {
  try {
    const output = execute('xcrun', ['simctl', 'spawn', device, '/bin/launchctl', 'list'], { timeout: 30 });
    capture(output);
    const label = intelligenceService(output);
    if (!label) { log('intelligencetasksd: service not found; continuing'); return; }
    log(`intelligencetasksd: found ${label}`);
    for (const operation of ['disable', 'bootout']) {
      try {
        execute('xcrun', ['simctl', 'spawn', device, '/bin/launchctl', operation, `system/${label}`], { timeout: 30 });
        log(`intelligencetasksd: ${operation} ${label} succeeded`);
      } catch (error) { log(`warning:intelligencetasksd ${operation} ${label}: ${String(error)}`); }
    }
  } catch (error) { log(`warning:intelligencetasksd lookup: ${String(error)}`); }
}
