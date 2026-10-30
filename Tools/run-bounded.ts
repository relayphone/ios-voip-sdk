import { spawn } from 'node:child_process';
import { constants } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';

export interface BoundedOptions {
  readonly timeoutMs: number;
  readonly signal?: AbortSignal;
}

export interface BoundedResult {
  readonly status: number;
  readonly timedOut: boolean;
}

export async function runBounded(
  command: string,
  args: readonly string[],
  options: BoundedOptions,
): Promise<BoundedResult> {
  if (!command || !Number.isSafeInteger(options.timeoutMs) || options.timeoutMs <= 0 || options.timeoutMs > 2_147_483_647) {
    throw new RangeError('A command and positive integer timeout in milliseconds are required');
  }
  if (options.signal?.aborted) return { status: 130, timedOut: false };
  const deadline = AbortSignal.timeout(options.timeoutMs);
  const child = spawn(command, args, { detached: true, stdio: 'inherit' });
  const pid = child.pid;
  let status: number | undefined;
  let failure: unknown;
  child.once('error', error => { failure = error; });
  const group = (signal: NodeJS.Signals | 0): boolean => {
    if (pid === undefined) return false;
    try {
      process.kill(-pid, signal);
      return true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ESRCH') return false;
      throw error;
    }
  };
  let completed = false;
  let stop: 'timeout' | 'cancelled' | undefined;
  const observeCompletion = () => {
    if (status !== undefined && !group(0)) completed = true;
  };
  child.once('exit', (code, signal) => {
    status = code ?? (signal ? 128 + constants.signals[signal] : 1);
    if (!stop) {
      try { observeCompletion(); } catch (error) { failure = error; }
    }
  });
  const requestStop = (reason: 'timeout' | 'cancelled') => {
    if (!stop && !completed) {
      observeCompletion();
      if (!completed) stop = reason;
    }
  };
  const onTimeout = () => { try { requestStop('timeout'); } catch (error) { failure = error; } };
  const onCancel = () => { try { requestStop('cancelled'); } catch (error) { failure = error; } };
  deadline.addEventListener('abort', onTimeout, { once: true });
  options.signal?.addEventListener('abort', onCancel, { once: true });
  try {
    if (options.signal?.aborted) requestStop('cancelled');
    while (!completed && !stop) {
      if (failure) throw failure;
      observeCompletion();
      if (!completed) await delay(25);
    }
    if (failure) throw failure;
    if (completed) return { status: status ?? 1, timedOut: false };
    const timedOut = stop === 'timeout';
    // macOS can report EPERM for a group containing an unreaped zombie.
    // Retry briefly, but never treat a persistent permission error as cleanup.
    const groupAfterTermination = async (signal: NodeJS.Signals | 0): Promise<boolean> => {
      const retry = AbortSignal.timeout(2000);
      for (;;) {
        try { return group(signal); }
        catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'EPERM' || retry.aborted) throw error;
          await delay(25);
        }
      }
    };
    await groupAfterTermination('SIGTERM');
    const grace = AbortSignal.timeout(2000);
    while (!grace.aborted && await groupAfterTermination(0)) await delay(25);
    if (await groupAfterTermination(0)) await groupAfterTermination('SIGKILL');
    const reap = AbortSignal.timeout(2000);
    while (!reap.aborted && (status === undefined || await groupAfterTermination(0))) {
      if (failure) throw failure;
      await delay(25);
    }
    if (status === undefined || await groupAfterTermination(0)) throw new Error('Owned process group cleanup is uncertain');
    return { status: timedOut ? 124 : 130, timedOut };
  } catch (error) {
    // A failed probe cannot establish ownership cleanup. Kill the group and
    // give the direct child a bounded opportunity to be reaped before failing.
    try { group('SIGKILL'); } catch { /* Preserve the original failure. */ }
    const reap = AbortSignal.timeout(2000);
    while (pid !== undefined && status === undefined && !reap.aborted) await delay(25);
    throw error;
  } finally {
    deadline.removeEventListener('abort', onTimeout);
    options.signal?.removeEventListener('abort', onCancel);
  }
}

async function main(args: string[]): Promise<number> {
  const [seconds, command, ...childArgs] = args;
  const timeoutMs = Number(seconds) * 1000;
  if (!seconds || !command || !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2_147_483_647) {
    console.error('usage: run-bounded <positive-seconds> <command> [args...]');
    return 2;
  }
  const controller = new AbortController();
  let interrupted: NodeJS.Signals | undefined;
  const interrupt = (signal: NodeJS.Signals) => {
    interrupted ??= signal;
    controller.abort();
  };
  const onInt = () => interrupt('SIGINT');
  const onTerm = () => interrupt('SIGTERM');
  process.on('SIGINT', onInt);
  process.on('SIGTERM', onTerm);
  try {
    const result = await runBounded(command, childArgs, { timeoutMs, signal: controller.signal });
    return interrupted && !result.timedOut ? 128 + constants.signals[interrupted] : result.status;
  } catch (error) {
    console.error('run-bounded:', error instanceof Error ? error.message : String(error));
    const code = (error as NodeJS.ErrnoException).code;
    return code === 'ENOENT' ? 127 : code === 'EACCES' ? 126 : 125;
  } finally {
    process.off('SIGINT', onInt);
    process.off('SIGTERM', onTerm);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
