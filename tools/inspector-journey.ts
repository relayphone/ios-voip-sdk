// Runs the Inspector GUI on a display simulator, keeping the injected target foregrounded.
import { spawn, type ChildProcess } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isMain, main, repository, run } from './command.ts';
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
    if (bridge.exitCode !== null) throw new InfrastructureFailure('bridge-connect', 'Bridge exited');
    if (readFileSync(log, 'utf8').includes('Ctrl-C to disconnect.')) return;
    await sleep(500);
  }
  throw new InfrastructureFailure('bridge-connect', 'Timed out');
}
function summary(message: string): void {
  console.log(message);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${message}\n`);
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
  for (let attempt = 0; attempt < 2; attempt++) {
    const devices: string[] = [];
    let bridge: ChildProcess | undefined;
    const prefix = join(results, `attempt-${attempt + 1}`);
    let check = 'setup';
    try {
      for (const role of ['target', 'display']) {
        const name = `inspector-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}-${attempt}-${role}`;
        // Record names before creation, so always() cleanup also covers interrupted creation.
        writeFileSync(join(markers, name), '');
        const device = infrastructure('create', () => run('xcrun', ['simctl', 'create', name,
          'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
          'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], { timeout: 120 }));
        devices.push(device);
        infrastructure('boot', () => {
          run('xcrun', ['simctl', 'boot', device], { timeout: 120 });
          run('xcrun', ['simctl', 'bootstatus', device, '-b'], { timeout: 300 });
        });
      }
      const [target, display] = devices as [string, string];
      const cksim = (...args: string[]) => run(join(runtime, 'cksim'),
        ['--simulator', target, '--bundle', bundle, ...args], { timeout: 180 });
      infrastructure('install', () => run('xcrun', ['simctl', 'install', target, app], { timeout: 180 }));
      infrastructure('launch', () => cksim('launch'));
      infrastructure('bridge-connect', () => cksim('status'));
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
      for (const [index, device] of devices.entries()) {
        try { run('xcrun', ['simctl', 'io', device, 'screenshot', `${prefix}-${index}.png`], { timeout: 30 }); }
        catch { /* Preserve the original failure if a simulator cannot take a screenshot. */ }
      }
      if (error instanceof InfrastructureFailure) {
        summary(`infra:${error.step} (${attempt === 0 ? 'retrying on fresh simulators' : 'retry exhausted'})`);
        console.error(error.cause);
        if (attempt === 0) continue;
      } else { summary(`product:${check} failed; infrastructure retries used: ${attempt}`); }
      throw error;
    } finally {
      bridge?.kill('SIGINT');
      for (const device of devices) {
        try { run('xcrun', ['simctl', 'shutdown', device], { timeout: 120 }); } catch { /* May be stopped. */ }
        // Keep markers: the workflow's always() step verifies deletion, including partial creates.
      }
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
