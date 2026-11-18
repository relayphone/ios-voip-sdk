import { execFile, spawn } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import { promisify } from 'node:util';
import { StringDecoder } from 'node:string_decoder';
import { setTimeout as delay } from 'node:timers/promises';

const execute = promisify(execFile);

export interface TestProcessResult {
  code: number | null;
  signal: NodeJS.Signals | null;
  reason: 'exit' | 'startupTimeout' | 'timeout' | 'outputLimit' | 'interrupted' | 'launchError' | 'outputHeldOpen';
  /** Original stdout, kept separate so diagnostics cannot split a structured receipt. */
  log: string;
  stderr: string;
  elapsedMS: number;
  /** Time through launcher exit and pipe handling, before final group cleanup. */
  processElapsedMS: number;
  /** Time from host start to the native readiness marker, when requested and observed. */
  readyElapsedMS?: number;
  nativePID?: number;
  clean: boolean;
  cleanupErrors: string[];
}
export interface TestProcessReadiness {
  /** Exact LF-terminated stdout line after the native process ownership receipt. */
  line: string;
  timeoutMS: number;
}

type ProcessGroupInspection = {
  existingGroups: number[];
  timeoutMS: number;
  states?: string[][];
  error?: string;
  remainingGroups?: number[];
};

async function readProcessGroupStates(timeout: number): Promise<string> {
  // An execFile timeout can discard unread stdout even when ps exits successfully.
  const { stdout } = await execute('/bin/ps', ['-axo', 'pgid=,stat='], {
    signal: AbortSignal.timeout(timeout), killSignal: 'SIGKILL', maxBuffer: 256 * 1024,
  });
  return stdout;
}

function groupMayExist(group: number): boolean {
  try {
    process.kill(-group, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== 'ESRCH';
  }
}

export async function confirmGroupsStopped(
  groups: number[], cleanupErrors: Set<string>, inspect = readProcessGroupStates,
  onGroupInspection?: (inspection: ProcessGroupInspection) => void,
): Promise<boolean> {
  let inspectionTimeout = 500;
  const settleDeadline = performance.now() + inspectionTimeout;
  let observedLiveGroup = false;
  // A live process can still be handling SIGKILL when the launcher closes its pipes.
  do {
    const existingGroups = groups.filter(groupMayExist);
    if (!existingGroups.length) {
      onGroupInspection?.({ existingGroups, timeoutMS: inspectionTimeout });
      return true;
    }
    let stdout: string;
    try {
      stdout = await inspect(inspectionTimeout);
    } catch (error) {
      // A group can disappear while the process table scan is in flight.
      const remainingGroups = groups.filter(groupMayExist);
      const failure = error as NodeJS.ErrnoException & { signal?: NodeJS.Signals };
      const inspectionError = `processInspection:${failure.code ?? failure.signal ?? 'unknown'}`;
      onGroupInspection?.({ existingGroups, timeoutMS: inspectionTimeout, error: inspectionError, remainingGroups });
      if (!remainingGroups.length) return true;
      cleanupErrors.add(inspectionError);
      break;
    }
    const states = stdout.split('\n').map(line => line.trim().split(/\s+/, 2))
      .filter(([group]) => groups.includes(Number(group)));
    onGroupInspection?.({ existingGroups, timeoutMS: inspectionTimeout, states });
    if (!states.some(([, state]) => !state?.startsWith('Z'))) return true;
    observedLiveGroup = true;
    if (settleDeadline - performance.now() > 25) await delay(25);
    inspectionTimeout = Math.ceil(settleDeadline - performance.now());
  } while (inspectionTimeout > 0);
  if (observedLiveGroup) cleanupErrors.add('liveProcessGroup');
  return false;
}
const kill = (pid: number) => {
  try { process.kill(-pid, 'SIGKILL'); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ESRCH') return (error as NodeJS.ErrnoException).code ?? 'unknown'; }
};

/** Owns both host and simulator groups; output or a passed-test line never substitutes for exit. */
export async function runTestProcess(options: {
  command: string; args: string[]; timeoutMS: number; env?: NodeJS.ProcessEnv;
  secrets?: string[]; outputLimit?: number; readiness?: TestProcessReadiness;
  onGroupInspection?: (inspection: ProcessGroupInspection) => void;
}): Promise<TestProcessResult> {
  if (!Number.isSafeInteger(options.timeoutMS) || options.timeoutMS <= 0) throw new Error('Invalid test timeout');
  const limit = options.outputLimit ?? 16 * 1024 * 1024;
  if (!Number.isSafeInteger(limit) || limit <= 0) throw new Error('Invalid output limit');
  const { readiness } = options;
  if (readiness && (!readiness.line || /[\r\n]/.test(readiness.line) ||
    !Number.isSafeInteger(readiness.timeoutMS) || readiness.timeoutMS <= 0)) throw new Error('Invalid test readiness');
  const marker = readiness && `\n${readiness.line}\n`;
  const started = performance.now();
  const child = spawn(options.command, options.args, { detached: true, env: options.env, stdio: ['ignore', 'pipe', 'pipe'] });
  let reason: TestProcessResult['reason'] = 'exit', log = '', stderr = '', bytes = 0, prefix = '';
  const stdoutDecoder = new StringDecoder('utf8'), stderrDecoder = new StringDecoder('utf8');
  let nativePID: number | undefined, parsed = false, closed = false;
  let readyElapsedMS: number | undefined;
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
      // A failed signal may leave the pipes open indefinitely. Once the native
      // group is known, give buffered output a short grace before settling.
      const pipeGraceMS = cleanupErrors.size > 0 && nativePID !== undefined ? 250 : 1000;
      fallback ??= setTimeout(abandonPipes, pipeGraceMS);
    };
    let timer = readiness
      ? setTimeout(() => terminate('startupTimeout'), readiness.timeoutMS)
      : setTimeout(() => terminate('timeout'), options.timeoutMS);
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
      if (!stdout) {
        stderr += stderrDecoder.write(chunk);
        return;
      }
      const previousLength = log.length;
      log += stdoutDecoder.write(chunk);
      if (marker && nativePID !== undefined && readyElapsedMS === undefined && reason === 'exit' &&
        log.includes(marker, Math.max(0, previousLength - marker.length + 1))) {
        readyElapsedMS = performance.now() - started;
        clearTimeout(timer);
        timer = setTimeout(() => terminate('timeout'), options.timeoutMS);
      }
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
    cleanup = () => {
      clearTimeout(timer); clearTimeout(fallback);
      process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
    };
  });
  let processElapsedMS: number;
  try {
    await completed;
    processElapsedMS = performance.now() - started;
  }
  finally { cleanup(); stop(); }
  log += stdoutDecoder.end(); stderr += stderrDecoder.end();
  for (const secret of options.secrets ?? []) if (secret) {
    log = log.replaceAll(secret, '<REDACTED>'); stderr = stderr.replaceAll(secret, '<REDACTED>');
  }
  const clean = nativePID !== undefined &&
    await confirmGroupsStopped([...new Set([nativePID, ...(child.pid ? [child.pid] : [])])], cleanupErrors,
      readProcessGroupStates, options.onGroupInspection);
  return { code, signal, reason, log, stderr, elapsedMS: performance.now() - started, processElapsedMS, readyElapsedMS,
    nativePID, clean, cleanupErrors: [...cleanupErrors] };
}
