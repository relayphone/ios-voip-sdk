import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { runReadyUITest } from './inspector-ui-run.ts';

test('waits for runner readiness before pushing, ignoring stale signals', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'inspector-ready-'));
  const readyPath = join(folder, 'ready');
  const release = join(folder, 'release');
  writeFileSync(readyPath, 'stale');
  let pushes = 0;
  try {
    const output = await runReadyUITest(process.execPath, ['-e', `
      const fs = require('node:fs');
      const ready = process.env.TEST_RUNNER_CKSIM_INSPECTOR_READY_FILE;
      if (fs.existsSync(ready) || fs.existsSync(process.argv[1])) process.exit(2);
      fs.writeFileSync(ready, 'ready');
      const timer = setInterval(() => {
        if (fs.existsSync(process.argv[1])) { clearInterval(timer); console.log('passed'); }
      }, 10);
    `, release], { readyPath, timeout: 5, ready: () => {
      assert.equal(existsSync(readyPath), true);
      pushes++;
      writeFileSync(release, 'push');
    } });
    assert.equal(output.trim(), 'passed');
    assert.equal(pushes, 1);
    assert.equal(existsSync(readyPath), false);
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test('runner failure before readiness does not push and preserves test output', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'inspector-ready-'));
  try {
    await assert.rejects(runReadyUITest(process.execPath, ['-e', "console.log('UI assertion failed'); process.exit(1)"], {
      readyPath: join(folder, 'ready'), timeout: 5, ready: () => assert.fail('must not push'),
    }), /UI assertion failed/);
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test('a successful runner exit without readiness fails without pushing', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'inspector-ready-'));
  try {
    await assert.rejects(runReadyUITest(process.execPath, ['-e', ''], {
      readyPath: join(folder, 'ready'), timeout: 5, ready: () => assert.fail('must not push'),
    }), /without requesting the incoming call/);
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test('a failed push cancels the runner and cleans its signal', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'inspector-ready-'));
  const readyPath = join(folder, 'ready');
  const failure = new Error('push failed');
  try {
    await assert.rejects(runReadyUITest(process.execPath, ['-e', `
      require('node:fs').writeFileSync(process.env.TEST_RUNNER_CKSIM_INSPECTOR_READY_FILE, 'ready');
      setInterval(() => {}, 1000);
    `], { readyPath, timeout: 5, ready: () => { throw failure; } }), error => error === failure);
    assert.equal(existsSync(readyPath), false);
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
