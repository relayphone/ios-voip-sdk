import { execFile } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { promisify } from 'node:util';
import { repository, type RunOptions } from './command.ts';

interface ReadyRunOptions extends Pick<RunOptions, 'timeout' | 'environment' | 'directory'> {
  readyPath: string;
  ready: () => void;
}

/** Runs the UI process once and sends the fixture only after its readiness signal. */
export async function runReadyUITest(command: string, args: readonly string[], options: ReadyRunOptions): Promise<string> {
  rmSync(options.readyPath, { force: true });
  const abort = new AbortController();
  let finished = false;
  const running = promisify(execFile)(command, [...args], {
    cwd: options.directory ?? repository,
    env: { ...(options.environment ?? process.env), TEST_RUNNER_CKSIM_INSPECTOR_READY_FILE: options.readyPath },
    encoding: 'utf8', maxBuffer: 256 * 1024 * 1024,
    timeout: (options.timeout ?? 600) * 1000, killSignal: 'SIGKILL', signal: abort.signal,
  }).then(result => result.stdout, (error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    const stdout = error instanceof Error && 'stdout' in error && typeof error.stdout === 'string' ? error.stdout : '';
    const stderr = error instanceof Error && 'stderr' in error && typeof error.stderr === 'string' ? error.stderr : '';
    throw new Error(`${command} ${args.join(' ')}: ${message}\n${stdout}${stderr}`);
  }).finally(() => { finished = true; });
  // Observe rejection while waiting for readiness; the original failure is awaited below.
  void running.catch(() => {});
  try {
    while (!finished && !existsSync(options.readyPath)) await sleep(100);
    if (finished) {
      await running;
      throw new Error('UI runner exited without requesting the incoming call');
    }
    options.ready();
    return await running;
  } finally {
    abort.abort();
    await running.catch(() => {});
    rmSync(options.readyPath, { force: true });
  }
}
