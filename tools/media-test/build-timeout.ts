import { execFile, spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const fileLimit = 256 * 1024;

/** Captures at most four 256 KiB files, without command arguments or environment values. */
export async function captureBuildDiagnostics(pid: number, directory: string, signal?: AbortSignal): Promise<void> {
  await mkdir(directory, { recursive: true });
  const capture = async (name: string, command: string, args: string[]) => {
    let output: string;
    try { const result = await execute(command, args, { timeout: 7_000, maxBuffer: fileLimit, signal });
      output = result.stdout + result.stderr;
    } catch (error) {
      const result = error as { stdout?: string; stderr?: string; code?: unknown };
      output = `${result.stdout ?? ''}${result.stderr ?? ''}\nDiagnostic command failed: ${String(result.code)}\n`;
    }
    await writeFile(join(directory, name), Buffer.from(output).subarray(0, fileLimit));
    return output;
  };
  const tree = await capture('processes.txt', '/bin/ps', ['-c', '-axo', 'pid=,ppid=,pgid=,etime=,%cpu=,rss=,comm=']);
  await Promise.all([
    capture('disk.txt', '/bin/df', ['-h']),
    capture('load.txt', '/usr/bin/uptime', []),
  ]);
  // The build owns its process group. Never sample another concurrent build.
  const candidate = tree.split('\n').map(line => line.trim().split(/\s+/))
    .find(fields => Number(fields[2]) === pid && /(?:^|\/)(?:ld|ld-classic|swift-frontend)$/.test(fields.at(-1) ?? ''));
  const target = candidate ? Number(candidate[0]) : pid;
  await capture('sample.txt', '/usr/bin/sample', [String(target), '5', '10']);
}

/** Fails at the existing build deadline, gathers bounded evidence, then kills its process group. */
export async function runBuild(options: {
  command: string; args: string[]; timeoutMS: number; directory: string;
  capture?: (pid: number, directory: string, signal: AbortSignal) => Promise<void>;
}): Promise<number> {
  if (!Number.isSafeInteger(options.timeoutMS) || options.timeoutMS <= 0) throw new Error('Invalid build timeout');
  const child = spawn(options.command, options.args, { detached: true, stdio: 'inherit' });
  const pid = child.pid;
  if (!pid) return await new Promise<number>(resolve => child.once('error', () => resolve(1)));
  let timedOut = false;
  let interrupted: number | undefined;
  const signalGroup = (signal: NodeJS.Signals) => {
    try { process.kill(-pid, signal); } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
    }
  };
  let stopped = false;
  const stop = () => { if (!stopped) { stopped = true; signalGroup('SIGKILL'); } };
  const interrupt = () => { interrupted = 130; stop(); };
  process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  let diagnosticTask: Promise<void> | undefined;
  const timer = setTimeout(() => {
    timedOut = true;
    console.error(`Build exceeded ${options.timeoutMS}ms; capturing diagnostics before termination`);
    diagnosticTask = (async () => {
      // This independent timer also bounds diagnostics if a host utility or filesystem stalls.
      const controller = new AbortController();
      const watchdog = setTimeout(() => { controller.abort(); stop(); }, 15_000);
      try { await (options.capture ?? captureBuildDiagnostics)(pid, options.directory, controller.signal); }
      catch { console.error('Build diagnostic capture failed'); }
      finally { clearTimeout(watchdog); stop(); }
    })();
  }, options.timeoutMS);
  try {
    const code = await new Promise<number>(resolve => {
      child.once('error', () => resolve(1));
      child.once('close', (code, signal) => resolve(code ?? (signal ? 1 : 0)));
    });
    return interrupted ?? (timedOut ? 142 : code);
  } finally {
    clearTimeout(timer);
    process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
    // Do not await a stuck diagnostic utility after the build process has been killed.
    void diagnosticTask;
  }
}

if (import.meta.main) {
  const [seconds, directory, command, ...args] = process.argv.slice(2);
  if (!seconds || !directory || !command) throw new Error('Usage: build-timeout.ts <seconds> <diagnostics-directory> <command> [args...]');
  process.exitCode = await runBuild({ command, args, timeoutMS: Number(seconds) * 1000, directory });
}
