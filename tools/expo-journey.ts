import { lateHandlerJourneys } from './expo-late-handler.ts';
import { simulatorRuntime } from './simulator-runtime.ts';
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { CommandFailure, isMain, main, run } from './command.ts';
import { simulatorDevice } from './inspector-devices.ts';
import { captureTail, simulatorDiagnostics } from './inspector-resources.ts';
import { launchToleratingASlowSimulator } from './runtime-smoke.ts';
import { assertExpoJournal, assertJavaScriptResults } from './expo-journey-results.ts';
import { buildBundledExample } from './expo-journey-build.ts';
import { JourneySetupTrace, waitForJourneyBoot } from './expo-journey-setup.ts';
import { journeyIDs, type JourneyStage } from '../expo/example/client/journeys/results.ts';

const bundle = 'com.example.voipconversations';

/** Launches the source-activated app and retains its startup output. */
export function launchBundledExample(simulator: string, prefix: string, execute: typeof run = run): string {
  return launchToleratingASlowSimulator(() => execute('xcrun', ['simctl', 'launch',
    `--stdout=${prefix}-stdout.log`, `--stderr=${prefix}-stderr.log`, simulator, bundle], { timeout: 180 }));
}

/** Approves the explicit journey link on the owned simulator, as Expo CLI does. */
export function openJourneyLink(simulator: string, runID: string, execute: typeof run = run): void {
  const inventory = JSON.parse(execute('xcrun', ['simctl', 'list', 'devices', '--json'], { timeout: 120 })) as {
    devices: Record<string, { udid: string; dataPath: string }[]>;
  };
  const device = Object.values(inventory.devices).flat().find(device => device.udid === simulator);
  if (!device?.dataPath) throw new Error(`Missing data path for journey simulator ${simulator}`);
  const plist = join(device.dataPath, 'Library/Preferences/com.apple.launchservices.schemeapproval.plist');
  if (!existsSync(plist)) execute('plutil', ['-create', 'binary1', plist], { timeout: 120 });
  execute('plutil', ['-replace', String.raw`com\.apple\.CoreSimulator\.CoreSimulatorBridge-->conversations-example`,
    '-string', bundle, plist], { timeout: 120 });
  execute('xcrun', ['simctl', 'openurl', simulator, `conversations-example://journey?runID=${runID}`], { timeout: 120 });
}

export class InfrastructureFailure extends Error {
  readonly step: string;
  constructor(step: string, cause: unknown) { super(`infra:${step}`, { cause }); this.step = step; }
}

/** Installation diagnostics survive both the immediate classification and retry summary. */
export class InstallFailure extends InfrastructureFailure {
  readonly elapsedMS: number;
  readonly stderrTail: string | undefined;
  constructor(cause: unknown, elapsedMS: number, stderrTail: string | undefined) {
    super('install', cause);
    this.elapsedMS = elapsedMS;
    this.stderrTail = stderrTail;
    this.message += `; elapsed_ms=${elapsedMS}; stderr_tail=${JSON.stringify(stderrTail ?? '(unavailable)')}`;
  }
}

/** Keeps the existing install deadline while retaining the failed command's evidence. */
export function installBundledExample(simulator: string, app: string, execute: typeof run = run,
  now: () => number = () => performance.now()): void {
  const started = now();
  try {
    execute('xcrun', ['simctl', 'install', simulator, app], { timeout: 180 });
  } catch (cause) {
    throw new InstallFailure(cause, cause instanceof CommandFailure ? cause.elapsedMS : Math.round(now() - started),
      cause instanceof CommandFailure ? cause.stderrTail : undefined);
  }
}

/** Host evidence invalidates startup attribution without making a product check retryable. */
export class HostUnresponsiveFailure extends Error {
  readonly evidence: string;
  constructor(cause: unknown, evidence: string) {
    super('infra:host-unresponsive', { cause }); this.evidence = evidence;
  }
}

/** Probe immediately after a bootstrap failure, before slower diagnostic collection. */
export function classifyJourneyFailure(error: unknown, check: string, simulator: string | undefined,
  bootstatusRetried: boolean, execute: typeof run = run): unknown {
  if (check !== 'javascript-start' || !simulator || error instanceof InfrastructureFailure) return error;
  if (bootstatusRetried) return new HostUnresponsiveFailure(error, 'bootstatus failed on the prior attempt');
  try {
    execute('xcrun', ['simctl', 'list', 'devices', '--json'], { timeout: 10 });
  } catch (probe) {
    if (probe instanceof Error && /\bETIMEDOUT\b|\btimed out\b/i.test(probe.message)) {
      return new HostUnresponsiveFailure(error, `Immediate simulator probe: ${probe.message}`);
    }
  }
  return error;
}
function infrastructure<T>(step: string, body: () => T): T {
  try { return body(); } catch (error) { throw new InfrastructureFailure(step, error); }
}
function summary(message: string): void {
  console.log(message);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${message}\n`);
}

/** Finds devices by the name recorded before creation, including a timed-out create. */
export function deleteJourneySimulator(name: string, markers: string, execute: typeof run = run): void {
  const inventory = JSON.parse(execute('xcrun', ['simctl', 'list', 'devices', '--json'], { timeout: 120 })) as {
    devices: Record<string, { name: string; udid: string }[]>;
  };
  for (const device of Object.values(inventory.devices).flat().filter(device => device.name === name)) {
    try { execute('xcrun', ['simctl', 'shutdown', device.udid], { timeout: 120 }); } catch { /* May be stopped. */ }
    execute('xcrun', ['simctl', 'delete', device.udid], { timeout: 120 });
  }
  rmSync(join(markers, name), { force: true });
}

/** Only simulator setup failures qualify; product checks are executed once. */
export async function withInfrastructureRetry(attempt: (index: number) => Promise<void>, report = summary): Promise<void> {
  for (let index = 0; index < 2; index++) {
    try {
      await attempt(index);
      report(`product:javascript passed; product:journal passed; infrastructure retries used: ${index}`);
      return;
    } catch (error) {
      if (error instanceof InfrastructureFailure) {
        report(`${error.message} (${index === 0 ? 'retrying on a fresh simulator' : 'retry exhausted'}); infrastructure retries used: ${index}`);
        if (index === 0) continue;
      }
      throw error;
    }
  }
}

async function until<T>(label: string, seconds: number, read: () => T | undefined): Promise<T> {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const value = read();
    if (value !== undefined) return value;
    await sleep(250);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

/** Drives a bundled Debug example without a development server, taps or runtime injection. */
export async function expoJourney(work: string, app: string, example?: string): Promise<void> {
  const results = join(work, 'results');
  const markers = join(work, 'simulators');
  mkdirSync(results, { recursive: true }); mkdirSync(markers, { recursive: true });
  const deviceType = infrastructure('device-selection', simulatorDevice);
  summary(`Target simulator: ${deviceType.name} (${deviceType.identifier}); one simulator per attempt`);
  let bootstatusRetried = false;
  let build: Promise<void> | undefined;
  await withInfrastructureRetry(async attempt => {
    const name = `expo-journey-${process.env.GITHUB_RUN_ID ?? process.pid}-${process.env.GITHUB_RUN_ATTEMPT ?? 1}-${attempt}`;
    const prefix = join(results, `attempt-${attempt + 1}`);
    const setup = new JourneySetupTrace();
    const runID = `js-${process.env.GITHUB_RUN_ID ?? process.pid}-${process.env.GITHUB_RUN_ATTEMPT ?? 1}-${attempt}`;
    const ids = journeyIDs(runID);
    let target: string | undefined;
    let check = 'setup';
    let captureJournal: (() => string) | undefined;
    let output: string | undefined;
    try {
      writeFileSync(join(markers, name), '');
      target = infrastructure('create', () => setup.observe('create', () => run('xcrun',
        ['simctl', 'create', name, deviceType.identifier, simulatorRuntime], { timeout: 120 })));
      const simulator = target;
      infrastructure('boot', () => {
        try { waitForJourneyBoot(simulator, setup); }
        catch (error) { bootstatusRetried = true; throw error; }
      });
      // Leave the booted simulator idle while Xcode builds the example.
      if (example) {
        check = 'build';
        await (build ??= buildBundledExample(work, example, app));
        check = 'setup';
      }
      setup.observe('install', () => installBundledExample(simulator, app));
      const container = infrastructure('container', () => setup.observe('container', () => run('xcrun',
        ['simctl', 'get_app_container', simulator, bundle, 'data'], { timeout: 120 })));
      setup.save(prefix);
      const cksim = (...args: string[]) => run(join(work, 'runtime/cksim'),
        ['--simulator', simulator, '--bundle', bundle, '--app-container', container, ...args], { timeout: 180 });
      captureJournal = () => cksim('watch', '--json', '--duration', '1');
      // The SDK activates its compiled-in runtime; cksim launch would inject a second runtime.
      infrastructure('launch', () => launchBundledExample(simulator, prefix));
      check = 'javascript-start';
      const ready = join(container, 'Documents/javascript-journeys-ready.json');
      await until('JavaScript bootstrap', 120, () => existsSync(ready) ? true : undefined);
      cksim('status');
      output = join(container, 'Documents/javascript-journeys.json');
      openJourneyLink(simulator, runID);
      const stage = async (expected: JourneyStage) => until(`JS stage ${expected}`, 120, () => {
        if (!existsSync(output!)) return undefined;
        let value: unknown;
        try { value = JSON.parse(readFileSync(output!, 'utf8')); }
        catch (error) { if (error instanceof SyntaxError) return undefined; throw error; }
        if (!value || typeof value !== 'object' || !('runID' in value) || value.runID !== runID) throw new Error('Stale JS result');
        if ('stage' in value && value.stage === 'failed') throw new Error(readFileSync(output!, 'utf8'));
        return 'stage' in value && value.stage === expected ? value : undefined;
      });
      const push = (id: string) => {
        const payload = `${prefix}-${id}.json`;
        writeFileSync(payload, JSON.stringify({ incomingCall: { eventId: `${id}-push`, serverCallId: id,
          caller: { handleType: 'generic', value: id, displayName: id }, hasVideo: false } }));
        cksim('push', '--payload-file', payload, '--must-report', 'true');
      };
      check = 'incoming'; await stage('incoming'); push(ids.incoming);
      check = 'preview'; await stage('preview'); cksim('incoming-filter', '--reason', 'do-not-disturb'); push(ids.preview);
      check = 'elsewhere'; await stage('elsewhere'); cksim('incoming-filter', '--reason', 'none'); push(ids.elsewhere);
      await stage('server-event');
      const server = `${prefix}-server-event.json`;
      writeFileSync(server, JSON.stringify({ messageType: 'callEnded', callEnded: JSON.stringify({
        eventId: `${ids.elsewhere}-answered`, serverCallId: ids.elsewhere, reason: 'answeredElsewhere',
      }) }));
      cksim('push', '--payload-file', server, '--must-report', 'false');
      check = 'filtered'; await stage('filtered'); cksim('incoming-filter', '--reason', 'do-not-disturb'); push(ids.filtered);
      check = 'javascript'; const result = await stage('passed');
      copyFileSync(output, `${prefix}-app.json`);
      assertJavaScriptResults(result, runID);
      check = 'journal';
      const journal = captureJournal(); writeFileSync(`${prefix}-events.jsonl`, journal);
      assertExpoJournal(journal, runID);
      check = 'late-handler';
      await lateHandlerJourneys(work, simulator, container, prefix, runID, evidence => launchBundledExample(simulator, evidence));
    } catch (error) {
      if (error instanceof InfrastructureFailure && target && (error.step === 'install' || error.step === 'container')) {
        setup.captureInstallFailure(target);
      }
      if (check === 'setup' || check === 'build') setup.save(prefix);
      const failure = classifyJourneyFailure(error, check, target, bootstatusRetried);
      summary(`${failure instanceof InfrastructureFailure || failure instanceof HostUnresponsiveFailure ? failure.message : `product:${check} failed`}`);
      writeFileSync(`${prefix}-failure.log`, `${String(failure)}\n${failure instanceof Error ? String(failure.cause ?? '') : ''}\n${failure instanceof HostUnresponsiveFailure ? failure.evidence : ''}`);
      if (output && existsSync(output)) copyFileSync(output, `${prefix}-app.json`);
      try { if (captureJournal) writeFileSync(`${prefix}-events.jsonl`, captureJournal()); } catch { /* Retain the first failure. */ }
      if (target) {
        try { writeFileSync(`${prefix}-app.log`, await captureTail('xcrun', ['simctl', 'spawn', target,
          'log', 'show', '--last', '5m', '--style', 'compact', '--predicate', 'process == "VoIPExample"'])); }
        catch { /* Retain the first failure. */ }
        try { run('xcrun', ['simctl', 'io', target, 'screenshot', `${prefix}-screen.png`], { timeout: 30 }); }
        catch { /* An unavailable screenshot cannot replace the journey failure. */ }
      }
      await simulatorDiagnostics(prefix);
      throw failure;
    } finally {
      try { deleteJourneySimulator(name, markers); }
      catch (error) { summary('infra:cleanup failed'); throw error; }
    }
  });
}

if (isMain(import.meta.url)) await main(async () => {
  const [work, app, example] = process.argv.slice(2);
  if (!work || !app) throw new Error('Usage: expo-journey.ts <work directory> <Debug simulator app> [example project]');
  await expoJourney(resolve(work), resolve(app), example ? resolve(example) : undefined);
});
