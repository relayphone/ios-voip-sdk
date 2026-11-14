import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { test } from 'node:test';
import { command, deadline, stopChild } from './fixture-runtime.ts';

test('simulator commands cannot starve the media publisher event loop', async () => {
  let ticks = 0;
  const timer = setInterval(() => ticks++, 5);
  try {
    await command(process.execPath, ['-e', 'setTimeout(() => {}, 100)'], 2000);
    assert.ok(ticks >= 5);
  } finally { clearInterval(timer); }
});
test('a stalled command and a stalled native promise have hard deadlines', async () => {
  await assert.rejects(command(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], 50));
  await assert.rejects(deadline(20, 'Native call', () => new Promise(() => {})), /exceeded/);
});
test('server shutdown awaits exit and escalates for an unresponsive child', async () => {
  const child = spawn(process.execPath, ['-e',
    'process.on("SIGTERM", () => {}); console.log("ready"); setInterval(() => {}, 1000)']);
  try {
    await deadline(2000, 'Child ready', () => once(child.stdout!, 'data'));
    await stopChild(child, 20);
    assert.equal(child.signalCode, 'SIGKILL');
  } finally { child.kill('SIGKILL'); }
});
