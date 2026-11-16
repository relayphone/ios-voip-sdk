import { spawnSync } from 'node:child_process';
import { run, type RunOptions } from './command.ts';

const timeout = (error: unknown): boolean => error instanceof Error && /\bETIMEDOUT\b|\btimed out\b/i.test(error.message);

/** Short, bounded probes never collect process arguments or environments. */
function probe(command: string, args: readonly string[], options: RunOptions = {}): string {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: (options.timeout ?? 3) * 1000,
    killSignal: 'SIGKILL', maxBuffer: 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Probe exited ${result.status ?? result.signal}`);
  return result.stdout;
}

/** A command timeout retains its phase, original cause and immediate host evidence. */
export class SmokeCommandFailure extends Error {
  readonly stage: string;
  readonly hostUnresponsive: boolean;
  readonly evidence: string;
  constructor(stage: string, hostUnresponsive: boolean, evidence: string, cause: unknown) {
    super(`${hostUnresponsive ? 'infra:host-unresponsive' : 'runtime-smoke:command-timeout'}; stage=${stage}\n${evidence}\n${cause instanceof Error ? cause.message : String(cause)}`, { cause });
    this.stage = stage; this.hostUnresponsive = hostUnresponsive; this.evidence = evidence;
  }
}

/** Runs each smoke command once; only simulator command timeouts trigger health probes. */
export function smokeCommand(stage: string, command: string, args: readonly string[], options: RunOptions = {},
  execute: typeof run = run, inspect: typeof run = probe): string {
  try { return execute(command, args, options); } catch (error) {
    const simctl = command === 'xcrun' && args[0] === 'simctl';
    const cksim = /(?:^|\/)cksim$/.test(command);
    const nestedTimeout = error instanceof Error && /(?:simctl \S+|Reading simulator environment key \S+) timed out/i.test(error.message);
    if (!(simctl && timeout(error)) && !(cksim && (nestedTimeout || error instanceof Error && /\bETIMEDOUT\b/.test(error.message)))) throw error;
    let hostUnresponsive = false;
    let inventory: string;
    try {
      inspect('xcrun', ['simctl', 'list', 'devices', '--json'], { timeout: 10 });
      inventory = 'simctl list: responsive';
    } catch (failure) {
      hostUnresponsive = timeout(failure);
      inventory = `simctl list: ${String(failure).slice(0, 4096)}`;
    }
    let service: string;
    try {
      const processes = inspect('ps', ['-axo', 'pid=,etime=,comm='], { timeout: 3 });
      service = processes.split('\n').filter(line => /(?:^|\/)com\.apple\.CoreSimulator\.CoreSimulatorService\s*$/.test(line)).join('\n');
      service = service.slice(0, 4096) || 'not observed';
    } catch (failure) { service = String(failure).slice(0, 4096); }
    throw new SmokeCommandFailure(stage, hostUnresponsive, `${inventory}\nCoreSimulatorService pid/uptime/name: ${service}`, error);
  }
}
