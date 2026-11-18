import { execFile, spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { deadline } from './fixture-runtime.ts';

/** Evidence required from a future lease adapter. These are local types, not a lease wire format. */
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

export function requireSimulatorMedia({ environment, leaseAudio }: Authorization = {
  environment: process.env,
}): void {
  if (environment.GITHUB_ACTIONS === 'true') return;
  const runOnCI = 'Run simulator media and video journeys on hosted GitHub Actions.';
  if (!leaseAudio) {
    throw new SimulatorMediaRefusal(`Simulator media can activate the host speakers and microphone. Isolated simulator leases are not available yet. ${runOnCI}`);
  }
  if (!leaseAudio.isolated || !leaseAudio.virtualInputVerified || !leaseAudio.virtualOutputVerified) {
    throw new SimulatorMediaRefusal(`Simulator lease requires isolated audio and verified virtual input and output routes. ${runOnCI}`);
  }
  throw new SimulatorMediaRefusal(`Isolated simulator lease verification is not available yet. ${runOnCI}`);
}

interface AudioGuard {
  readonly signal: AbortSignal;
  finish(): Promise<string>;
}

const execute = promisify(execFile);
const source = fileURLToPath(new URL('./HostAudioGuard.swift', import.meta.url));

async function startAudioGuard(): Promise<AudioGuard> {
  const scratch = await mkdtemp(join(tmpdir(), 'host-audio-guard-'));
  const binary = join(scratch, 'guard');
  try {
    await execute('xcrun', ['swiftc', '-swift-version', '6', '-warnings-as-errors', source, '-o', binary],
      { timeout: 60_000, killSignal: 'SIGKILL' });
  } catch (cause) {
    await rm(scratch, { recursive: true, force: true });
    throw new Error('Could not build the Core Audio guard', { cause });
  }

  const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'] });
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
    if (line === 'ready: no host devices' || line === 'ready: monitoring default host devices') {
      ready.resolve(line.slice('ready: '.length));
    }
    if (line === 'clean: host audio guard completed') clean = true;
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

export async function withSimulatorMediaAudio<T>(
  run: (signal: AbortSignal) => Promise<T>,
  { authorization = { environment: process.env }, start = startAudioGuard }:
    { authorization?: Authorization; start?: () => Promise<AudioGuard> } = {},
): Promise<T> {
  requireSimulatorMedia(authorization);
  const report = (verdict: string) => {
    console.error(`Core Audio guard ${verdict}`);
    const summary = authorization.environment.GITHUB_STEP_SUMMARY;
    if (summary) appendFileSync(summary, `\nCore Audio guard ${verdict}\n`);
  };
  function fail(cause: unknown): never {
    const failure = new HostAudioGuardFailure(cause instanceof Error ? cause.message : String(cause), { cause });
    report(`failed: ${failure.message}`);
    throw failure;
  }
  let guard: AudioGuard;
  try { guard = await start(); }
  catch (error) { return fail(error); }
  try {
    guard.signal.throwIfAborted();
    return await run(guard.signal);
  } finally {
    let mode: string;
    try {
      mode = await guard.finish();
      guard.signal.throwIfAborted();
    }
    catch (error) { fail(error); }
    report(`passed (${mode})`);
  }
}

/** Supervise the simulator's boot-through-cleanup command on hosted macOS. */
async function runCommand(command: string, args: string[], signal: AbortSignal): Promise<void> {
  const child = spawn(command, args, { detached: true, stdio: 'inherit' });
  const send = (name: NodeJS.Signals) => {
    if (!child.pid) return;
    try {
      process.kill(-child.pid, name);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
    }
  };
  let escalation: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    if (escalation) return;
    send('SIGTERM');
    escalation = setTimeout(() => send('SIGKILL'), 5_000);
  };
  signal.addEventListener('abort', stop, { once: true });
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  try {
    const code = await new Promise<number | null>((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    signal.throwIfAborted();
    if (code !== 0 || escalation) throw new Error(`Simulator command exited with ${code ?? 'a signal'}`);
  } finally {
    if (escalation) { clearTimeout(escalation); send('SIGKILL'); }
    signal.removeEventListener('abort', stop);
    process.removeListener('SIGINT', stop);
    process.removeListener('SIGTERM', stop);
  }
}

if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2);
  if (!command) throw new Error('Usage: simulator-media.ts <command> [args...]');
  await withSimulatorMediaAudio(signal => runCommand(command, args, signal));
}
