import { writeFileSync } from 'node:fs';
import { CommandFailure, run } from './command.ts';

type Phase = 'create' | 'bootstatus' | 'install' | 'container'
  | 'host-processes' | 'simulator-services' | 'host-install-log';

type Observation = { phase: Phase; startedAt: string; elapsedMS: number } & (
  { outcome: 'succeeded'; stdout?: string; lastMigrationElapsedMS?: number } |
  { outcome: 'failed'; error: string; stderrTail?: string }
);

/** Returns the last migration elapsed time reported by simctl, if a sample was observed. */
function lastReportedMigrationElapsed(output: string): number | undefined {
  const elapsed = Array.from(output.matchAll(/Migration Elapsed:\s*(\d+(?::\d{2}){1,2})\b/g)).at(-1)?.[1];
  if (elapsed === undefined) return undefined;
  return elapsed.split(':').reduce((total, unit) => total * 60 + Number(unit), 0) * 1000;
}

/** Monitors before starting the device so the initial migration can be observed. */
export function waitForJourneyBoot(simulator: string, setup: JourneySetupTrace, execute: typeof run = run): void {
  setup.observe('bootstatus', () => execute('xcrun', ['simctl', 'bootstatus', simulator, '-b', '-d'],
    { timeout: 300 }), output => output);
}

/** Records bounded simulator setup commands. */
export class JourneySetupTrace {
  private readonly observations: Observation[] = [];

  observe<T>(phase: Phase, operation: () => T, stdout?: (result: T) => string): T {
    const startedAt = new Date().toISOString();
    const start = performance.now();
    const timing = () => ({ phase, startedAt, elapsedMS: Math.round(performance.now() - start) });
    try {
      const result = operation();
      const output = stdout?.(result);
      const lastMigrationElapsedMS = phase === 'bootstatus' && output ? lastReportedMigrationElapsed(output) : undefined;
      this.observations.push({ ...timing(), outcome: 'succeeded', stdout: output?.slice(-8192), lastMigrationElapsedMS });
      return result;
    } catch (error) {
      const cause = error instanceof Error && error.cause instanceof CommandFailure ? error.cause : error;
      this.observations.push({ ...timing(), outcome: 'failed',
        error: String(error).slice(-4096), stderrTail: cause instanceof CommandFailure ? cause.stderrTail : undefined });
      throw error;
    }
  }

  save(prefix: string): void {
    try { writeFileSync(`${prefix}-setup.json`, JSON.stringify(this.observations, null, 2) + '\n'); }
    catch (error) { console.warn(`warning: could not save simulator setup trace: ${String(error)}`); }
  }

  /** Read-only probes run only after install or lookup fails and cannot affect the verdict. */
  captureInstallFailure(simulator: string, execute: typeof run = run): void {
    const collect = (phase: Phase, command: string, args: readonly string[], timeout: number,
      select: (output: string) => string) => {
      try { this.observe(phase, () => execute(command, args, { timeout }), select); }
      catch { /* The failed probe is already in the trace. */ }
    };
    collect('host-processes', '/bin/ps', ['-axo', 'pid,ppid,state,comm'], 3,
      output => output.split('\n').filter(line =>
        /(?:^|[\s/.])(?:CoreSimulatorService|CoreDeviceService|simdiskimaged|launchd_sim|installd|containermanagerd|lsd|SpringBoard|xcrun|simctl)$/.test(line)).join('\n'));
    collect('simulator-services', 'xcrun', ['simctl', 'spawn', simulator, 'launchctl', 'list'], 8,
      output => output.split('\n').filter(line =>
        /SpringBoard|installd|container.?manager|launchservices|\.lsd\b/i.test(line)).join('\n'));
    collect('host-install-log', '/usr/bin/log', ['show', '--last', '10m', '--style', 'compact', '--info', '--predicate',
      'process IN {"installd", "containermanagerd", "CoreSimulatorService", "com.apple.CoreSimulator.CoreSimulatorService"}'],
    15, output => output);
  }
}
