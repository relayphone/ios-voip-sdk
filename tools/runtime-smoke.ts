import { simulatorRuntime } from './simulator-runtime.ts';
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
import { isList, isRecord, isString } from './json-fields.ts';
import { smokeCommand, SmokeCommandFailure } from './runtime-smoke-diagnostics.ts';
import { buildSimulatorApp } from './simulator-app.ts';

const bundle = 'dev.callkitsim.smoke';

function parseRecord(json: string) {
  const value: unknown = JSON.parse(json);
  assert.ok(isRecord(value), 'Expected a JSON record');
  return value;
}

function commandResult(json: string) {
  const response = parseRecord(json);
  assert.ok('result' in response && isRecord(response.result), 'Expected a command result');
  return response.result;
}

function readSession(channel: string) {
  const session = parseRecord(readFileSync(join(channel, 'session.json'), 'utf8'));
  assert.ok('runID' in session && isString(session.runID) && session.runID, 'Missing runtime invocation');
  assert.ok('pid' in session && Number.isSafeInteger(session.pid) && Number(session.pid) > 0, 'Invalid runtime PID');
  return { runID: session.runID, pid: Number(session.pid) };
}

function readPushID(json: string) {
  const result = commandResult(json);
  assert.ok('pushID' in result && isString(result.pushID) && result.pushID, 'Missing push ID');
  return result.pushID;
}

interface Call {
  uuid: string;
  connected: boolean;
  ringing: boolean;
}

function isCall(value: unknown): value is Call {
  return isRecord(value) && 'uuid' in value && isString(value.uuid)
    && 'connected' in value && (value.connected === true || value.connected === false)
    && 'ringing' in value && (value.ringing === true || value.ringing === false);
}

function readCalls(json: string) {
  const result = commandResult(json);
  assert.ok('calls' in result && isList(result.calls) && result.calls.every(isCall), 'Invalid call status');
  return result.calls;
}

function readEvent(line: string) {
  const row = parseRecord(line);
  assert.ok('event' in row && isString(row.event), 'Missing runtime event name');
  return {
    event: row.event,
    runID: 'runID' in row ? row.runID : undefined,
    pid: 'pid' in row ? row.pid : undefined,
    sequence: 'sequence' in row ? row.sequence : undefined,
    uptimeNanoseconds: 'uptimeNanoseconds' in row ? row.uptimeNanoseconds : undefined,
    timeMS: 't_ms' in row ? row.t_ms : undefined,
    boundarySource: 'boundarySource' in row ? row.boundarySource : undefined,
    pushID: 'pushID' in row ? row.pushID : undefined,
    requestID: 'requestID' in row ? row.requestID : undefined,
    api: 'api' in row ? row.api : undefined,
    mustReport: 'mustReport' in row ? row.mustReport : undefined,
    reason: 'reason' in row ? row.reason : undefined,
    signal: 'signal' in row ? row.signal : undefined,
    cause: 'cause' in row ? row.cause : undefined,
  };
}

function readEvents(json: string) {
  return json.split('\n').filter(line => line.trim()).map(readEvent);
}

function eventTime(row: ReturnType<typeof readEvent>) {
  assert.ok(Number.isFinite(row.timeMS), `Missing timing for ${row.event}`);
  return Number(row.timeMS);
}

function eventPushID(row: ReturnType<typeof readEvent>) {
  assert.ok(isString(row.pushID) && row.pushID, `Missing push ID for ${row.event}`);
  return row.pushID;
}

function processIsGone(cause: unknown) {
  return cause instanceof Error && 'code' in cause && cause.code === 'ESRCH';
}

/** Checks real runtime boundaries without treating hook installation as application readiness. */
export function assertRuntimeBoundaries(journal: string, identity: { runID: string; pid: number }) {
  const rows = readEvents(journal);
  const entered = rows.filter(row => row.event === 'process.entered');
  const ready = rows.filter(row => row.event === 'runtime.ready');
  assert.equal(entered.length, 1, 'one instrumented entry per invocation');
  assert.equal(ready.length, 1, 'one completed hook installation per invocation');
  const [entry] = entered;
  const [hooks] = ready;
  assert.ok(entry && hooks);
  for (const row of [entry, hooks]) {
    assert.equal(row.runID, identity.runID);
    assert.equal(row.pid, identity.pid);
    assert.ok(Number.isInteger(row.uptimeNanoseconds) && Number(row.uptimeNanoseconds) > 0);
    assert.ok(Number.isSafeInteger(row.sequence));
  }
  assert.equal(entry.boundarySource, 'runtime-preparation');
  assert.equal(hooks.boundarySource, 'hooks-installed');
  assert.equal(entry.timeMS, 0);
  assert.ok(Number(hooks.uptimeNanoseconds) >= Number(entry.uptimeNanoseconds));
  assert.ok(Number(hooks.sequence) > Number(entry.sequence));
}

/** Checks reporting enforcement in a disposable app process, never in the test runner. */
async function reportingEnforcement(packagePath: string, simulator: string, work: string) {
  const channel = join(smokeCommand('reporting:container', 'xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data']),
    'Documents/.callkit-simulator');
  let phase = 'reporting:setup';
  const cksim = (...args: string[]) => smokeCommand(`${phase}:${args[0]}`, join(packagePath, 'cksim'),
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
    const priorRun = readSession(channel).runID;
    phase = `reporting:${scenario.name}`;
    launchToleratingASlowSimulator(() => smokeCommand(`${phase}:launch`, join(packagePath, 'cksim'),
      ['--simulator', simulator, '--bundle', bundle, 'launch'], {
        timeout: 120, environment: {
          ...process.env, SIMCTL_CHILD_CKSIM_SMOKE_METADATA: scenario.metadata ? '1' : '0',
        },
      }));
    await until(`the new runtime for ${scenario.name}`, 120, () => {
      const published = readSession(channel);
      assert.notEqual(published.runID, priorRun);
      cksim('status');
      assert.equal(readSession(channel).runID, published.runID);
      return true;
    });
    const session = readSession(channel);
    const journal = join(channel, session.runID, 'events.jsonl');
    const entries = () => readFileSync(journal, 'utf8').split('\n').slice(0, -1).map(readEvent);
    const running = () => {
      try { process.kill(session.pid, 0); return true; } catch (error) {
        if (processIsGone(error)) return false;
        throw error;
      }
    };
    const callUUID = randomUUID();
    if (scenario.duplicate || scenario.withCall) {
      writeFileSync(payload, JSON.stringify({ callUUID }));
      cksim('push', '--payload-file', payload, '--must-report', 'true');
      await until('the first call', 10, () => {
        const calls = readCalls(cksim('status'));
        return calls.some(call => call.uuid.toLowerCase() === callUUID) ? true : undefined;
      });
    }
    writeFileSync(payload, JSON.stringify({ callUUID: scenario.freshUUIDs ? undefined : callUUID,
      report: scenario.report, delayMS: scenario.delayMS }));
    const requestID = readPushID(cksim('push', '--payload-file', payload,
      '--must-report', String(scenario.required), ...(scenario.faults ?? [])));
    const scheduled = entries().filter(row => row.event === 'push.scheduled' && row.requestID === requestID);
    const ids = scheduled.map(eventPushID);
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
      assert.ok(!entries().some(row => isString(row.pushID) && ids.includes(row.pushID) &&
        ['push.received', 'push.reportDeadline', 'runtime.processTerminated'].includes(row.event)));
      continue;
    }
    // Check survival or expiry past the final copy's own reporting window.
    const push = ids.at(-1);
    assert.ok(push);
    const received = await until('push delivery', 10, () =>
      entries().find(row => row.event === 'push.received' && row.pushID === push));
    if (scenario.deliveryDelay) {
      const [first] = scheduled;
      assert.ok(first);
      assert.ok(eventTime(received) - eventTime(first) >= scenario.deliveryDelay - 1);
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
      const elapsed = eventTime(termination) - eventTime(received);
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
async function until<T>(description: string, seconds: number, check: () => T | undefined) {
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
export function launchToleratingASlowSimulator(launch: () => string) {
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

export async function smoke(packagePath: string, requestedSimulator?: string) {
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
      simulator = smokeCommand('setup:create', 'xcrun', [
        'simctl', 'create', `runtime-smoke-${process.pid}`,
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', simulatorRuntime,
      ], { timeout: 120 });
      created = simulator;
    }
    // Boots the simulator unless it's booted already, and waits until it has finished booting.
    smokeCommand('setup:boot', 'xcrun', ['simctl', 'bootstatus', simulator, '-b'], { timeout: 300 });
    smokeCommand('setup:install', 'xcrun', ['simctl', 'install', simulator, app], { timeout: 300 });

    let phase = 'call:launch';
    const cksim = (...args: string[]) =>
      smokeCommand(`${phase}:${args[0]}`, join(packagePath, 'cksim'), ['--simulator', simulator, '--bundle', bundle, ...args], { timeout: 120 });
    const calls = () => readCalls(cksim('status'));
    launchToleratingASlowSimulator(() => cksim('launch'));
    await until('the runtime to start in the app', 120, () => (calls() ? true : undefined));
    const payload = join(work, 'push.json');
    writeFileSync(payload, JSON.stringify({ operation: 'incoming' }));
    phase = 'call:incoming';
    cksim('push', '--payload-file', payload, '--must-report', 'true');
    const ringing = await until('the pushed call to ring', 30, () => calls().find(call => call.ringing));
    phase = 'call:answer';
    cksim('answer', ringing.uuid);
    await until('the call to connect', 30, () =>
      calls().find(call => call.uuid === ringing.uuid && call.connected));
    phase = 'call:end';
    cksim('end', ringing.uuid);
    await until('the call to end', 30, () => (calls().length === 0 ? true : undefined));

    phase = 'call:journal';
    const events = readEvents(cksim('watch', '--json', '--duration', '1')).map(row => row.event);
    const expected = ['runtime.installed', 'push.received', 'report.incoming', 'action.settled', 'audio.activated'];
    const missing = expected.filter(name => !events.includes(name));
    if (missing.length > 0) throw new Error(`The journal is missing ${missing.join(', ')}`);
    const channel = join(smokeCommand('process:container', 'xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data']),
      'Documents/.callkit-simulator');
    const session = () => readSession(channel);
    phase = 'process:suspend';
    const beforeSuspension = session();
    const resumed = parseRecord(cksim('process', 'suspend', '--run-id', beforeSuspension.runID, '--resume-after-ms', '250'));
    assert.ok('outcome' in resumed && 'pid' in resumed && 'identity' in resumed
      && isRecord(resumed.identity) && 'runID' in resumed.identity && 'requestID' in resumed);
    assert.equal(resumed.outcome, 'resumed');
    assert.equal(resumed.pid, beforeSuspension.pid);
    assert.equal(resumed.identity.runID, beforeSuspension.runID);
    const requestID = resumed.requestID;
    assert.ok(isString(requestID) && requestID);
    const suspensionRows = readEvents(cksim('events', '--run-id', beforeSuspension.runID))
      .filter(row => row.requestID === requestID);
    assert.deepEqual(suspensionRows.map(row => row.event),
      ['process.suspendRequested', 'process.suspended', 'process.resumed']);
    assert.ok(suspensionRows.every(row => row.pid === beforeSuspension.pid));
    assert.equal(session().pid, beforeSuspension.pid);
    for (const cause of ['abrupt', 'user-requested']) {
      phase = `process:${cause}:kill`;
      const before = session();
      assertRuntimeBoundaries(readFileSync(join(channel, before.runID, 'events.jsonl'), 'utf8'), before);
      const requestID = readPushID(cksim('push', '--payload-file', payload, '--must-report', 'true',
        '--delay-ms', '120000', '--duplicate', '1'));
      const scheduled = readEvents(cksim('events', '--run-id', before.runID))
        .filter(row => row.event === 'push.scheduled' && row.requestID === requestID)
        .map(eventPushID);
      assert.equal(scheduled.length, 2);
      const receiptPath = join(work, `kill-${cause}.json`);
      const receipt = parseRecord(cksim('process', 'kill', '--run-id', before.runID,
        '--cause', cause, '--command-receipt', receiptPath));
      assert.ok('exited' in receipt && 'pid' in receipt && 'identity' in receipt
        && isRecord(receipt.identity) && 'runID' in receipt.identity
        && 'cause' in receipt && 'cancelledDeliveries' in receipt);
      assert.equal(receipt.exited, true);
      assert.equal(receipt.pid, before.pid);
      assert.equal(receipt.identity.runID, before.runID);
      assert.equal(receipt.cause, cause);
      assert.deepEqual(receipt.cancelledDeliveries, scheduled);
      assert.deepEqual(JSON.parse(readFileSync(receiptPath, 'utf8')), receipt);
      assert.throws(() => process.kill(before.pid, 0), processIsGone);
      const rows = readEvents(cksim('events', '--run-id', before.runID));
      assert.deepEqual(rows.filter(row => ['process.killRequested', 'process.exited'].includes(row.event)).map(row => row.event),
        ['process.killRequested', 'process.exited']);
      const cancelled = rows.filter(row => row.event === 'push.cancelled');
      assert.deepEqual(cancelled.map(row => row.pushID), scheduled);
      assert.ok(cancelled.every(row => row.requestID === requestID && row.pid === before.pid && row.cause === cause));
      assert.ok(!rows.some(row => row.event === 'push.received' && isString(row.pushID) && scheduled.includes(row.pushID)));
      phase = `process:${cause}:relaunch`;
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
      const dropped = readEvents(cksim('events', '--run-id', droppedRunID));
      assert.equal(dropped.length, 2);
      assert.ok(dropped.every(row => row.event === 'push.dropped' && row.pid === undefined));
      assert.equal(new Set(dropped.map(eventPushID)).size, 2);
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
          const status = commandResult(cksim('status'));
          assert.equal(session().runID, runID);
          assert.notEqual(session().pid, before.pid);
          assert.ok('processLifecycle' in status && isRecord(status.processLifecycle));
          const timings = status.processLifecycle;
          assert.ok('registry' in timings && isRecord(timings.registry)
            && 'handler' in timings && isRecord(timings.handler)
            && 'generation' in timings.handler && timings.handler.generation === 1);
          const durations = new Map<string, unknown>(Object.entries(timings));
          for (const key of ['launchToRegistryMS', 'entryToRegistryMS', 'launchToHandlerMS', 'entryToHandlerMS']) {
            const duration = durations.get(key);
            assert.ok(Number.isFinite(duration) && Number(duration) >= 0, key);
          }
          return true;
        });
        const receipt = parseRecord(readFileSync(receiptPath, 'utf8'));
        assert.ok('envelope' in receipt && isRecord(receipt.envelope) && 'deliveryIDs' in receipt.envelope);
        const { deliveryIDs } = receipt.envelope;
        assert.ok(isList(deliveryIDs) && deliveryIDs.every(isString));
        const deliveredCount = spacing === 100 ? 2 : 1;
        await until('independent duplicate delegate entries and reports', 30, () => {
          const rows = readEvents(cksim('events', '--run-id', runID));
          for (const id of deliveryIDs.slice(0, deliveredCount)) {
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
        const rows = readEvents(cksim('events', '--run-id', runID));
        assert.deepEqual(rows.filter(row => row.event === 'push.cancelled').map(row => row.pushID),
          deliveryIDs.slice(deliveredCount));
        assert.ok(rows.some(row => row.event === 'process.exited' && row.cause === 'unknown'));
      } finally {
        if (observer.exitCode === null) observer.kill('SIGTERM');
      }
    }
    await reportingEnforcement(packagePath, simulator, work);
    return events;
  } finally {
    if (requestedSimulator) {
      try { smokeCommand('cleanup:terminate', 'xcrun', ['simctl', 'terminate', requestedSimulator, bundle], { timeout: 60 }); }
      catch (error) { if (error instanceof SmokeCommandFailure) console.error(error.message); /* May already be terminated. */ }
    }
    if (created) {
      try { smokeCommand('cleanup:shutdown', 'xcrun', ['simctl', 'shutdown', created], { timeout: 120 }); }
      catch (error) { if (error instanceof SmokeCommandFailure) console.error(error.message); /* May already be shut down. */ }
      smokeCommand('cleanup:delete', 'xcrun', ['simctl', 'delete', created], { timeout: 120 });
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
