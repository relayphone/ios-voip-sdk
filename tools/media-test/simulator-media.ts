import { execFile, spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { command as executeCommand, deadline } from './fixture-runtime.ts';
import { checkerPhaseLog, isolatedLeaseConfiguration, withIsolatedSimulatorLease } from './isolated-simulator-lease.ts';

/** Evidence mapped from the verified simulator lease. */
export interface SimulatorLeaseAudio {
  isolated: boolean;
  virtualInputVerified: boolean;
  virtualOutputVerified: boolean;
}

interface Authorization {
  environment: NodeJS.ProcessEnv;
  leaseAudio?: SimulatorLeaseAudio;
}

export class SimulatorMediaRefusal extends Error {}
export class HostAudioGuardFailure extends Error {}

function isHosted(environment: NodeJS.ProcessEnv): boolean {
  return environment.GITHUB_ACTIONS === 'true' && environment.RUNNER_ENVIRONMENT === 'github-hosted';
}

export function requireSimulatorMedia({ environment, leaseAudio }: Authorization = {
  environment: process.env,
}): void {
  if (isHosted(environment)) return;
  const runOnCI = 'Use hosted GitHub Actions or a verified isolated simulator lease.';
  if (!leaseAudio) {
    throw new SimulatorMediaRefusal(`Simulator media can activate the host speakers and microphone. ${runOnCI}`);
  }
  if (!leaseAudio.isolated || !leaseAudio.virtualInputVerified || !leaseAudio.virtualOutputVerified) {
    throw new SimulatorMediaRefusal(`Simulator lease requires isolated audio and verified virtual input and output routes. ${runOnCI}`);
  }
}

/** Selects the proved simulator and refuses other destinations during a local journey. */
function simulatorForMedia(requested: string, leased: string): string {
  if (requested === 'lease' || requested.toLowerCase() === leased.toLowerCase()) return leased;
  throw new SimulatorMediaRefusal('The requested simulator UDID differs from the verified isolated simulator lease');
}

interface AudioGuard {
  readonly signal: AbortSignal;
  track?(pid: number): void;
  prepareRelease?(): void;
  finish(): Promise<string>;
}

const execute = promisify(execFile);
const guardSources = ['main.swift', 'AudioTransport.swift', 'LeaseAudioMonitor.swift'].map(
  file => fileURLToPath(new URL(`./HostAudioGuard/Sources/HostAudioGuard/${file}`, import.meta.url)),
);

async function startAudioGuard(
  reportDevice: (line: string) => void, env: NodeJS.ProcessEnv, args: string[] = [],
): Promise<AudioGuard> {
  const scratch = await mkdtemp(join(tmpdir(), 'host-audio-guard-'));
  const binary = join(scratch, 'guard');
  try {
    await execute('xcrun', ['swiftc', '-swift-version', '6', '-warnings-as-errors', ...guardSources, '-o', binary],
      { timeout: 60_000, killSignal: 'SIGKILL' });
  } catch (cause) {
    await rm(scratch, { recursive: true, force: true });
    throw new Error('Could not build the Core Audio guard', { cause });
  }

  const child = spawn(binary, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const controller = new AbortController();
  const ready = Promise.withResolvers<string>();
  let diagnostic = '';
  let clean = false;
  let finishing = false;
  const fail = (error: Error) => { ready.reject(error); controller.abort(error); };
  child.once('error', () => fail(new Error('Could not start the Core Audio guard')));
  child.stdin.on('error', () => { /* The process exit supplies the guard verdict. */ });
  child.stderr.setEncoding('utf8').on('data', chunk => { diagnostic += chunk; });
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    if (line === 'ready: no host devices' || line === 'ready: monitoring default host devices' ||
      line === 'ready: monitoring isolated simulator processes') {
      ready.resolve(line.slice('ready: '.length));
    }
    if (line === 'clean: host audio guard completed') clean = true;
    if (line.startsWith('audio route: ')) {
      try { reportDevice(line.slice('audio route: '.length)); }
      catch (cause) { fail(new Error('Could not report the Core Audio route', { cause })); }
    }
  });
  const closed = new Promise<void>(resolve => child.once('close', code => {
    if (!finishing || code !== 0 || !clean) {
      fail(new Error(diagnostic.trim() || 'Core Audio guard exited without a clean verdict'));
    }
    resolve();
  }));
  try {
    const mode = await deadline(10_000, 'Core Audio guard readiness', () => ready.promise);
    return {
      signal: controller.signal,
      track(pid) {
        controller.signal.throwIfAborted();
        if (!Number.isSafeInteger(pid) || pid <= 1) throw new Error('Invalid simulator app PID');
        child.stdin.write(`${pid}\n`);
      },
      prepareRelease() { child.stdin.write('release\n'); },
      async finish() {
        finishing = true;
        child.stdin.end();
        try {
          await deadline(5_000, 'Core Audio guard verdict', () => closed);
          controller.signal.throwIfAborted();
          return mode;
        } finally {
          if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
          await rm(scratch, { recursive: true, force: true });
        }
      },
    };
  } catch (error) {
    child.kill('SIGKILL');
    await rm(scratch, { recursive: true, force: true });
    throw error;
  }
}

/** Checks admission and holds the host audio guard from before setup through cleanup. */
export async function withSimulatorMediaAudio<T>(
  run: (signal: AbortSignal, simulator?: string, trackSimulatorApp?: (pid: number) => void) => Promise<T>,
  { authorization = { environment: process.env }, start = startAudioGuard, lease = withIsolatedSimulatorLease, localDestination }:
    { authorization?: Authorization; start?: typeof startAudioGuard; lease?: typeof withIsolatedSimulatorLease;
      localDestination?: { simulator: string } | 'check-lease' } = {},
): Promise<T> {
  const { environment } = authorization;
  const localLease = isHosted(environment) ? undefined : isolatedLeaseConfiguration(environment);
  if (!localLease) requireSimulatorMedia({ environment });
  if (localLease && !localDestination) {
    throw new SimulatorMediaRefusal('This entry point must bind its destination to the isolated simulator lease');
  }
  const record = (line: string) => {
    console.error(line);
    const summary = authorization.environment.GITHUB_STEP_SUMMARY;
    if (summary) appendFileSync(summary, `\n${line}\n`);
  };
  const report = (verdict: string) => record(`Core Audio guard ${verdict}`);
  function fail(cause: unknown): never {
    const failure = new HostAudioGuardFailure(cause instanceof Error ? cause.message : String(cause), { cause });
    report(`failed: ${failure.message}`);
    throw failure;
  }
  const interruption = new AbortController();
  const interrupt = () => interruption.abort(new Error('Simulator media journey interrupted'));
  if (localLease) {
    process.on('SIGINT', interrupt);
    process.on('SIGTERM', interrupt);
  }
  let guard: AudioGuard | undefined;
  async function arm(args?: string[]) {
    try {
      guard = await start(line => record(`Core Audio route ${line}`), environment, args);
      return guard.signal;
    } catch (error) { return fail(error); }
  }
  try {
    if (!localLease) {
      const signal = await arm();
      signal.throwIfAborted();
      return await run(signal);
    }
    return await lease(localLease, interruption.signal, (proof, leaseSignal) => {
      requireSimulatorMedia({ environment, leaseAudio: proof.leaseAudio });
      const simulator = localDestination && localDestination !== 'check-lease'
        ? simulatorForMedia(localDestination.simulator, proof.udid) : proof.udid;
      return run(leaseSignal, simulator, guard?.track);
    }, (checker, udid, leaseSignal) => runChecker(checker, udid, leaseSignal, environment), record, {
      async arm(proof, signal) {
        // Relative paths select the simulator runtime's executable in simctl.
        const launchd = await executeCommand('xcrun', ['simctl', 'spawn', proof.udid, 'bin/launchctl', 'managerpid'],
          10_000, signal).catch(error => {
          signal.throwIfAborted();
          throw new Error('Could not read the isolated simulator launchd PID', { cause: error });
        });
        signal.throwIfAborted();
        return arm([proof.udid, launchd, proof.input, proof.output]);
      },
      prepareRelease: () => guard?.prepareRelease?.(),
      shutdown: udid => executeCommand('xcrun', ['simctl', 'shutdown', udid], 10_000),
    });
  } finally {
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    if (guard) {
      let mode: string;
      try {
        mode = await guard.finish();
        guard.signal.throwIfAborted();
      }
      catch (error) { fail(error); }
      report(`passed (${mode})`);
    }
  }
}

class AudioCheckerTimeout extends Error {
}

async function runChecker(checker: string, udid: string, signal: AbortSignal, env: NodeJS.ProcessEnv) {
  const scratch = await mkdtemp(join(tmpdir(), 'simulator-audio-check-'));
  try {
    return await runCommand(checker, [udid], signal, { capture: true, env: { ...env, TMPDIR: scratch } });
  } catch (error) {
    if (!(error instanceof AudioCheckerTimeout)) throw error;
    throw new Error(`${error.message}\n${await checkerPhaseLog(scratch)}`);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

/** Supervise the entire command group, including a checker's playback and capture processes. */
async function runCommand(command: string, args: string[], signal: AbortSignal,
  { capture = false, env }: { capture?: boolean; env?: NodeJS.ProcessEnv } = {},
): Promise<string> {
  signal.throwIfAborted();
  const child = spawn(command, args, {
    detached: true, env, stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
  });
  let stdout = '', stderr = '';
  child.stdout?.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
  child.stderr?.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
  const send = (name: NodeJS.Signals) => {
    if (!child.pid) return;
    try {
      process.kill(-child.pid, name);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
    }
  };
  let escalation: ReturnType<typeof setTimeout> | undefined;
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    send(capture ? 'SIGKILL' : 'SIGTERM');
    if (!capture) escalation = setTimeout(() => send('SIGKILL'), 5_000);
  };
  let timedOut = false;
  const timeout = capture ? setTimeout(() => { timedOut = true; stop(); }, 120_000) : undefined;
  signal.addEventListener('abort', stop, { once: true });
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  try {
    const code = await new Promise<number | null>((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    signal.throwIfAborted();
    if (timedOut) throw new AudioCheckerTimeout(
      ['The audio isolation checker exceeded 120 seconds', (stdout + stderr).trim()].filter(Boolean).join('\n'));
    if (code !== 0 || stopping) {
      if (capture) throw new Error((stdout + stderr).trim() || 'The audio isolation checker did not complete successfully');
      throw new Error(`Simulator command exited with ${code ?? 'a signal'}`);
    }
    return stdout;
  } finally {
    clearTimeout(timeout);
    if (escalation) { clearTimeout(escalation); send('SIGKILL'); }
    signal.removeEventListener('abort', stop);
    process.removeListener('SIGINT', stop);
    process.removeListener('SIGTERM', stop);
  }
}

if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2);
  if (!command) throw new Error('Usage: simulator-media.ts --check-lease | <hosted command> [args...]');
  if (command === '--check-lease') {
    if (args.length || isHosted(process.env)) throw new Error('--check-lease requires a local isolated simulator lease');
    await withSimulatorMediaAudio(async () => {}, { localDestination: 'check-lease' });
  } else {
    requireSimulatorMedia();
    await withSimulatorMediaAudio(signal => runCommand(command, args, signal));
  }
}
