// Checks a built runtime package end to end: it launches an app that doesn't link the runtime with
// the package's runtime injected, then answers and ends a VoIP-pushed call with the package's
// `cksim`, as a developer without the SDK would.
//
// Usage: node tools/runtime-smoke.ts <runtime package> [--simulator <UUID>]
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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

interface PushEvent {
  event: string;
  t_ms: number;
  pushID?: string;
  api?: string;
  mustReport?: boolean;
  reason?: string;
  signal?: number;
  seconds?: number;
  qualifyingReport?: boolean;
}

/** Checks reporting enforcement in a disposable app process, never in the test runner. */
async function reportingEnforcement(packagePath: string, simulator: string, work: string): Promise<void> {
  const channel = join(run('xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data']),
    'Documents/.callkit-simulator');
  const cksim = (...args: string[]) => run(join(packagePath, 'cksim'),
    ['--simulator', simulator, '--bundle', bundle, ...args], { timeout: 120 });
  const payload = join(work, 'reporting-push.json');
  const cases = [
    { name: 'missing legacy report', metadata: false, required: false, report: 'skip', dies: true },
    { name: 'missing metadata report', metadata: true, required: true, report: 'skip', dies: true },
    { name: 'report at 3.15 seconds', metadata: true, required: true, delayMS: 3150, dies: false },
    { name: 'report due at 5 seconds', metadata: true, required: true, delayMS: 5000, dies: true },
    { name: 'existing UUID report', metadata: true, required: true, duplicate: true, dies: true },
    { name: 'optional push with a live call', metadata: true, required: false, report: 'skip', withCall: true, dies: false },
  ];
  for (const scenario of cases) {
    launchToleratingASlowSimulator(() => run(join(packagePath, 'cksim'),
      ['--simulator', simulator, '--bundle', bundle, 'launch'], {
        timeout: 120, environment: {
          ...process.env, SIMCTL_CHILD_CKSIM_SMOKE_METADATA: scenario.metadata ? '1' : '0',
        },
      }));
    cksim('status');
    const session = JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8')) as { runID: string; pid: number };
    const journal = join(channel, session.runID, 'events.jsonl');
    const entries = (): PushEvent[] => readFileSync(journal, 'utf8').split('\n').slice(0, -1)
      .map(line => JSON.parse(line) as PushEvent);
    const running = () => {
      try { process.kill(session.pid, 0); return true; } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ESRCH') return false;
        throw error;
      }
    };
    const callUUID = randomUUID();
    if (scenario.duplicate || scenario.withCall) {
      writeFileSync(payload, JSON.stringify({ callUUID }));
      cksim('push', '--payload-file', payload, '--must-report', 'true');
      await until('the first call', 10, () => {
        const calls = JSON.parse(cksim('status')).result.calls as Call[];
        return calls.some(call => call.uuid.toLowerCase() === callUUID) ? true : undefined;
      });
    }
    writeFileSync(payload, JSON.stringify({ callUUID, report: scenario.report, delayMS: scenario.delayMS }));
    const push = JSON.parse(cksim('push', '--payload-file', payload,
      '--must-report', String(scenario.required))).result.pushID as string;
    const received = await until('push delivery', 10, () =>
      entries().find(row => row.event === 'push.received' && row.pushID === push));
    assert.equal(received.api, scenario.metadata ? 'metadata' : 'legacy', scenario.name);
    assert.equal(received.mustReport, scenario.metadata ? scenario.required : true, scenario.name);
    if (scenario.dies) {
      const termination = await until(`${scenario.name} to terminate the process`, 9, () => {
        const row = entries().find(row => row.event === 'runtime.processTerminated' && row.pushID === push);
        return row && !running() ? row : undefined;
      });
      assert.equal(termination.reason, 'required-new-call-report-missing');
      assert.equal(termination.signal, 6); // SIGABRT, as in the iPhone 13 capture.
      const elapsed = termination.t_ms - received.t_ms;
      assert.ok(elapsed >= 4399 && elapsed <= 6400, `${scenario.name}: ${elapsed} ms`);
      assert.ok(!entries().some(row => row.event === 'push.reportSatisfied' && row.pushID === push));
    } else {
      await sleep(4700);
      assert.ok(running(), scenario.name);
      cksim('status'); // The same process must still serve controls after the reporting deadline.
      const rows = entries().filter(row => row.pushID === push);
      assert.ok(!rows.some(row => row.event === 'runtime.processTerminated'), scenario.name);
      assert.equal(rows.some(row => row.event === 'push.reportSatisfied'), scenario.required);
      if (!scenario.required) assert.ok(!rows.some(row => row.event === 'push.reportDeadline'));
    }
  }
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

/**
 * Launches the app with `launch`, once more if the first launch timed out reading the simulator's
 * environment. On a busy host, the first `simctl spawn` after the simulator boots can take longer
 * than `cksim`'s minute; `cksim` reads the environment before it changes anything.
 */
export function launchToleratingASlowSimulator(launch: () => string): string {
  try {
    return launch();
  } catch (error) {
    if (!(error instanceof Error) || !/Reading simulator environment key \S+ timed out/.test(error.message)) {
      throw error;
    }
    console.warn(`Launching again: ${error.message}`);
    return launch();
  }
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
    launchToleratingASlowSimulator(() => cksim('launch'));
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
    await reportingEnforcement(packagePath, simulator, work);
    return events;
  } finally {
    if (requestedSimulator) {
      try { run('xcrun', ['simctl', 'terminate', requestedSimulator, bundle], { timeout: 60 }); } catch { /* Already terminated. */ }
    }
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
