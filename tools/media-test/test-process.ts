import { execFile, spawn } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import { promisify } from 'node:util';
import { StringDecoder } from 'node:string_decoder';

const execute = promisify(execFile);

export interface TestProcessResult {
  code: number | null;
  signal: NodeJS.Signals | null;
  reason: 'exit' | 'timeout' | 'outputLimit' | 'interrupted' | 'launchError' | 'outputHeldOpen';
  /** Original stdout, kept separate so diagnostics cannot split a structured receipt. */
  log: string;
  stderr: string;
  elapsedMS: number;
  nativePID?: number;
  clean: boolean;
  cleanupErrors: string[];
}
const stopped = async (groups: number[]) => {
  const {stdout} = await execute('/bin/ps', ['-axo', 'pgid=,stat='], {timeout: 1000, maxBuffer: 256 * 1024});
  return !stdout.split('\n').some(line => {
    const [group, state] = line.trim().split(/\s+/);
    return groups.includes(Number(group)) && !state?.startsWith('Z');
  });
};
const kill = (pid: number) => {
  try { process.kill(-pid, 'SIGKILL'); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ESRCH') return (error as NodeJS.ErrnoException).code ?? 'unknown'; }
};

/** Owns both host and simulator groups; output or a passed-test line never substitutes for exit. */
export async function runTestProcess(options: {
  command: string; args: string[]; timeoutMS: number; env?: NodeJS.ProcessEnv;
  secrets?: string[]; outputLimit?: number;
}): Promise<TestProcessResult> {
  if (!Number.isSafeInteger(options.timeoutMS) || options.timeoutMS <= 0) throw new Error('Invalid test timeout');
  const limit = options.outputLimit ?? 16 * 1024 * 1024;
  if (!Number.isSafeInteger(limit) || limit <= 0) throw new Error('Invalid output limit');
  const started = performance.now();
  const child = spawn(options.command, options.args, { detached: true, env: options.env, stdio: ['ignore', 'pipe', 'pipe'] });
  let reason: TestProcessResult['reason'] = 'exit', log = '', stderr = '', bytes = 0, prefix = '';
  const stdoutDecoder = new StringDecoder('utf8'), stderrDecoder = new StringDecoder('utf8');
  let nativePID: number | undefined, parsed = false, closed = false;
  let code: number | null = null, signal: NodeJS.Signals | null = null;
  const cleanupErrors = new Set<string>();
  let fallback: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    for (const pid of new Set([nativePID, child.pid])) if (pid) {
      const error = kill(pid);
      if (error) cleanupErrors.add(error);
    }
  };
  let cleanup = () => {};
  const completed = new Promise<void>(resolve => {
    const finish = () => { if (!closed) { closed = true; resolve(); } };
    const abandonPipes = () => {
      child.stdout.destroy(); child.stderr.destroy(); child.unref(); finish();
    };
    const terminate = (why: TestProcessResult['reason']) => {
      if (reason === 'exit') reason = why;
      stop();
      fallback ??= setTimeout(abandonPipes, 1000);
    };
    const receive = (chunk: Buffer, stdout: boolean) => {
      if (closed) return;
      if (stdout && !parsed) {
        prefix = (prefix + chunk.toString('utf8')).slice(0, 256);
        const end = prefix.indexOf('\n');
        if (end >= 0 || prefix.length === 256) {
          parsed = true;
          const match = /^SIMULATOR_TEST_PROCESS ([1-9]\d*)\r?\n/.exec(prefix);
          const pid = match ? Number(match[1]) : 0;
          if (Number.isSafeInteger(pid) && pid > 1) nativePID = pid;
          else terminate('launchError');
        }
      }
      bytes += chunk.length;
      if (bytes > limit) { terminate('outputLimit'); return; }
      if (stdout) log += stdoutDecoder.write(chunk);
      else stderr += stderrDecoder.write(chunk);
    };
    child.stdout.on('data', chunk => receive(chunk, true));
    child.stderr.on('data', chunk => receive(chunk, false));
    child.once('error', () => { if (closed) return; reason = 'launchError'; finish(); });
    child.once('exit', (exitCode, exitSignal) => {
      if (closed) return;
      code = exitCode; signal = exitSignal;
      // Descendants can retain stdout after their parent exits. Bound that wait separately.
      fallback ??= setTimeout(() => { fallback = undefined; terminate('outputHeldOpen'); }, 250);
    });
    child.once('close', finish);
    const interrupt = () => terminate('interrupted');
    process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
    const timer = setTimeout(() => terminate('timeout'), options.timeoutMS);
    cleanup = () => {
      clearTimeout(timer); clearTimeout(fallback);
      process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
    };
  });
  try { await completed; }
  finally { cleanup(); stop(); }
  log += stdoutDecoder.end(); stderr += stderrDecoder.end();
  for (const secret of options.secrets ?? []) if (secret) {
    log = log.replaceAll(secret, '<REDACTED>'); stderr = stderr.replaceAll(secret, '<REDACTED>');
  }
  let clean = false;
  try { clean = nativePID !== undefined && await stopped([nativePID, ...(child.pid ? [child.pid] : [])]); } catch { /* Unknown cleanup is not success. */ }
  return { code, signal, reason, log, stderr, elapsedMS: performance.now() - started, nativePID,
    clean, cleanupErrors: [...cleanupErrors] };
}
