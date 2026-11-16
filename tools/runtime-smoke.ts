// Checks a built runtime package end to end: it launches an app that doesn't link the runtime with
// the package's runtime injected, then answers and ends a VoIP-pushed call with the package's
// `cksim`, as a developer without the SDK would.
//
// Usage: node tools/runtime-smoke.ts <runtime package> [--simulator <UUID>]
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isMain, main, option, repository, run } from './command.ts';
import { buildSimulatorApp } from './simulator-app.ts';

const bundle = 'dev.callkitsim.smoke';

/** Checks real runtime boundaries without treating hook installation as application readiness. */
export function assertRuntimeBoundaries(journal: string, identity: { runID: string; pid: number }): void {
  const rows = journal.trim().split('\n').map(line => JSON.parse(line) as {
    event: string; runID: string; pid: number; sequence: number;
    uptimeNanoseconds: number; t_ms: number; boundarySource?: string;
  });
  const entered = rows.filter(row => row.event === 'process.entered');
  const ready = rows.filter(row => row.event === 'runtime.ready');
  assert.equal(entered.length, 1, 'one instrumented entry per invocation');
  assert.equal(ready.length, 1, 'one completed hook installation per invocation');
  const entry = entered[0]!;
  const hooks = ready[0]!;
  for (const row of [entry, hooks]) {
    assert.equal(row.runID, identity.runID);
    assert.equal(row.pid, identity.pid);
    assert.ok(row.uptimeNanoseconds > 0);
  }
  assert.equal(entry.boundarySource, 'runtime-preparation');
  assert.equal(hooks.boundarySource, 'hooks-installed');
  assert.equal(entry.t_ms, 0);
  assert.ok(hooks.uptimeNanoseconds >= entry.uptimeNanoseconds);
  assert.ok(hooks.sequence > entry.sequence);
}

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
  requestID?: string;
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
  const cases: {
    name: string; metadata: boolean; required: boolean; dies: boolean;
    report?: string; delayMS?: number; duplicate?: boolean; withCall?: boolean;
    faults?: string[]; copies?: number; dropped?: boolean; freshUUIDs?: boolean; deliveryDelay?: number;
  }[] = [
    { name: 'missing legacy report', metadata: false, required: false, report: 'skip', dies: true },
    { name: 'missing metadata report', metadata: true, required: true, report: 'skip', dies: true },
    { name: 'report at 3.15 seconds', metadata: true, required: true, delayMS: 3150, dies: false },
    { name: 'report due at 5 seconds', metadata: true, required: true, delayMS: 5000, dies: true },
    { name: 'existing UUID report', metadata: true, required: true, duplicate: true, dies: true },
    { name: 'optional push with a live call', metadata: true, required: false, report: 'skip', withCall: true, dies: false },
    { name: 'delayed required delivery', metadata: true, required: true, dies: false,
      deliveryDelay: 5000, faults: ['--delay-ms', '5000'] },
    { name: 'dropped required copies', metadata: true, required: true, report: 'skip', dies: false,
      dropped: true, copies: 3, faults: ['--drop', '--duplicate', '2', '--spacing-ms', '100'] },
    { name: 'duplicate fresh reports', metadata: true, required: true, dies: false, freshUUIDs: true,
      copies: 3, faults: ['--duplicate', '2', '--spacing-ms', '700'] },
    { name: 'duplicate existing UUID fails', metadata: true, required: true, dies: true,
      copies: 2, faults: ['--duplicate', '1', '--spacing-ms', '700'] },
    { name: 'optional duplicate deliveries', metadata: true, required: false, report: 'skip', dies: false,
      copies: 3, faults: ['--duplicate', '2', '--spacing-ms', '700'] },
  ];
  for (const scenario of cases) {
    const priorRun = JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8')).runID as string;
    launchToleratingASlowSimulator(() => run(join(packagePath, 'cksim'),
      ['--simulator', simulator, '--bundle', bundle, 'launch'], {
        timeout: 120, environment: {
          ...process.env, SIMCTL_CHILD_CKSIM_SMOKE_METADATA: scenario.metadata ? '1' : '0',
        },
      }));
    await until(`the new runtime for ${scenario.name}`, 120, () => {
      const published = JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8'));
      assert.notEqual(published.runID, priorRun);
      cksim('status');
      assert.equal(JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8')).runID, published.runID);
      return true;
    });
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
    writeFileSync(payload, JSON.stringify({ callUUID: scenario.freshUUIDs ? undefined : callUUID,
      report: scenario.report, delayMS: scenario.delayMS }));
    const requestID = JSON.parse(cksim('push', '--payload-file', payload,
      '--must-report', String(scenario.required), ...(scenario.faults ?? []))).result.pushID as string;
    const scheduled = entries().filter(row => row.event === 'push.scheduled' && row.requestID === requestID);
    const ids = scheduled.map(row => row.pushID!);
    assert.equal(ids.length, scenario.copies ?? 1, scenario.name);
    assert.equal(new Set(ids).size, ids.length, scenario.name);
    assert.equal(ids[0], requestID, scenario.name);
    if (scenario.dropped) {
      await until('all copies to be dropped', 10, () =>
        entries().filter(row => row.event === 'push.dropped' && row.requestID === requestID).length === ids.length
          ? true : undefined);
      assert.deepEqual(entries().filter(row => row.event === 'push.dropped' && row.requestID === requestID)
        .map(row => row.pushID), ids, scenario.name);
      await sleep(4700);
      assert.ok(running(), scenario.name);
      cksim('status');
      assert.ok(!entries().some(row => ids.includes(row.pushID ?? '') &&
        ['push.received', 'push.reportDeadline', 'runtime.processTerminated'].includes(row.event)));
      continue;
    }
    // Check survival or expiry past the final copy's own reporting window.
    const push = ids.at(-1)!;
    const received = await until('push delivery', 10, () =>
      entries().find(row => row.event === 'push.received' && row.pushID === push));
    if (scenario.deliveryDelay) {
      assert.ok(received.t_ms - scheduled[0]!.t_ms >= scenario.deliveryDelay - 1);
    }
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
      for (const id of ids) {
        const rows = entries().filter(row => row.pushID === id);
        assert.equal(rows.filter(row => row.event === 'push.received').length, 1, scenario.name);
        assert.ok(!rows.some(row => row.event === 'runtime.processTerminated'), scenario.name);
        assert.equal(rows.some(row => row.event === 'push.reportSatisfied'), scenario.required);
        if (!scenario.required) assert.ok(!rows.some(row => row.event === 'push.reportDeadline'));
      }
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
    const channel = join(run('xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data']),
      'Documents/.callkit-simulator');
    const session = (): { runID: string; pid: number } =>
      JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8'));
    for (const cause of ['abrupt', 'user-requested']) {
      const before = session();
      assertRuntimeBoundaries(readFileSync(join(channel, before.runID, 'events.jsonl'), 'utf8'), before);
      const requestID = JSON.parse(cksim('push', '--payload-file', payload, '--must-report', 'true',
        '--delay-ms', '120000', '--duplicate', '1')).result.pushID as string;
      const scheduled = cksim('events', '--run-id', before.runID).trim().split('\n')
        .map(line => JSON.parse(line) as PushEvent)
        .filter(row => row.event === 'push.scheduled' && row.requestID === requestID)
        .map(row => row.pushID);
      assert.equal(scheduled.length, 2);
      const receiptPath = join(work, `kill-${cause}.json`);
      const receipt = JSON.parse(cksim('process', 'kill', '--run-id', before.runID,
        '--cause', cause, '--command-receipt', receiptPath));
      assert.equal(receipt.exited, true);
      assert.equal(receipt.pid, before.pid);
      assert.equal(receipt.identity.runID, before.runID);
      assert.equal(receipt.cause, cause);
      assert.deepEqual(receipt.cancelledDeliveries, scheduled);
      assert.deepEqual(JSON.parse(readFileSync(receiptPath, 'utf8')), receipt);
      assert.throws(() => process.kill(before.pid, 0),
        (error: unknown) => (error as NodeJS.ErrnoException).code === 'ESRCH');
      const rows = cksim('events', '--run-id', before.runID).trim().split('\n')
        .map(line => JSON.parse(line) as { event: string; pid?: number; cause?: string;
          requestID?: string; pushID?: string });
      assert.deepEqual(rows.filter(row => ['process.killRequested', 'process.exited'].includes(row.event)).map(row => row.event),
        ['process.killRequested', 'process.exited']);
      const cancelled = rows.filter(row => row.event === 'push.cancelled');
      assert.deepEqual(cancelled.map(row => row.pushID), scheduled);
      assert.ok(cancelled.every(row => row.requestID === requestID && row.pid === before.pid && row.cause === cause));
      assert.ok(!rows.some(row => row.event === 'push.received' && scheduled.includes(row.pushID)));
      launchToleratingASlowSimulator(() => cksim('launch'));
      await until('a new runtime process after verified kill', 120, () => {
        cksim('status');
        const after = session();
        assert.notEqual(after.pid, before.pid);
        assert.notEqual(after.runID, before.runID);
        return true;
      });
    }
    run('xcrun', ['simctl', 'terminate', simulator, bundle]);
    for (const spacing of [100, 120000]) {
      const before = session();
const droppedRunID = `dropped-${randomUUID()}`;
cksim('push', '--launch', '--run-id', droppedRunID, '--payload-file', payload, '--must-report', 'true',
  '--launch-receipt', join(work, `${droppedRunID}.json`), '--drop', '--duplicate', '1');
const dropped = cksim('events', '--run-id', droppedRunID).trim().split('\n').map(line => JSON.parse(line));
assert.equal(dropped.length, 2);
assert.ok(dropped.every(row => row.event === 'push.dropped' && row.pid === undefined));
assert.equal(new Set(dropped.map(row => row.pushID)).size, 2);
assert.equal(session().runID, before.runID);
const runID = `cold-${randomUUID()}`;
      const receiptPath = join(work, `${runID}.json`);
      const observer = spawn(join(packagePath, 'cksim'), ['--simulator', simulator, '--bundle', bundle,
        'push', '--launch', '--run-id', runID, '--payload-file', payload, '--must-report', 'true',
        '--launch-receipt', receiptPath, '--duplicate', '1', '--spacing-ms', String(spacing)], {
        env: { ...process.env, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES: join(packagePath, 'CKSimRuntime.dylib'),
          SIMCTL_CHILD_CKSIM_ENABLED: '1', SIMCTL_CHILD_CKSIM_PROFILE: 'ios-27.0' },
        stdio: ['ignore', 'ignore', 'pipe'],
      });
      let diagnostic = '';
      observer.stderr.on('data', chunk => { diagnostic += String(chunk); });
      const exited = new Promise<number | null>((resolveExit, reject) => {
        observer.once('error', reject); observer.once('exit', code => resolveExit(code));
      });
      try {
        await until('the cold process and both readiness acknowledgements', 120, () => {
          const status = JSON.parse(cksim('status')).result;
          assert.equal(session().runID, runID);
          assert.notEqual(session().pid, before.pid);
          const timings = status.processLifecycle;
          assert.ok(timings.registry && timings.handler?.generation === 1);
          for (const key of ['launchToRegistryMS', 'entryToRegistryMS', 'launchToHandlerMS', 'entryToHandlerMS']) {
            assert.ok(Number.isFinite(timings[key]) && timings[key] >= 0, key);
          }
          return true;
        });
        const plan = JSON.parse(readFileSync(receiptPath, 'utf8')).envelope;
        const deliveredCount = spacing === 100 ? 2 : 1;
        await until('independent duplicate delegate entries and reports', 30, () => {
          const rows = cksim('events', '--run-id', runID).trim().split('\n').map(line => JSON.parse(line));
          for (const id of plan.deliveryIDs.slice(0, deliveredCount)) {
            assert.ok(rows.some(row => row.event === 'push.received' && row.pushID === id));
            assert.ok(rows.some(row => row.event === 'report.incoming' && row.pushID === id));
          }
          return true;
        });
        // An external exit exercises automatic observation, independently of process kill.
        run('xcrun', ['simctl', 'terminate', simulator, bundle]);
        const timeout = new AbortController();
        try {
          assert.equal(await Promise.race([exited, sleep(30000, undefined, { signal: timeout.signal })
            .then(() => { throw new Error('Cold observer exit timed out'); })]), 0, diagnostic);
        } finally { timeout.abort(); }
        const rows = cksim('events', '--run-id', runID).trim().split('\n').map(line => JSON.parse(line));
        assert.deepEqual(rows.filter(row => row.event === 'push.cancelled').map(row => row.pushID),
          plan.deliveryIDs.slice(deliveredCount));
        assert.ok(rows.some(row => row.event === 'process.exited' && row.cause === 'unknown'));
      } finally {
        if (observer.exitCode === null) observer.kill('SIGTERM');
      }
    }
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
