// Temporary two-phase simulator CPU investigation; no UI, bridge or retries.
import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isMain, main, repository, run } from './command.ts';
import { displayDevice } from './inspector-devices.ts';
import { simulatorDiagnostics } from './inspector-resources.ts';
import { buildSimulatorApp } from './simulator-app.ts';

if (isMain(import.meta.url)) {
  await main(async () => {
    const work = resolve(process.argv[2]!);
    const results = join(work, 'results');
    const markers = join(work, 'simulators');
    mkdirSync(results, { recursive: true });
    mkdirSync(markers, { recursive: true });
    const events = join(results, 'phases.log');
    const note = (message: string) => {
      const line = `${new Date().toISOString()} ${message}\n`;
      appendFileSync(events, line);
      console.log(line.trim());
      if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, line);
    };
    const type = displayDevice();
    const sampler = spawn(process.execPath, [join(repository, 'tools/inspector-resources.ts'),
      join(results, 'resources.log')], { stdio: 'inherit' });
    sampler.on('error', error => note(`warning:resource-sampler ${String(error)}`));
    const names: string[] = [];
    const step = (label: string, body: () => void) => {
      note(`${label} start`);
      try { body(); note(`${label} complete`); }
      catch (error) { note(`${label} FAILED ${String(error)}`); process.exitCode = 1; }
    };
    const idle = async (phase: string, seconds: number) => {
      note(`${phase} idle ${seconds}s start`);
      await sleep(seconds * 1000);
      note(`${phase} idle complete`);
    };
    const create = (role: string) => {
      const name = `inspector-diagnostic-${process.env.GITHUB_RUN_ID}-${role}`;
      names.push(name);
      writeFileSync(join(markers, name), '');
      const id = run('xcrun', ['simctl', 'create', name, type.identifier,
        'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], { timeout: 120 });
      note(`${role} simulator ${id} ${type.name}`);
      step(`${role} boot`, () => {
        run('xcrun', ['simctl', 'boot', id], { timeout: 120 });
        run('xcrun', ['simctl', 'bootstatus', id, '-b'], { timeout: 300 });
      });
      return id;
    };
    try {
      const app = join(work, 'Smoke.app');
      buildSimulatorApp({ bundle: app, executable: 'Smoke', identifier: 'dev.callkitsim.smoke',
        displayName: 'Smoke', minimumOS: '18.0', sources: [join(repository, 'tools/smoke/SmokeApp.swift')] });
      note('phase A start');
      const target = create('target');
      await idle('A booted', 240);
      step('A install smoke', () => { run('xcrun', ['simctl', 'install', target, app], { timeout: 180 }); });
      step('A launch smoke', () => { run(join(work, 'runtime/cksim'), ['--simulator', target,
        '--bundle', 'dev.callkitsim.smoke', 'launch'], { timeout: 180 }); });
      await idle('A launched', 180);
      note('phase B start');
      const display = create('display');
      await idle('B booted', 300);
      step('B install inspector', () => { run('xcrun', ['simctl', 'install', display,
        join(work, 'inspector/CKSimInspector.app')], { timeout: 180 }); });
      await idle('B installed', 180);
      note('phase B complete');
    } finally {
      await simulatorDiagnostics(join(results, 'final'));
      sampler.kill('SIGTERM');
      for (const name of names) {
        try { run('xcrun', ['simctl', 'shutdown', name], { timeout: 120 }); } catch { /* May be stopped. */ }
        try { run('xcrun', ['simctl', 'delete', name], { timeout: 120 }); rmSync(join(markers, name)); }
        catch (error) { note(`cleanup ${name} ${String(error)}`); }
      }
    }
  });
}
