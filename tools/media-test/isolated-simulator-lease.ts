import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import type { SimulatorLeaseAudio } from './simulator-media.ts';

const execute = promisify(execFile);
const maxProofAge = 120_000;
const firstHeartbeatTimeout = 90_000;
const pollInterval = 2_000;
const acquisitionWaitMinutes = 10;
const acquisitionTimeout = acquisitionWaitMinutes * 60_000 + 15_000;
const reattachmentBudget = 15 * 60_000;
const releaseBudget = 90_000;
const transportRetryDelay = 2_000;
const udidPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

export class IsolatedLeaseRefusal extends Error {}
class LeaseTransportError extends IsolatedLeaseRefusal {}

function cliFailure(message: string): IsolatedLeaseRefusal {
  return /cannot reach .*Transport error/i.test(message)
    ? new LeaseTransportError(message) : new IsolatedLeaseRefusal(message);
}

function object(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : {};
}

function reason(value: unknown): string {
  return typeof value === 'string' && value ? `: ${value}` : '';
}

function json(stdout: string): Record<string, unknown> {
  try { return object(JSON.parse(stdout)); }
  catch { throw new IsolatedLeaseRefusal('The isolated simulator lease CLI did not return valid JSON'); }
}

interface Routes {
  input: string;
  output: string;
  slot: string;
  verifiedAt: number;
}

function deviceSlot(uid: string, prefix: string): string | undefined {
  const start = `${prefix} `;
  if (uid.startsWith(start)) return /^([1-9]\d*)_UID$/.exec(uid.slice(start.length))?.[1];
}

function routes(value: unknown, field: string, now: number, config: LeaseConfiguration): Routes {
  const proof = object(value);
  if (proof.isolated !== true) {
    throw new IsolatedLeaseRefusal(`${field}.isolated must be true${reason(proof.reason)}`);
  }
  const { input, output, verifiedAt } = proof;
  if (typeof input !== 'string' || !input) throw new IsolatedLeaseRefusal(`${field}.input is missing`);
  if (typeof output !== 'string' || !output) throw new IsolatedLeaseRefusal(`${field}.output is missing`);
  const inputSlot = deviceSlot(input, config.inputDevicePrefix);
  const outputSlot = deviceSlot(output, config.outputDevicePrefix);
  if (!inputSlot) throw new IsolatedLeaseRefusal(`${field}.input is not a virtual microphone UID`);
  if (!outputSlot) throw new IsolatedLeaseRefusal(`${field}.output is not a virtual speaker UID`);
  if (inputSlot !== outputSlot) throw new IsolatedLeaseRefusal(`${field} device slots do not match`);
  if (typeof verifiedAt !== 'number' || !Number.isSafeInteger(verifiedAt)) {
    throw new IsolatedLeaseRefusal(`${field}.verifiedAt must be an epoch timestamp in milliseconds`);
  }
  if (verifiedAt > now) throw new IsolatedLeaseRefusal(`${field}.verifiedAt is in the future`);
  if (now - verifiedAt > maxProofAge) {
    throw new IsolatedLeaseRefusal(`${field}.verifiedAt is older than 120 seconds`);
  }
  return { input, output, slot: inputSlot, verifiedAt };
}

export interface Proof extends Routes {
  udid: string;
  leaseAudio: SimulatorLeaseAudio;
}

/** Preserves the checker phase files if the outer deadline interrupts its own reporting. */
export async function checkerPhaseLog(scratch: string,
  { checkerDirectoryPrefix, checkerAppId }: Pick<LeaseConfiguration, 'checkerDirectoryPrefix' | 'checkerAppId'>,
): Promise<string> {
  const directories = (await readdir(scratch, { withFileTypes: true }))
    .filter(entry => entry.isDirectory() && entry.name.startsWith(checkerDirectoryPrefix));
  const directory = directories.length === 1 ? join(scratch, directories[0]!.name) : undefined;
  const read = (name: string) => directory
    ? readFile(join(directory, name), 'utf8').catch(() => undefined) : Promise.resolve(undefined);
  const [tone, feed, record, probe] = await Promise.all(
    ['tone.txt', 'feed.txt', 'record.txt', 'probe.txt'].map(read));
  const observations = (probe ?? '').split('\n').filter(line => line.includes(` ${checkerAppId} `));
  return [
    `Playback phase:\n${tone?.trim() || 'No output'}`,
    `Virtual microphone feed phase:\n${feed?.trim() || 'No output'}`,
    `Recording phase:\n${record?.trim() || (record === undefined ? 'Did not start' : 'No output before timeout')}`,
    `Checker process routes:\n${observations.join('\n') || 'No process samples'}`,
  ].join('\n');
}

function readProof(
  view: Record<string, unknown>, id: string, now: number, waitingForHeartbeat: boolean, attached: boolean,
  config: LeaseConfiguration,
): Proof | undefined {
  const lease = object(view.lease);
  if (lease.id !== id) throw new IsolatedLeaseRefusal('The lease response has a different lease identifier');
  const audio = object(lease.audio);
  if (audio.isolated === false && audio.reason !== undefined) routes(audio, 'lease.audio', now, config);
  if (audio.required !== true) throw new IsolatedLeaseRefusal('lease.audio.required must be true');
  if (waitingForHeartbeat && audio.isolated === false && audio.reason === undefined) return;
  const proof = routes(audio, 'lease.audio', now, config);
  const sims = Array.isArray(view.sims) ? view.sims.map(object) : [];
  const owned = sims.filter(sim => sim.leaseId === id);
  const primary = owned.filter(sim => sim.primary === true);
  // A fresh attachment has no locally selected UDID. The lease's one primary is the selection.
  const udid = attached && view.udid === undefined && primary.length === 1 ? primary[0]?.udid : view.udid;
  if (typeof udid !== 'string' || !udidPattern.test(udid)) {
    throw new IsolatedLeaseRefusal('The lease has no valid simulator UDID');
  }
  const simulator = owned.find(sim => sim.udid === udid);
  if (!simulator) throw new IsolatedLeaseRefusal('The lease UDID is missing from its simulator list');
  if ((simulator.platform !== undefined && simulator.platform !== 'ios-sim') || simulator.state !== 'booted') {
    throw new IsolatedLeaseRefusal('The lease UDID must identify a booted iOS simulator');
  }
  const sim = routes(simulator.audio, 'simulator.audio', now, config);
  if (sim.input !== proof.input || sim.output !== proof.output) {
    throw new IsolatedLeaseRefusal('The lease and simulator audio UIDs differ');
  }
  return { ...proof, udid, leaseAudio: { isolated: true, virtualInputVerified: true, virtualOutputVerified: true } };
}

type LeaseCommand = (file: string, args: string[], options: {
  cwd: string; env: NodeJS.ProcessEnv; timeout: number; signal?: AbortSignal;
}) => Promise<{ stdout: string; stderr: string }>;

async function releaseHandle(env: NodeJS.ProcessEnv, { configDir, cliEnv }: LeaseConfiguration): Promise<NodeJS.ProcessEnv | undefined> {
  if (env[cliEnv.leaseId]) return env;
  const readState = async (file: string) => {
    try { return json(await readFile(join(configDir, file), 'utf8')); }
    catch { return {}; }
  };
  const saved = object((await readState('leases.json'))[env[cliEnv.scope]!]);
  const url = env[cliEnv.url] ?? (await readState('config.json')).url;
  if (typeof saved.leaseId !== 'string' || typeof saved.token !== 'string' || typeof url !== 'string') return;
  return { ...env, [cliEnv.url]: url, [cliEnv.leaseId]: saved.leaseId, [cliEnv.leaseToken]: saved.token };
}

export interface LeaseConfiguration {
  cli: string;
  checker: string;
  configDir: string;
  cliErrorPrefix: string;
  cliSecretPattern: RegExp;
  cliEnv: { scope: string; url: string; leaseId: string; leaseToken: string };
  inputDevicePrefix: string;
  outputDevicePrefix: string;
  checkerAppId: string;
  checkerDirectoryPrefix: string;
  project?: string;
  environment: NodeJS.ProcessEnv;
}

export function isolatedLeaseConfiguration(environment: NodeJS.ProcessEnv): LeaseConfiguration | undefined {
  if (!Object.entries(environment).some(([name, value]) => name.startsWith('ISOLATED_LEASE_') && value)) return;
  const required = (suffix: string) => {
    const name = `ISOLATED_LEASE_${suffix}`;
    const value = environment[name]?.trim();
    if (!value) throw new IsolatedLeaseRefusal(`Set ${name} to configure the isolated simulator lease`);
    return value;
  };
  const cli = required('CLI');
  const checker = required('CHECKER');
  const configDir = required('CONFIG_DIR');
  if (!isAbsolute(checker) || !isAbsolute(configDir)) {
    throw new IsolatedLeaseRefusal('ISOLATED_LEASE_CHECKER and ISOLATED_LEASE_CONFIG_DIR must be absolute paths');
  }
  const pattern = required('CLI_SECRET_PATTERN');
  let cliSecretPattern: RegExp;
  try { cliSecretPattern = new RegExp(pattern, 'g'); }
  catch { throw new IsolatedLeaseRefusal('ISOLATED_LEASE_CLI_SECRET_PATTERN must be a valid regular expression'); }
  const cliEnv = { scope: required('CLI_SCOPE_ENV'), url: required('CLI_URL_ENV'),
    leaseId: required('CLI_LEASE_ID_ENV'), leaseToken: required('CLI_LEASE_TOKEN_ENV') };
  if (new Set(Object.values(cliEnv)).size !== 4 || Object.values(cliEnv).some(name => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name))) {
    throw new IsolatedLeaseRefusal('The isolated lease CLI environment variable names must be valid and distinct');
  }
  const inputDevicePrefix = required('INPUT_DEVICE_PREFIX');
  const outputDevicePrefix = required('OUTPUT_DEVICE_PREFIX');
  if (inputDevicePrefix === outputDevicePrefix) throw new IsolatedLeaseRefusal('The virtual input and output prefixes must differ');
  return {
    cli, checker, configDir, cliSecretPattern, cliEnv, inputDevicePrefix, outputDevicePrefix,
    cliErrorPrefix: required('CLI_ERROR_PREFIX'),
    checkerAppId: required('CHECKER_APP_ID'),
    checkerDirectoryPrefix: required('CHECKER_DIRECTORY_PREFIX'),
    project: environment.ISOLATED_LEASE_PROJECT?.trim() || undefined, environment,
  };
}

export async function withIsolatedSimulatorLease<T>(
  config: LeaseConfiguration,
  signal: AbortSignal,
  run: (proof: Proof, signal: AbortSignal) => Promise<T>,
  check: (checker: string, udid: string, signal: AbortSignal) => Promise<string>,
  report: (line: string) => void,
  { command = execute, now = Date.now, elapsed = () => performance.now(),
    pause = (ms, signal) => delay(ms, undefined, { signal }), shutdown, arm, prepareRelease }: {
    command?: LeaseCommand; now?: () => number; pause?: (ms: number, signal: AbortSignal) => Promise<void>;
    elapsed?: () => number;
    shutdown?: (udid: string) => Promise<string>;
    arm?: (proof: Proof, signal: AbortSignal) => Promise<AbortSignal>;
    prepareRelease?: () => void;
  } = {},
): Promise<T> {
  const { cli, checker, project, environment, cliEnv, cliErrorPrefix, cliSecretPattern } = config;
  const redactLeaseOutput = (output: string) => output.replace(cliSecretPattern, '[redacted]');
  let id = environment[cliEnv.leaseId];
  const attached = Boolean(id);
  if (Boolean(id) !== Boolean(environment[cliEnv.leaseToken])) {
    throw new IsolatedLeaseRefusal('An existing isolated simulator lease requires both its identifier and its token');
  }
  // Scope acquisition and cleanup to this run, including when acquisition fails after creating a lease.
  const env: NodeJS.ProcessEnv = id || environment[cliEnv.scope] ? { ...environment }
    : { ...environment, [cliEnv.scope]: randomUUID() };
  const cwd = process.cwd();
  async function invoke(args: string[], timeout: number, cancellation?: AbortSignal, commandEnv = env): Promise<string> {
    const acquiring = args[0] === 'up';
    try {
      const result = await command(cli, args, { cwd, env: commandEnv, timeout, signal: cancellation });
      if (acquiring) report(redactLeaseOutput([result.stderr.trim(), result.stdout.trim()].filter(Boolean).join('\n')));
      const releaseError = args[0] === 'down' && /^release: (.+)$/m.exec(result.stderr)?.[1];
      if (releaseError) throw cliFailure(`Could not release isolated simulator lease: ${redactLeaseOutput(releaseError)}`);
      return result.stdout;
    } catch (error) {
      if (error instanceof IsolatedLeaseRefusal) throw error;
      const failure = object(error);
      const stderr = typeof failure.stderr === 'string' ? redactLeaseOutput(failure.stderr.trim()) : '';
      const stdout = typeof failure.stdout === 'string' ? redactLeaseOutput(failure.stdout.trim()) : '';
      if (acquiring && (stderr || stdout)) report([stderr, stdout].filter(Boolean).join('\n'));
      cancellation?.throwIfAborted();
      const diagnostic = stderr.split(/\r?\n/).find(line => line.startsWith(cliErrorPrefix))
        ?.slice(cliErrorPrefix.length).trim() ?? stderr;
      if (args[0] === 'down' && failure.killed === true) {
        throw new LeaseTransportError(`Isolated simulator lease release command timed out${reason(diagnostic)}`);
      }
      const details = acquiring && failure.killed === true
        ? `acquisition command timed out${reason(diagnostic)}` : diagnostic || failure.code;
      throw cliFailure(`Isolated simulator lease CLI failed (${args[0]})${reason(details)}`);
    }
  }

  async function retryTransport<T>(
    budget: number, cancellation: AbortSignal, operation: (remaining: number) => Promise<T>,
  ): Promise<T> {
    const deadline = elapsed() + budget;
    let failure: LeaseTransportError | undefined;
    while (elapsed() < deadline) {
      cancellation.throwIfAborted();
      try { return await operation(Math.max(1, Math.floor(deadline - elapsed()))); }
      catch (error) {
        if (!(error instanceof LeaseTransportError)) throw error;
        failure = error;
      }
      const wait = Math.min(transportRetryDelay, deadline - elapsed());
      if (wait > 0) await pause(wait, cancellation);
    }
    throw new IsolatedLeaseRefusal(`Isolated simulator lease transport retry deadline expired${reason(failure?.message)}`);
  }

  async function release() {
    // The CLI clears its local lease record even when the DELETE request fails.
    const handle = await releaseHandle(env, config);
    let commandEnv = env;
    return retryTransport(releaseBudget, new AbortController().signal, async remaining => {
      try { await invoke(['down'], Math.min(remaining, 30_000), undefined, commandEnv); }
      catch (error) {
        if (!(error instanceof LeaseTransportError) || !handle) {
          throw new IsolatedLeaseRefusal(error instanceof Error ? error.message : String(error));
        }
        commandEnv = handle;
        report('Lease release transport failed. Retrying cleanup for the same lease.');
        throw error;
      }
    });
  }

  const stop = new AbortController();
  const localSignal = AbortSignal.any([signal, stop.signal]);
  const polling = new AbortController();
  const pollSignal = AbortSignal.any([localSignal, polling.signal]);
  let monitor: Promise<void> | undefined;
  let primaryFailure: unknown;
  let shutdownOnAbort: Promise<unknown> | undefined;
  let stopSimulator: (() => void) | undefined;
  let guard: AbortSignal | undefined;
  const trip = () => stop.abort(guard?.reason);
  try {
    let acquiredProof: (Routes & { udid: string }) | undefined;
    if (!id) {
      report(`[${new Date(now()).toISOString()}] Requesting an isolated simulator lease with a ten-minute wait`);
      const args = ['up', '--audio', 'isolated', '--platform', 'ios-sim', '--wait', String(acquisitionWaitMinutes)];
      if (project) args.push('--project', project);
      const acquired = json(await retryTransport(reattachmentBudget, localSignal, async remaining => {
        try { return await invoke(args, Math.min(remaining, acquisitionTimeout), localSignal); }
        catch (error) {
          if (error instanceof LeaseTransportError) report('Lease heartbeat transport failed. Reattaching to the queued lease.');
          throw error;
        }
      }));
      if (typeof acquired.lease !== 'string' || !acquired.lease) {
        throw new IsolatedLeaseRefusal('Acquisition returned no isolated simulator lease identifier');
      }
      id = acquired.lease;
      if (typeof acquired.udid !== 'string' || !udidPattern.test(acquired.udid)) {
        throw new IsolatedLeaseRefusal('Acquisition returned no valid simulator UDID');
      }
      acquiredProof = { udid: acquired.udid, ...routes(acquired.audio, 'audio', now(), config) };
    }

    const leaseID = id;
    const heartbeat = AbortSignal.timeout(firstHeartbeatTimeout);
    const startupSignal = AbortSignal.any([localSignal, heartbeat]);
    let proof: Proof | undefined;
    try {
      while (!proof) {
        const view = json(await invoke(['lease'], 10_000, startupSignal));
        proof = readProof(view, leaseID, now(), true, attached, config);
        if (!proof) await pause(pollInterval, startupSignal);
      }
    } catch (error) {
      if (heartbeat.aborted && !localSignal.aborted) {
        throw new IsolatedLeaseRefusal('lease.audio.isolated stayed false for 90 seconds without an isolation heartbeat');
      }
      throw error;
    }
    if (acquiredProof && (acquiredProof.udid !== proof.udid
      || acquiredProof.input !== proof.input || acquiredProof.output !== proof.output)) {
      throw new IsolatedLeaseRefusal('The acquired simulator and lease audio proofs differ');
    }
    const expected = proof;
    stopSimulator = () => {
      shutdownOnAbort = shutdown?.(expected.udid).catch(() => {
        report('Immediate simulator shutdown could not be confirmed. Releasing the isolated simulator lease.');
      });
    };
    localSignal.addEventListener('abort', stopSimulator, { once: true });
    localSignal.throwIfAborted();
    report(`Isolated simulator lease proof: ${JSON.stringify({
      required: true, isolated: true, udid: proof.udid, input: proof.input, output: proof.output,
      verifiedAt: proof.verifiedAt,
    })}`);
    async function refreshProof(cancellation: AbortSignal) {
      const view = json(await invoke(['lease'], 10_000, cancellation));
      const updated = readProof(view, leaseID, now(), false, attached, config);
      if (updated?.udid !== expected.udid || updated.input !== expected.input || updated.output !== expected.output) {
        throw new IsolatedLeaseRefusal('The isolated simulator lease route changed during the run');
      }
      return updated;
    }
    monitor = (async () => {
      while (!pollSignal.aborted) {
        await pause(pollInterval, pollSignal);
        await refreshProof(pollSignal);
      }
    })().catch(error => { if (!pollSignal.aborted) stop.abort(error); });
    if (arm) {
      try { guard = await arm(proof, localSignal); }
      catch (error) { stop.abort(error); throw error; }
      if (guard.aborted) trip();
      else guard.addEventListener('abort', trip, { once: true });
    }
    localSignal.throwIfAborted();
    let output: string;
    try {
      output = await check(checker, proof.udid, localSignal);
    } catch (error) {
      localSignal.throwIfAborted();
      const diagnostic = error instanceof Error ? error.message : undefined;
      throw new IsolatedLeaseRefusal(`The host-side audio isolation checker failed${reason(diagnostic)}`);
    }
    if (!output.split(/\r?\n/).some(line => line.startsWith(`PASS: slot ${expected.slot} isolated (`))) {
      throw new IsolatedLeaseRefusal('The host-side audio isolation checker did not confirm the proved slot');
    }
    report(output.trim());
    proof = await refreshProof(localSignal);
    report(`Isolated simulator lease proof refreshed at ${new Date(proof.verifiedAt).toISOString()}.`);
    localSignal.throwIfAborted();
    const result = await run(proof, localSignal);
    localSignal.throwIfAborted();
    return result;
  } catch (error) {
    primaryFailure = localSignal.aborted ? localSignal.reason : error;
    throw primaryFailure;
  } finally {
    polling.abort();
    await monitor;
    try {
      await shutdownOnAbort;
      prepareRelease?.();
      try { await release(); }
      catch (error) {
        if (!primaryFailure) throw error;
        report(error instanceof Error ? error.message : String(error));
      }
      await shutdownOnAbort;
      if (!primaryFailure) localSignal.throwIfAborted();
    } finally {
      guard?.removeEventListener('abort', trip);
      if (stopSimulator) localSignal.removeEventListener('abort', stopSimulator);
    }
  }
}
