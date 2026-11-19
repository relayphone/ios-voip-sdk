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
const udidPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const inputPattern = /^xcr Mic ([1-9]\d*)_UID$/;
const outputPattern = /^xcr Speaker ([1-9]\d*)_UID$/;

export class IsolatedLeaseRefusal extends Error {}

function redactLeaseOutput(output: string): string {
  return output.replace(/\b(xc[lhcpdj])_[A-Za-z0-9_-]{8,}/g, '$1_[redacted]');
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

function routes(value: unknown, field: string, now: number): Routes {
  const proof = object(value);
  if (proof.isolated !== true) {
    throw new IsolatedLeaseRefusal(`${field}.isolated must be true${reason(proof.reason)}`);
  }
  const { input, output, verifiedAt } = proof;
  if (typeof input !== 'string' || !input) throw new IsolatedLeaseRefusal(`${field}.input is missing`);
  if (typeof output !== 'string' || !output) throw new IsolatedLeaseRefusal(`${field}.output is missing`);
  const inputSlot = inputPattern.exec(input)?.[1];
  const outputSlot = outputPattern.exec(output)?.[1];
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
export async function checkerPhaseLog(scratch: string): Promise<string> {
  const directories = (await readdir(scratch, { withFileTypes: true }))
    .filter(entry => entry.isDirectory() && entry.name.startsWith('xcr-audio-check.'));
  const directory = directories.length === 1 ? join(scratch, directories[0]!.name) : undefined;
  const read = (name: string) => directory
    ? readFile(join(directory, name), 'utf8').catch(() => undefined) : Promise.resolve(undefined);
  const [tone, feed, record, probe] = await Promise.all(
    ['tone.txt', 'feed.txt', 'record.txt', 'probe.txt'].map(read));
  const observations = (probe ?? '').split('\n').filter(line => line.includes(' dev.xcr.simtone '));
  return [
    `Playback phase:\n${tone?.trim() || 'No output'}`,
    `Virtual microphone feed phase:\n${feed?.trim() || 'No output'}`,
    `Recording phase:\n${record?.trim() || (record === undefined ? 'Did not start' : 'No output before timeout')}`,
    `Checker process routes:\n${observations.join('\n') || 'No process samples'}`,
  ].join('\n');
}

function readProof(
  view: Record<string, unknown>, id: string, now: number, waitingForHeartbeat: boolean, attached: boolean,
): Proof | undefined {
  const lease = object(view.lease);
  if (lease.id !== id) throw new IsolatedLeaseRefusal('The lease response has a different lease identifier');
  const audio = object(lease.audio);
  if (audio.isolated === false && audio.reason !== undefined) routes(audio, 'lease.audio', now);
  if (audio.required !== true) throw new IsolatedLeaseRefusal('lease.audio.required must be true');
  if (waitingForHeartbeat && audio.isolated === false && audio.reason === undefined) return;
  const proof = routes(audio, 'lease.audio', now);
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
  const sim = routes(simulator.audio, 'simulator.audio', now);
  if (sim.input !== proof.input || sim.output !== proof.output) {
    throw new IsolatedLeaseRefusal('The lease and simulator audio UIDs differ');
  }
  return { ...proof, udid, leaseAudio: { isolated: true, virtualInputVerified: true, virtualOutputVerified: true } };
}

type LeaseCommand = (file: string, args: string[], options: {
  env: NodeJS.ProcessEnv; timeout: number; signal?: AbortSignal;
}) => Promise<{ stdout: string; stderr: string }>;

export interface LeaseConfiguration {
  cli: string;
  checker: string;
  project?: string;
  environment: NodeJS.ProcessEnv;
}

export function isolatedLeaseConfiguration(environment: NodeJS.ProcessEnv): LeaseConfiguration | undefined {
  const { SIMULATOR_LEASE_CLI: cli, SIMULATOR_LEASE_AUDIO_CHECKER: checker } = environment;
  if (!cli && !checker) return;
  if (!cli || !checker || !isAbsolute(checker)) {
    throw new IsolatedLeaseRefusal('Set SIMULATOR_LEASE_CLI and an absolute SIMULATOR_LEASE_AUDIO_CHECKER path');
  }
  return { cli, checker, project: environment.ISOLATED_LEASE_PROJECT?.trim() || undefined, environment };
}

export async function withIsolatedSimulatorLease<T>(
  { cli, checker, project, environment }: LeaseConfiguration,
  signal: AbortSignal,
  run: (proof: Proof, signal: AbortSignal) => Promise<T>,
  check: (checker: string, udid: string, signal: AbortSignal) => Promise<string>,
  report: (line: string) => void,
  { command = execute, now = Date.now, pause = (ms, signal) => delay(ms, undefined, { signal }), shutdown, arm, prepareRelease }: {
    command?: LeaseCommand; now?: () => number; pause?: (ms: number, signal: AbortSignal) => Promise<void>;
    shutdown?: (udid: string) => Promise<string>;
    arm?: (proof: Proof, signal: AbortSignal) => Promise<AbortSignal>;
    prepareRelease?: () => void;
  } = {},
): Promise<T> {
  let id = environment.XCR_LEASE_ID;
  const attached = Boolean(id);
  if (Boolean(id) !== Boolean(environment.XCR_LEASE_TOKEN)) {
    throw new IsolatedLeaseRefusal('An existing isolated simulator lease requires both its identifier and its token');
  }
  // Scope acquisition and cleanup to this run, including when acquisition fails after creating a lease.
  const env = id ? { ...environment, XCR_ALLOW_RELEASE: '1' }
    : { ...environment, XCR_LEASE_KEY: randomUUID() };
  async function invoke(args: string[], timeout: number, cancellation?: AbortSignal): Promise<string> {
    const acquiring = args[0] === 'up';
    try {
      const result = await command(cli, args, { env, timeout, signal: cancellation });
      if (acquiring) report(redactLeaseOutput([result.stderr.trim(), result.stdout.trim()].filter(Boolean).join('\n')));
      const releaseError = args[0] === 'down' && /^release: (.+)$/m.exec(result.stderr)?.[1];
      if (releaseError) throw new IsolatedLeaseRefusal(`Could not release isolated simulator lease: ${releaseError}`);
      return result.stdout;
    } catch (error) {
      if (error instanceof IsolatedLeaseRefusal) throw error;
      const failure = object(error);
      const stderr = typeof failure.stderr === 'string' ? redactLeaseOutput(failure.stderr.trim()) : '';
      const stdout = typeof failure.stdout === 'string' ? redactLeaseOutput(failure.stdout.trim()) : '';
      if (acquiring && (stderr || stdout)) report([stderr, stdout].filter(Boolean).join('\n'));
      cancellation?.throwIfAborted();
      const diagnostic = /^xcr: (.+)$/m.exec(stderr)?.[1] ?? stderr;
      const details = acquiring && failure.killed === true
        ? `acquisition command timed out${reason(diagnostic)}` : diagnostic || failure.code;
      throw new IsolatedLeaseRefusal(`Isolated simulator lease CLI failed (${args[0]})${reason(details)}`);
    }
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
      const acquired = json(await invoke(args, acquisitionTimeout, localSignal));
      if (typeof acquired.lease !== 'string' || !acquired.lease) {
        throw new IsolatedLeaseRefusal('Acquisition returned no isolated simulator lease identifier');
      }
      id = acquired.lease;
      if (typeof acquired.udid !== 'string' || !udidPattern.test(acquired.udid)) {
        throw new IsolatedLeaseRefusal('Acquisition returned no valid simulator UDID');
      }
      acquiredProof = { udid: acquired.udid, ...routes(acquired.audio, 'audio', now()) };
    }

    const leaseID = id;
    const heartbeat = AbortSignal.timeout(firstHeartbeatTimeout);
    const startupSignal = AbortSignal.any([localSignal, heartbeat]);
    let proof: Proof | undefined;
    try {
      while (!proof) {
        const view = json(await invoke(['lease'], 10_000, startupSignal));
        proof = readProof(view, leaseID, now(), true, attached);
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
      const updated = readProof(view, leaseID, now(), false, attached);
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
      try { await invoke(['down'], 30_000); }
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
