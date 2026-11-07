// Runs the Inspector GUI on a display simulator, keeping the injected target foregrounded.
import { spawn, type ChildProcess } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isMain, main, repository, run } from './command.ts';
import { displayDevice } from './inspector-devices.ts';
import { simulatorDiagnostics } from './inspector-resources.ts';
import { launchToleratingASlowSimulator } from './runtime-smoke.ts';
import { assertInspectorJournal } from './inspector-journal.ts';
import { buildSimulatorApp } from './simulator-app.ts';
import { runnerHungBeforeConnecting } from './simulator-test-result.ts';

const bundle = 'dev.callkitsim.smoke';
class InfrastructureFailure extends Error {
  readonly step: string;
  constructor(step: string, cause: unknown) {
    super(`infra:${step}`, { cause });
    this.step = step;
  }
}
function infrastructure<T>(step: string, body: () => T): T {
  try { return body(); } catch (error) { throw new InfrastructureFailure(step, error); }
}
async function connected(bridge: ChildProcess, log: string): Promise<void> {
  const deadline = Date.now() + 240_000;
  while (Date.now() < deadline) {
    if (!bridge.pid || bridge.exitCode !== null || bridge.signalCode !== null) throw new InfrastructureFailure('bridge-connect', 'Bridge exited');
    if (readFileSync(log, 'utf8').includes('Ctrl-C to disconnect.')) return;
    await sleep(500);
  }
  throw new InfrastructureFailure('bridge-connect', 'Timed out');
}
function summary(message: string): void {
  console.log(message);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${message}\n`);
}

async function stopBridge(bridge: ChildProcess | undefined): Promise<void> {
  if (!bridge?.pid || bridge.exitCode !== null || bridge.signalCode !== null) return;
  const exited = new Promise<void>(resolve => bridge.once('exit', () => resolve()));
  bridge.kill('SIGINT');
  const timer = setTimeout(() => bridge.kill('SIGKILL'), 10_000);
  try { await exited; } finally { clearTimeout(timer); }
}

/** Deletes owned devices and restarts the service before creating a fresh pair. */
async function recover(names: readonly string[], markers: string): Promise<void> {
  for (const name of names) {
    try { run('xcrun', ['simctl', 'shutdown', name], { timeout: 30 }); } catch { /* May be stopped. */ }
    try { run('xcrun', ['simctl', 'delete', name], { timeout: 120 }); }
    catch (error) { console.warn(String(error)); }
  }
  try { run('xcrun', ['simctl', 'shutdown', 'all'], { timeout: 120 }); }
  catch (error) { console.warn(String(error)); }
  try { run('killall', ['-9', 'com.apple.CoreSimulator.CoreSimulatorService'], { timeout: 30 }); }
  catch (error) { console.warn(String(error)); }
  const deadline = Date.now() + 120_000;
  while (true) {
    try {
      const state = JSON.parse(run('xcrun', ['simctl', 'list', 'devices', '--json'], { timeout: 15 })) as {
        devices: Record<string, { name: string; udid: string }[]>;
      };
      for (const device of Object.values(state.devices).flat().filter(d => names.includes(d.name))) {
        run('xcrun', ['simctl', 'delete', device.udid], { timeout: 30 });
      }
      for (const name of names) rmSync(join(markers, name), { force: true });
      return;
    } catch (error) {
      if (Date.now() >= deadline) throw new InfrastructureFailure('service-restart', error);
      await sleep(1000);
    }
  }
}

/** Runs at most two attempts; only infrastructure errors allow the second pair of simulators. */
export async function journey(work: string): Promise<void> {
  const runtime = join(work, 'runtime');
  const inspector = join(work, 'inspector/CKSimInspector.app');
  const app = join(work, 'Smoke.app');
  try { buildSimulatorApp({
    bundle: app, executable: 'Smoke', identifier: bundle, displayName: 'Smoke', minimumOS: '18.0',
    sources: [join(repository, 'tools/smoke/SmokeApp.swift')],
  }); } catch (error) { summary('product:smoke-build failed'); throw error; }
  const results = join(work, 'results');
  const markers = join(work, 'simulators');
  mkdirSync(results, { recursive: true });
  mkdirSync(markers, { recursive: true });
  writeFileSync(join(work, 'push.json'), JSON.stringify({ operation: 'incoming' }));
  const type = infrastructure('device-selection', displayDevice);
  summary(`Simulator device for target and display: ${type.name} (${type.identifier})`);
  for (let attempt = 0; attempt < 2; attempt++) {
    const devices: string[] = [];
    const names: string[] = [];
    let bridge: ChildProcess | undefined;
    const prefix = join(results, `attempt-${attempt + 1}`);
    let check = 'setup';
    try {
      const create = (role: string): string => {
        const name = `inspector-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}-${attempt}-${role}`;
        names.push(name);
        writeFileSync(join(markers, name), '');
        const device = infrastructure('create', () => run('xcrun', ['simctl', 'create', name,
          type.identifier, 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], { timeout: 120 }));
        devices.push(device);
        infrastructure('boot', () => {
          run('xcrun', ['simctl', 'boot', device], { timeout: 120 });
          run('xcrun', ['simctl', 'bootstatus', device, '-b'], { timeout: 300 });
        });
        return device;
      };
      const target = create('target');
      const cksim = (...args: string[]) => run(join(runtime, 'cksim'),
        ['--simulator', target, '--bundle', bundle, ...args], { timeout: 180 });
      infrastructure('install', () => run('xcrun', ['simctl', 'install', target, app], { timeout: 180 }));
      infrastructure('launch', () => launchToleratingASlowSimulator(() => cksim('launch')));
      infrastructure('bridge-connect', () => cksim('status'));
      const display = create('display');
      infrastructure('install', () => run('xcrun', ['simctl', 'install', display, inspector], { timeout: 180 }));
      const log = `${prefix}-bridge.log`;
      const fd = openSync(log, 'w');
      try {
        bridge = spawn(join(runtime, 'cksim'), ['--simulator', target, '--bundle', bundle,
          'inspect', '--app', inspector, '--inspector-simulator', display], { stdio: ['ignore', fd, fd],
          env: { ...process.env, NSUnbufferedIO: 'YES' } });
        bridge.on('error', error => appendFileSync(log, String(error)));
      } finally { closeSync(fd); }
      await connected(bridge, log);
      check = 'push';
      cksim('push', '--payload-file', join(work, 'push.json'), '--must-report', 'true');
      check = 'ui';
      const result = `${prefix}.xcresult`;
      const uiLog = `${prefix}-ui.log`;
      try {
        const output = run('xcodebuild', ['test', '-project', 'tools/inspector-ui/InspectorJourney.xcodeproj',
          '-scheme', 'InspectorJourney', '-destination', `platform=iOS Simulator,id=${display}`,
          '-parallel-testing-enabled', 'NO', '-retry-tests-on-failure', 'NO',
          '-derivedDataPath', join(work, 'ui-build'), '-resultBundlePath', result,
          'CODE_SIGNING_ALLOWED=NO', 'COMPILER_INDEX_STORE_ENABLE=NO'], { timeout: 600 });
        writeFileSync(uiLog, output);
      } catch (error) {
        const output = error instanceof Error ? error.message : String(error);
        writeFileSync(uiLog, output);
        // An assertion or even a started UI test is never retried.
        if (existsSync(result) && !output.includes("Test Case '-[")) {
          const report = run('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', result, '--compact']);
          if (runnerHungBeforeConnecting(report, output)) throw new InfrastructureFailure('runner-hang', error);
        }
        throw error;
      }
      check = 'journal';
      const journal = cksim('watch', '--json', '--duration', '1');
      writeFileSync(`${prefix}-events.jsonl`, journal);
      assertInspectorJournal(journal);
      summary(`product:ui passed; product:journal passed; infrastructure retries used: ${attempt}`);
      return;
    } catch (error) {
      writeFileSync(`${prefix}-failure.log`, `${new Date().toISOString()}\n${String(error)}\n${error instanceof Error ? String(error.cause ?? '') : ''}`);
      console.error(`${new Date().toISOString()} ${String(error)}`);
      await simulatorDiagnostics(prefix);
      for (const [index, device] of devices.entries()) {
        try { run('xcrun', ['simctl', 'io', device, 'screenshot', `${prefix}-${index}.png`], { timeout: 30 }); }
        catch { /* Preserve the original failure if a simulator cannot take a screenshot. */ }
      }
      if (error instanceof InfrastructureFailure) {
        summary(`infra:${error.step} (${attempt === 0 ? 'retrying after CoreSimulator restart' : 'retry exhausted'})`);
        console.error(error.cause);
        if (attempt === 0) {
          await stopBridge(bridge);
          bridge = undefined;
          try { await recover(names, markers); }
          catch (recoveryError) {
            summary('infra:service-restart failed');
            await simulatorDiagnostics(`${prefix}-recovery`);
            throw recoveryError;
          }
          continue;
        }
      } else { summary(`product:${check} failed; infrastructure retries used: ${attempt}`); }
      throw error;
    } finally {
      await stopBridge(bridge);
    }
  }
}

if (isMain(import.meta.url)) {
  await main(async () => {
    const work = process.argv[2];
    if (!work) throw new Error('Usage: inspector-journey.ts <work directory>');
    await journey(resolve(work));
  });
}
