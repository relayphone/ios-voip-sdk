// Resource diagnostics run in a separate process, independent of blocking simulator commands.
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { CrashTracker, processSummary } from './inspector-processes.ts';
import { dirname, join } from 'node:path';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { isMain, main, run } from './command.ts';

/** Retains the tail of a log with a hard byte limit. */
export function boundedTail(value: string | Buffer, limit = 2 * 1024 * 1024): Buffer {
  const bytes = typeof value === 'string' ? Buffer.from(value) : value;
  return bytes.subarray(Math.max(0, bytes.length - limit));
}

/** Summarizes the highest used-memory percentage and lowest free-page count observed. */
export function memoryMargin(samples: string): string {
  const free = [...samples.matchAll(/System-wide memory free percentage:\s*(\d+)%/g)].map(m => Number(m[1]));
  const pages = [...samples.matchAll(/Pages free:\s*(\d+)/g)].map(m => Number(m[1]));
  if (!free.length || !pages.length) return 'warning:resource-sampler did not capture memory pressure and free pages';
  const times = samples.match(/^\d{4}-\d{2}-\d{2}T\S+Z$/gm) ?? [];
  const coverage = times.length ? `; ${times.length} samples (${times[0]} to ${times.at(-1)})` : '';
  const warnings = /(?:vm_stat|memory_pressure|top|ps|crash reports): /.test(samples) ? '; warning:resource-sampler command failures (see resources.log)' : '';
  return `peak memory pressure: ${100 - Math.min(...free)}% used (memory_pressure -Q); minimum free pages: ${Math.min(...pages)}${coverage}${warnings}`;
}

function sample(path: string, crashes: CrashTracker): void {
  appendFileSync(path, `\n${new Date().toISOString()}\n`);
  for (const [command, args, keep] of [
    ['vm_stat', [], /page size|Pages (free|active|inactive|speculative|wired down)|compressor/],
    ['memory_pressure', ['-Q'], /System-wide memory free percentage/],
    ['top', ['-l', '1', '-n', '0'], /Processes:|Load Avg:|CPU usage:|PhysMem:|VM:/],
  ] as const) {
    try {
      const output = run(command, args, { timeout: 5 });
      appendFileSync(path, `${command}\n${output.split('\n').filter(line => keep.test(line)).join('\n')}\n`);
    } catch (error) { appendFileSync(path, `${command}: ${String(error)}\n`); }
  }
  try {
    appendFileSync(path, processSummary(run('ps', ['-axo', 'pid,ppid,stat,%cpu,etime,comm', '-r'], { timeout: 5 })) + '\n');
  } catch (error) { appendFileSync(path, `ps: ${String(error)}\n`); }
  try { appendFileSync(path, crashes.sample() + '\n'); }
  catch (error) { appendFileSync(path, `crash reports: ${String(error)}\n`); }
}

/** Runs immediately and every 15 seconds; a failed sample cannot stop later samples. */
export function startResourceSampler(
  sample: () => void,
  warn: (message: string) => void = console.warn,
  schedule: (tick: () => void, milliseconds: number) => () => void = (tick, milliseconds) => {
    const timer = setInterval(tick, milliseconds);
    return () => clearInterval(timer);
  },
): () => void {
  let stopped = false;
  const tick = () => {
    if (stopped) return;
    try { sample(); } catch (error) { warn(`warning:resource-sampler ${String(error)}`); }
  };
  const cancel = schedule(tick, 15_000);
  tick();
  return () => { stopped = true; cancel(); };
}

/** Captures only a rolling tail, including stderr, even if the command fails or times out. */
export async function captureTail(command: string, args: readonly string[], limit = 2 * 1024 * 1024): Promise<Buffer> {
  return new Promise(resolve => {
    let tail: Buffer = Buffer.alloc(0);
    const append = (chunk: Buffer) => { tail = boundedTail(Buffer.concat([tail, chunk]), limit); };
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', append);
    child.stderr.on('data', append);
    const timer = setTimeout(() => {
      append(Buffer.from('\nDiagnostic command timed out after 60s\n'));
      child.kill('SIGKILL');
    }, 60_000);
    child.once('error', error => append(Buffer.from(String(error))));
    child.once('close', () => { clearTimeout(timer); resolve(tail); });
  });
}

/** Saves simulator state and the latest CoreSimulator messages without masking the original failure. */
export async function simulatorDiagnostics(prefix: string): Promise<void> {
  mkdirSync(dirname(prefix), { recursive: true });
  for (const [name, command, args] of [
    ['devices', 'xcrun', ['simctl', 'list', 'devices']],
    ['coresimulator', '/usr/bin/log', ['show', '--last', '15m', '--style', 'compact', '--predicate',
      'subsystem BEGINSWITH "com.apple.CoreSimulator" OR process == "CoreSimulatorService" OR process == "launchd_sim"']],
  ] as const) {
    try { writeFileSync(`${prefix}-${name}.log`, await captureTail(command, args)); }
    catch (error) { writeFileSync(`${prefix}-${name}.log`, boundedTail(String(error))); }
  }
}

if (isMain(import.meta.url)) {
  await main(async () => {
    const path = process.argv[2];
    if (!path) throw new Error('Usage: inspector-resources.ts <samples.log>');
    if (process.argv.includes('--diagnostics')) { await simulatorDiagnostics(path); return; }
    if (process.argv.includes('--summary')) {
      try { console.log(memoryMargin(readFileSync(path, 'utf8'))); }
      catch (error) { console.log(`warning:resource-sampler ${String(error)}`); }
      return;
    }
    let stop = () => {};
    process.once('SIGTERM', () => { stop(); process.exit(0); });
    const crashes = new CrashTracker([join(homedir(), 'Library/Logs/DiagnosticReports'),
      join(homedir(), 'Library/Logs/CoreSimulator')]);
    stop = startResourceSampler(() => sample(path, crashes));
  });
}
