import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { runBounded } from './run-bounded.ts';

test('returns the child exit status', async () => {
  const result = await runBounded(process.execPath, ['-e', 'process.exit(7)'], { timeoutMs: 5000 });
  assert.deepEqual(result, { status: 7, timedOut: false });
});

test('times out a command and stops it', async () => {
  const result = await runBounded(process.execPath, ['-e', 'setTimeout(() => {}, 600)'], { timeoutMs: 100 });
  assert.deepEqual(result, { status: 124, timedOut: true });
});

test('escalates to SIGKILL for a resistant child', { timeout: 20_000 }, async () => {
  const { mkdtemp, readFile, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { setTimeout: delay } = await import('node:timers/promises');
  const dir = await mkdtemp(join(tmpdir(), 'bounded-test-'));
  const controller = new AbortController();
  try {
    const marker = join(dir, 'ready');
    const script = `process.on('SIGTERM', () => {}); require('node:fs').writeFileSync(process.argv[1], String(process.pid)); setInterval(() => {}, 1000);`;
    const run = runBounded(process.execPath, ['-e', script, marker], { timeoutMs: 15_000, signal: controller.signal });
    const readyDeadline = AbortSignal.timeout(5000);
    let pid: number | undefined;
    while (!readyDeadline.aborted && pid === undefined) {
      try { pid = Number(await readFile(marker, 'utf8')); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
        await delay(25);
      }
    }
    assert.ok(pid, 'child did not start');
    controller.abort();
    assert.deepEqual(await run, { status: 130, timedOut: false });
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    controller.abort();
    await rm(dir, { recursive: true, force: true });
  }
});

test('cancellation stops the owned process group', async () => {
  const controller = new AbortController();
  const cancel = setTimeout(() => controller.abort(), 100);
  try {
    const result = await runBounded(process.execPath, ['-e', 'setTimeout(() => {}, 600)'], {
      timeoutMs: 5000, signal: controller.signal,
    });
    assert.deepEqual(result, { status: 130, timedOut: false });
  } finally {
    clearTimeout(cancel);
  }
});

test('command line forwards a child exit status', async () => {
  const { spawnSync } = await import('node:child_process');
  const result = spawnSync(process.execPath, [new URL('./run-bounded.ts', import.meta.url).pathname,
    '5', process.execPath, '-e', 'process.exit(7)']);
  assert.equal(result.status, 7);
});

test('command line reports a missing executable', async () => {
  const { spawnSync } = await import('node:child_process');
  const result = spawnSync(process.execPath, [new URL('./run-bounded.ts', import.meta.url).pathname,
    '5', '/definitely-not-a-real-command']);
  assert.equal(result.status, 127);
});

test('command line forwards termination after cleaning up the child', { timeout: 10_000 }, async () => {
  const { spawn } = await import('node:child_process');
  const { mkdtemp, readFile, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { setTimeout: delay } = await import('node:timers/promises');
  const dir = await mkdtemp(join(tmpdir(), 'bounded-cli-'));
  const marker = join(dir, 'ready');
  const script = `require('node:fs').writeFileSync(process.argv[1], String(process.pid)); setInterval(() => {}, 1000);`;
  const runner = spawn(process.execPath, [new URL('./run-bounded.ts', import.meta.url).pathname,
    '8', process.execPath, '-e', script, marker], { stdio: 'ignore' });
  const exit = new Promise<number | null>((resolve, reject) => {
    runner.once('error', reject);
    runner.once('exit', resolve);
  });
  try {
    const readyDeadline = AbortSignal.timeout(5000);
    let pid: number | undefined;
    while (!readyDeadline.aborted && pid === undefined) {
      try { pid = Number(await readFile(marker, 'utf8')); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
        await delay(25);
      }
    }
    assert.ok(pid, 'child did not start');
    runner.kill('SIGTERM');
    assert.equal(await exit, 143);
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    runner.kill('SIGTERM');
    await exit;
    await rm(dir, { recursive: true, force: true });
  }
});

test('reports process group probe failures rather than throwing from a callback', async () => {
  const { spawnSync } = await import('node:child_process');
  const moduleURL = new URL('./run-bounded.ts', import.meta.url).href;
  const script = `const { runBounded } = await import(process.argv[1]);
    const kill = process.kill.bind(process);
    process.kill = (pid, signal) => { if (signal === 0) { const error = new Error('probe failed'); error.code = 'EPERM'; throw error; } return kill(pid, signal); };
    try { await runBounded(process.execPath, ['-e', ''], {timeoutMs: 1000}); process.exitCode = 2; }
    catch (error) { if (error.code !== 'EPERM') process.exitCode = 3; }`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script, moduleURL], { timeout: 5000 });
  assert.equal(result.status, 0, result.stderr.toString());
});

test('waits for child reaping when a termination probe temporarily returns EPERM', async () => {
  const { spawnSync } = await import('node:child_process');
  const moduleURL = new URL('./run-bounded.ts', import.meta.url).href;
  const script = `const { runBounded } = await import(process.argv[1]);
    const kill = process.kill.bind(process);
    let terminated = false;
    let injected = false;
    process.kill = (pid, signal) => {
      if (signal === 'SIGTERM') terminated = true;
      if (terminated && signal === 0 && !injected) {
        injected = true;
        const error = new Error('temporary probe failure'); error.code = 'EPERM'; throw error;
      }
      return kill(pid, signal);
    };
    const result = await runBounded(process.execPath, ['-e', 'setTimeout(() => {}, 1000)'], {timeoutMs: 100});
    if (!injected || result.status !== 124) process.exitCode = 2;`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script, moduleURL], { timeout: 5000 });
  assert.equal(result.status, 0, result.stderr.toString());
});

test('retries a temporary termination signal permission failure', async () => {
  const { spawnSync } = await import('node:child_process');
  const moduleURL = new URL('./run-bounded.ts', import.meta.url).href;
  const script = `const { runBounded } = await import(process.argv[1]);
    const kill = process.kill.bind(process);
    let injected = false;
    process.kill = (pid, signal) => {
      if (signal === 'SIGTERM' && !injected) {
        injected = true;
        const error = new Error('temporary signal failure'); error.code = 'EPERM'; throw error;
      }
      return kill(pid, signal);
    };
    const result = await runBounded(process.execPath, ['-e', 'setTimeout(() => {}, 1000)'], {timeoutMs: 100});
    if (!injected || result.status !== 124) process.exitCode = 2;`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script, moduleURL], { timeout: 5000 });
  assert.equal(result.status, 0, result.stderr.toString());
});

test('reports a persistent termination probe permission failure', async () => {
  const { spawnSync } = await import('node:child_process');
  const moduleURL = new URL('./run-bounded.ts', import.meta.url).href;
  const script = `const { runBounded } = await import(process.argv[1]);
    const kill = process.kill.bind(process);
    let terminated = false;
    process.kill = (pid, signal) => {
      if (signal === 'SIGTERM') terminated = true;
      if (terminated && signal === 0) {
        const error = new Error('persistent probe failure'); error.code = 'EPERM'; throw error;
      }
      return kill(pid, signal);
    };
    try { await runBounded(process.execPath, ['-e', 'setTimeout(() => {}, 1000)'], {timeoutMs: 100}); process.exitCode = 2; }
    catch (error) { if (error.code !== 'EPERM') process.exitCode = 3; }`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script, moduleURL], { timeout: 7000 });
  assert.equal(result.status, 0, result.stderr.toString());
});

test('keeps ownership of a descendant after the parent exits', { timeout: 10_000 }, async () => {
  const { mkdtemp, readFile, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { setTimeout: delay } = await import('node:timers/promises');
  const dir = await mkdtemp(join(tmpdir(), 'bounded-tree-'));
  const ready = join(dir, 'ready');
  const stopped = join(dir, 'stopped');
  const childScript = `const fs=require('node:fs');process.on('SIGTERM',()=>{fs.writeFileSync(process.argv[2],'yes');process.exit(0)});fs.writeFileSync(process.argv[1],'ready');setInterval(()=>{},1000);`;
  const parentScript = `const fs=require('node:fs');fs.writeFileSync(process.argv[3],String(process.pid));require('node:child_process').spawn(process.execPath,['-e',process.argv[1],process.argv[2],process.argv[4]],{stdio:'ignore'}).unref();`;
  const controller = new AbortController();
  const run = runBounded(process.execPath, ['-e', parentScript, childScript, ready, join(dir, 'parent'), stopped], { timeoutMs: 8000, signal: controller.signal });
  try {
    const deadline = AbortSignal.timeout(5000);
    let readyAndParentGone = false;
    while (!deadline.aborted && !readyAndParentGone) {
      try {
        await readFile(ready);
        const parent = Number(await readFile(join(dir, 'parent'), 'utf8'));
        try { process.kill(parent, 0); } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
          readyAndParentGone = true;
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      }
      if (!readyAndParentGone) await delay(25);
    }
    assert.ok(readyAndParentGone, 'parent did not exit and leave its ready descendant');
    controller.abort();
    assert.deepEqual(await run, { status: 130, timedOut: false });
    assert.equal(await readFile(stopped, 'utf8'), 'yes');
  } finally {
    controller.abort();
    await run.catch(() => {});
    await rm(dir, { recursive: true, force: true });
  }
});

test('command line reports a non-executable file', async () => {
  const { spawnSync } = await import('node:child_process');
  const { mkdtemp, rm, writeFile } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = await mkdtemp(join(tmpdir(), 'bounded-denied-'));
  try {
    const path = join(dir, 'not-executable');
    await writeFile(path, 'denied', { mode: 0o600 });
    const result = spawnSync(process.execPath, [new URL('./run-bounded.ts', import.meta.url).pathname, '5', path]);
    assert.equal(result.status, 126);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
