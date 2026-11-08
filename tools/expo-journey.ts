import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isMain, main, run } from './command.ts';
import { simulatorDevice } from './inspector-devices.ts';
import { captureTail, simulatorDiagnostics } from './inspector-resources.ts';
import { launchToleratingASlowSimulator } from './runtime-smoke.ts';
import { assertExpoJournal, assertJavaScriptResults } from './expo-journey-results.ts';
import { journeyIDs, type JourneyStage } from '../expo/example/client/journeys/results.ts';

const bundle = 'com.example.voipconversations';

/** Launches the source-activated app and retains its startup output. */
export function launchBundledExample(simulator: string, prefix: string, execute: typeof run = run): string {
  return launchToleratingASlowSimulator(() => execute('xcrun', ['simctl', 'launch',
    `--stdout=${prefix}-stdout.log`, `--stderr=${prefix}-stderr.log`, simulator, bundle], { timeout: 180 }));
}

export class InfrastructureFailure extends Error {
  readonly step: string;
  constructor(step: string, cause: unknown) { super(`infra:${step}`, { cause }); this.step = step; }
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
        report(`infra:${error.step} (${index === 0 ? 'retrying on a fresh simulator' : 'retry exhausted'}); infrastructure retries used: ${index}`);
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
export async function expoJourney(work: string, app: string): Promise<void> {
  const results = join(work, 'results');
  const markers = join(work, 'simulators');
  mkdirSync(results, { recursive: true }); mkdirSync(markers, { recursive: true });
  const deviceType = infrastructure('device-selection', simulatorDevice);
  summary(`Target simulator: ${deviceType.name} (${deviceType.identifier}); one simulator per attempt`);
  await withInfrastructureRetry(async attempt => {
    const name = `expo-journey-${process.env.GITHUB_RUN_ID ?? process.pid}-${process.env.GITHUB_RUN_ATTEMPT ?? 1}-${attempt}`;
    const prefix = join(results, `attempt-${attempt + 1}`);
    const runID = `js-${process.env.GITHUB_RUN_ID ?? process.pid}-${process.env.GITHUB_RUN_ATTEMPT ?? 1}-${attempt}`;
    const ids = journeyIDs(runID);
    let target: string | undefined;
    let check = 'setup';
    let captureJournal: (() => string) | undefined;
    let output: string | undefined;
    writeFileSync(join(markers, name), '');
    try {
      target = infrastructure('create', () => run('xcrun', ['simctl', 'create', name,
        deviceType.identifier, 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], { timeout: 120 }));
      const simulator = target;
      infrastructure('boot', () => {
        run('xcrun', ['simctl', 'boot', simulator], { timeout: 120 });
        run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], { timeout: 300 });
      });
      infrastructure('install', () => run('xcrun', ['simctl', 'install', simulator, app], { timeout: 180 }));
      const container = infrastructure('container', () => run('xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data'], { timeout: 120 }));
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
      run('xcrun', ['simctl', 'openurl', simulator, `conversations-example://journey?runID=${runID}`], { timeout: 120 });
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
    } catch (error) {
      summary(`${error instanceof InfrastructureFailure ? error.message : `product:${check} failed`}`);
      writeFileSync(`${prefix}-failure.log`, `${String(error)}\n${error instanceof Error ? String(error.cause ?? '') : ''}`);
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
      throw error;
    } finally {
      try { deleteJourneySimulator(name, markers); }
      catch (error) { summary('infra:cleanup failed'); throw error; }
    }
  });
}

if (isMain(import.meta.url)) await main(async () => {
  const [work, app] = process.argv.slice(2);
  if (!work || !app) throw new Error('Usage: expo-journey.ts <work directory> <Debug simulator app>');
  await expoJourney(resolve(work), resolve(app));
});
