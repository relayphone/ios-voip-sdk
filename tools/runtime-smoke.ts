// Checks a built runtime package end to end: it launches an app that doesn't link the runtime with
// the package's runtime injected, then answers and ends a VoIP-pushed call with the package's
// `cksim`, as a developer without the SDK would.
//
// Usage: node tools/runtime-smoke.ts <runtime package> [--simulator <UUID>]
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isMain, main, option, repository, run } from './command.ts';
import { buildSimulatorApp } from './simulator-app.ts';

const bundle = 'dev.callkitsim.smoke';

interface Call {
  uuid: string;
  connected: boolean;
  ringing: boolean;
  ended: boolean;
}

/** Waits until the check returns a value, retrying a failed check until the deadline. */
async function until<T>(description: string, seconds: number, check: () => T | undefined): Promise<T> {
  const deadline = Date.now() + seconds * 1000;
  let failure: unknown;
  while (Date.now() < deadline) {
    try {
      const value = check();
      if (value !== undefined) return value;
    } catch (error) {
      failure = error;
    }
    await sleep(250);
  }
  const reason = failure instanceof Error ? `: ${failure.message}` : '';
  throw new Error(`Timed out waiting for ${description}${reason}`);
}

export async function smoke(packagePath: string, requestedSimulator?: string): Promise<string[]> {
  const work = mkdtempSync(join(tmpdir(), 'runtime-smoke-'));
  let created: string | undefined;
  try {
    const app = join(work, 'Smoke.app');
    buildSimulatorApp({
      bundle: app, executable: 'Smoke', identifier: bundle, displayName: 'Smoke',
      minimumOS: '18.0', sources: [join(repository, 'tools/smoke/SmokeApp.swift')],
    });
    let simulator = requestedSimulator;
    if (!simulator) {
      simulator = run('xcrun', [
        'simctl', 'create', `runtime-smoke-${process.pid}`,
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
      ], { timeout: 120 });
      created = simulator;
    }
    // Boots the simulator unless it's booted already, and waits until it has finished booting.
    run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], { timeout: 300 });
    run('xcrun', ['simctl', 'install', simulator, app], { timeout: 300 });

    const cksim = (...args: string[]) =>
      run(join(packagePath, 'cksim'), ['--simulator', simulator, '--bundle', bundle, ...args], { timeout: 120 });
    const calls = (): Call[] => JSON.parse(cksim('status')).result.calls as Call[];
    cksim('launch');
    await until('the runtime to start in the app', 120, () => (calls() ? true : undefined));
    const payload = join(work, 'push.json');
    writeFileSync(payload, JSON.stringify({ operation: 'incoming' }));
    cksim('push', '--payload-file', payload, '--must-report', 'true');
    const ringing = await until('the pushed call to ring', 30, () => calls().find(call => call.ringing));
    cksim('answer', ringing.uuid);
    await until('the call to connect', 30, () =>
      calls().find(call => call.uuid === ringing.uuid && call.connected));
    cksim('end', ringing.uuid);
    await until('the call to end', 30, () => (calls().length === 0 ? true : undefined));

    const events = cksim('watch', '--json', '--duration', '1')
      .split('\n').filter(line => line.trim()).map(line => JSON.parse(line).event as string);
    const expected = ['runtime.installed', 'push.received', 'report.incoming', 'action.settled', 'audio.activated'];
    const missing = expected.filter(name => !events.includes(name));
    if (missing.length > 0) throw new Error(`The journal is missing ${missing.join(', ')}`);
    return events;
  } finally {
    if (created) {
      try { run('xcrun', ['simctl', 'shutdown', created], { timeout: 120 }); } catch { /* Already shut down. */ }
      run('xcrun', ['simctl', 'delete', created], { timeout: 120 });
    }
    rmSync(work, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) {
  await main(async () => {
    const packagePath = process.argv[2];
    if (!packagePath || packagePath.startsWith('--')) {
      throw new Error('Usage: node tools/runtime-smoke.ts <runtime package> [--simulator <UUID>]');
    }
    const events = await smoke(resolve(packagePath), option(process.argv, 'simulator'));
    console.log(`The packaged runtime answered and ended a pushed call; its journal has ${events.length} events.`);
  });
}
