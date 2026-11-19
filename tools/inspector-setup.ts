// Bounded setup of a disposable simulator owned by the Inspector journey.
import { spawnSync } from 'node:child_process';
import { isString } from './json-fields.ts';
import { setTimeout as sleep } from 'node:timers/promises';

export interface SetupResult {
  status: number | null;
  signal: string | null;
  stderr: string;
  errorCode?: string;
}
type Phase = 'boot' | 'bootstatus' | 'install' | 'shutdown' | 'erase';
interface SetupOptions {
  execute?: (args: readonly string[], timeoutMS: number) => SetupResult;
  delay?: (milliseconds: number) => Promise<void>;
  now?: () => number;
  report: (message: string) => void;
}

function execute(args: readonly string[], timeout: number) {
  const result = spawnSync('xcrun', ['simctl', ...args], {
    encoding: 'utf8', timeout, killSignal: 'SIGKILL', maxBuffer: 1024 * 1024,
  });
  const error = result.error;
  const errorCode = error && 'code' in error && isString(error.code) ? error.code : undefined;
  return { status: result.status, signal: result.signal, stderr: result.stderr ?? '', errorCode };
}

export class SimulatorSetupFailure extends Error {
  readonly phase: Phase;
  readonly result: SetupResult;
  constructor(phase: Phase, result: SetupResult) {
    super(`infra:setup:${phase}: ${JSON.stringify(result)}`);
    this.phase = phase;
    this.result = result;
  }
}

/** Only known service/transport failures may retry; invalid apps and unknown failures stop. */
export function transientSetupFailure(result: SetupResult) {
  return result.errorCode === 'ETIMEDOUT'
    || /\b(?:operation timed out|connection timed out|connection interrupted|connection invalid|CoreSimulatorService connection became invalid|failed to connect to installd|unable to boot device in current state: Shutdown)\b/i.test(result.stderr);
}

/** Waits for boot completion before every install attempt; erases only this owned device once. */
export async function setupInspectorSimulator(device: string, app: string, options: SetupOptions) {
  const run = options.execute ?? execute;
  const delay = options.delay ?? sleep;
  const now = options.now ?? (() => performance.now());
  const deadline = now() + 12 * 60_000;
  const attempts = new Map<Phase, number>();
  const command = (phase: Phase, args: readonly string[], limit: number) => {
    const remaining = deadline - now();
    const result = remaining <= 0
      ? { status: null, signal: null, stderr: 'Simulator setup budget exhausted', errorCode: 'SETUP_DEADLINE' }
      : run(args, Math.max(1, Math.min(limit, Math.floor(remaining))));
    const attempt = (attempts.get(phase) ?? 0) + 1;
    attempts.set(phase, attempt);
    const record = JSON.stringify({ phase, device, attempt, exitCode: result.status,
      signal: result.signal, errorCode: result.errorCode, stderr: result.stderr });
    // Preserve stderr verbatim in JSON while preventing it from becoming summary markup.
    options.report(`infra:setup <pre>${record.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</pre>`);
    if (result.status !== 0 || result.signal !== null || result.errorCode) {
      throw new SimulatorSetupFailure(phase, result);
    }
  };
  const boot = () => command('boot', ['boot', device], 120_000);
  const ready = () => command('bootstatus', ['bootstatus', device, '-b'], 300_000);
  for (let recovery = 0; recovery < 2; recovery++) {
    try {
      boot();
      for (let attempt = 0; attempt < 3; attempt++) {
        ready();
        try {
          command('install', ['install', device, app], 90_000);
          options.report(`infra:setup passed; erase recovery used: ${recovery}`);
          return;
        } catch (error) {
          if (!(error instanceof SimulatorSetupFailure) || !transientSetupFailure(error.result) || attempt === 2) throw error;
          const backoff = attempt === 0 ? 2000 : 5000;
          options.report(`infra:setup:install retrying after ${backoff}ms`);
          await delay(Math.min(backoff, Math.max(0, deadline - now())));
        }
      }
    } catch (error) {
      if (!(error instanceof SimulatorSetupFailure) || !transientSetupFailure(error.result) || recovery === 1) throw error;
      options.report('infra:setup recovering owned device with one erase and reboot');
      try { command('shutdown', ['shutdown', device], 30_000); }
      catch (shutdownError) {
        if (!(shutdownError instanceof SimulatorSetupFailure)
          || !/current state: Shutdown/i.test(shutdownError.result.stderr)) throw shutdownError;
      }
      command('erase', ['erase', device], 120_000);
    }
  }
}
