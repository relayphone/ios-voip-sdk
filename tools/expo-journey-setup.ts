import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { CommandFailure, repository, run } from './command.ts';
import { buildSimulatorApp } from './simulator-app.ts';

type Phase = 'create' | 'boot' | 'bootstatus' | 'probe-install' | 'probe-uninstall' | 'install' | 'container'
  | 'host-processes' | 'simulator-services' | 'host-install-log';

type Observation = { phase: Phase; startedAt: string; elapsedMS: number } & (
  { outcome: 'succeeded'; stdout?: string } |
  { outcome: 'failed'; error: string; stderrTail?: string }
);

const probeIdentifier = 'com.example.voip.install-probe';

/** Builds a tiny signed simulator app separate from the example's build products. */
export function buildInstallProbe(work: string, execute: typeof run = run): string {
  const parent = join(work, 'install-probe');
  mkdirSync(parent, { recursive: true });
  const bundle = join(mkdtempSync(join(parent, 'build-')), 'SimulatorInstallProbe.app');
  buildSimulatorApp({ bundle, executable: 'SimulatorInstallProbe', identifier: probeIdentifier,
    displayName: 'Simulator Install Probe', minimumOS: '26.0', sources: [join(repository, 'tools/SimulatorInstallProbe.swift')],
  }, (command, args, options) => execute(command, args, { ...options, timeout: 120 }));
  return bundle;
}

/** Finishes the throwaway install before measuring the example's install. */
export function warmSimulatorInstaller(simulator: string, probe: string, setup: JourneySetupTrace,
  execute: typeof run = run): void {
  setup.observe('probe-install', () => execute('xcrun', ['simctl', 'install', simulator, probe], { timeout: 180 }));
  setup.observe('probe-uninstall', () => execute('xcrun', ['simctl', 'uninstall', simulator, probeIdentifier], { timeout: 120 }));
}

/** Records bounded setup commands, including the warm-up and the example install. */
export class JourneySetupTrace {
  private readonly observations: Observation[] = [];

  observe<T>(phase: Phase, operation: () => T, stdout?: (result: T) => string): T {
    const startedAt = new Date().toISOString();
    const start = performance.now();
    const timing = () => ({ phase, startedAt, elapsedMS: Math.round(performance.now() - start) });
    try {
      const result = operation();
      this.observations.push({ ...timing(), outcome: 'succeeded', stdout: stdout?.(result).slice(-8192) });
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
