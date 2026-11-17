import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { closeSync, copyFileSync, existsSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { run } from './command.ts';
import { assertLateHandlerResults } from './expo-late-handler-results.ts';
import type { LateHandlerConfiguration, LateHandlerResults, LateHandlerScenario } from '../expo/example/client/journeys/late-handler.ts';

/** Reuses the installed bundled app; each scenario starts with a fresh process and no handler. */
export async function lateHandlerJourneys(work: string, simulator: string, container: string, prefix: string,
  runID: string, launch: (evidence: string) => void): Promise<void> {
  const bundle = 'com.example.voipconversations';
  const input = join(container, 'Documents/late-handler-config.json');
  const output = join(container, 'Documents/late-handler-results.json');
  assert.ok(!existsSync(join(container, 'Documents/media-fixture.json')), 'Native media fixture must be absent');
  const control = join(work, 'runtime/cksim');
  const args = ['--simulator', simulator, '--bundle', bundle, '--app-container', container];
  const cksim = (...command: string[]) => run(control, [...args, ...command], { timeout: 120 });
  const cases: [LateHandlerScenario, number][] = [['before-deadline', 1000], ['after-deadline', 28000], ['preview-placement', 11000]];
  run('xcrun', ['simctl', 'terminate', simulator, bundle], { timeout: 120 });
  for (const [scenario, delay] of cases) {
    const config: LateHandlerConfiguration = { schemaVersion: 1, scenario, runID: `${runID}-${scenario}`,
      handlerAttachDelayMS: delay, connectDeadlineMS: 27000 };
    const evidence = `${prefix}-${scenario}`;
    rmSync(output, { force: true });
    writeFileSync(input, JSON.stringify(config));
    const payload = `${evidence}-push.json`;
    writeFileSync(payload, JSON.stringify({ incomingCall: { eventId: `${config.runID}-push`,
      serverCallId: `${config.runID}-call`, caller: { handleType: 'generic', value: 'fixture' }, hasVideo: false } }));
    let observer: ReturnType<typeof spawn> | undefined;
    let exited: Promise<void> | undefined;
    let launchFailure: unknown;
    let failed = false;
    try {
      if (scenario === 'preview-placement') { launch(evidence); }
      else {
        const log = openSync(`${evidence}-launcher.log`, 'w');
        try {
          observer = spawn(control, [...args, 'push', '--launch', '--run-id', config.runID,
            '--payload-file', payload, '--must-report', 'true', '--launch-receipt', `${evidence}-launch.json`],
          { stdio: ['ignore', log, log], timeout: 180000 });
        } finally { closeSync(log); }
        exited = new Promise(resolve => {
          observer!.once('error', error => { launchFailure = error; resolve(); });
          observer!.once('exit', code => { launchFailure = new Error(`Push launcher exited early: ${code}`); resolve(); });
        });
      }
      async function stage(expected: LateHandlerResults['stage']): Promise<LateHandlerResults> {
        const deadline = Date.now() + 120000;
        while (Date.now() < deadline) {
          if (launchFailure) throw launchFailure;
          if (existsSync(output)) {
            let result: LateHandlerResults | undefined;
            try { result = JSON.parse(readFileSync(output, 'utf8')) as LateHandlerResults; }
            catch (error) { if (!(error instanceof SyntaxError)) throw error; }
            if (result) {
              assert.deepEqual(result.configuration, config);
              if (result.stage === 'failed') throw new Error(result.failure);
              if (result.stage === expected) return result;
            }
          }
          await sleep(100);
        }
        throw new Error(`Timed out waiting for late-handler ${scenario} ${expected}`);
      }
      await stage('waiting');
      if (scenario === 'preview-placement') {
        cksim('incoming-filter', '--reason', 'do-not-disturb');
        cksim('push', '--payload-file', payload, '--must-report', 'true');
      } else {
        const deadline = Date.now() + 120000;
        let ringing: { uuid: string } | undefined;
        while (!ringing && Date.now() < deadline) {
          if (launchFailure) throw launchFailure;
          const calls = JSON.parse(cksim('status')).result.calls as { uuid: string; ringing: boolean }[];
          const incoming = calls.filter(call => call.ringing);
          assert.ok(incoming.length <= 1, 'Cold push reported multiple ringing calls');
          ringing = incoming[0];
          if (!ringing) await sleep(100);
        }
        assert.ok(ringing, 'Cold push did not report a ringing call');
        cksim('answer', ringing.uuid);
      }
      const result = await stage('complete');
      const journal = cksim('watch', '--json', '--duration', '1');
      writeFileSync(`${evidence}-events.jsonl`, journal);
      assertLateHandlerResults(result, config, journal);
    } catch (error) {
      failed = true;
      writeFileSync(`${evidence}-failure.log`, String(error));
      try { writeFileSync(`${evidence}-events.jsonl`, cksim('watch', '--json', '--duration', '1')); }
      catch { /* The primary failure remains in the scenario log. */ }
      throw error;
    } finally {
      if (existsSync(output)) copyFileSync(output, `${evidence}-app.json`);
      rmSync(input, { force: true });
      try { run('xcrun', ['simctl', 'terminate', simulator, bundle], { timeout: 120 }); }
      catch (error) {
        writeFileSync(`${evidence}-cleanup.log`, String(error));
        if (!failed) throw error;
      } finally {
        if (observer) {
          let forced = false;
          const timer = setTimeout(() => { forced = true; observer!.kill('SIGKILL'); }, 10000);
          await exited;
          clearTimeout(timer);
          if (forced) {
            writeFileSync(`${evidence}-cleanup.log`, 'Launch observer did not stop after app termination');
            if (!failed) throw new Error('Launch observer cleanup timed out');
          }
        }
      }
    }
  }
}
