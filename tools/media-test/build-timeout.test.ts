import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { runBuild, captureBuildDiagnostics } from './build-timeout.ts';
import { execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

test('ordinary success and failure preserve status without collecting diagnostics', async () => {
  for (const code of [0, 7]) {
    const result = await runBuild({ command: process.execPath, args: ['-e', `process.exit(${code})`],
      timeoutMS: 5_000, directory: '', capture: async () => assert.fail('Unexpected diagnostics') });
    assert.equal(result, code);
  }
});

test('timeout samples a live build before killing its process group and returns alarm status', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'build-timeout-'));
  let buildPID = 0;
  try {
    const result = await runBuild({ command: process.execPath,
      args: ['-e', 'setInterval(() => {}, 1000)'], timeoutMS: 300, directory,
      capture: async pid => { buildPID = pid; process.kill(pid, 0); } });
    assert.equal(result, 142);
    assert.ok(buildPID > 0);
    assert.throws(() => process.kill(buildPID, 0), { code: 'ESRCH' });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('failed diagnostics still terminate the timed out build', async () => {
  let buildPID = 0;
  assert.equal(await runBuild({ command: process.execPath,
    args: ['-e', 'setInterval(() => {}, 1000)'], timeoutMS: 300, directory: '',
    capture: async pid => { buildPID = pid; throw new Error('Sample failed'); } }), 142);
  assert.throws(() => process.kill(buildPID, 0), { code: 'ESRCH' });
});

test('the diagnostic watchdog kills the build even when capture never returns', { timeout: 25_000 }, async () => {
  let buildPID = 0;
  try {
    assert.equal(await runBuild({ command: process.execPath,
      args: ['-e', 'setInterval(() => {}, 1000)'], timeoutMS: 100, directory: '',
      capture: async pid => { buildPID = pid; await new Promise<void>(() => {}); } }), 142);
    assert.throws(() => process.kill(buildPID, 0), { code: 'ESRCH' });
  } finally { if (buildPID) { try { process.kill(-buildPID, 'SIGKILL'); } catch { /* Already stopped. */ } } }
});

test('timeout also stops a build worker which ignores termination requests', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'build-worker-'));
  const receipt = join(directory, 'worker-pid');
  let workerPID = 0;
  try {
    const script = `const {spawn}=require('node:child_process');
      const worker=spawn(process.execPath,['-e',"process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],{stdio:'ignore'});
      require('node:fs').writeFileSync(${JSON.stringify(receipt)},String(worker.pid));setInterval(()=>{},1000);`;
    assert.equal(await runBuild({ command: process.execPath, args: ['-e', script], timeoutMS: 500, directory,
      capture: async () => {
        for (let attempt = 0; attempt < 20; attempt++) {
          try { workerPID = Number(readFileSync(receipt, 'utf8')); break; } catch { await delay(50); }
        }
        assert.ok(workerPID > 0); process.kill(workerPID, 0);
      } }), 142);
    assert.ok(workerPID > 0);
    // A reparented worker can briefly remain a zombie before launchd/init reaps it.
    let state = '';
    try { state = execFileSync('/bin/ps', ['-p', String(workerPID), '-o', 'stat='], { encoding: 'utf8' }).trim(); }
    catch { /* The worker was reaped. */ }
    assert.ok(state === '' || state.startsWith('Z'), `Worker still running: ${state}`);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('real diagnostics are bounded and omit process command arguments', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'build-diagnostics-'));
  try {
    await captureBuildDiagnostics(process.pid, directory);
    for (const file of ['processes.txt', 'disk.txt', 'load.txt', 'sample.txt']) {
      const contents = readFileSync(join(directory, file));
      assert.ok(contents.length > 0 && contents.length <= 256 * 1024);
    }
    assert.ok(!readFileSync(join(directory, 'processes.txt'), 'utf8').includes('build-timeout.test.ts'));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
