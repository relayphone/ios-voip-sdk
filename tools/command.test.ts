import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CommandFailure, run } from './command.ts';

test('timed-out commands preserve elapsed time and stderr emitted before the hang', () => {
  assert.throws(() => run(process.execPath, ['--eval',
    'process.stderr.write("installer waiting\\n"); setInterval(() => {}, 1000);'], { timeout: 1 }), error => {
    assert.ok(error instanceof CommandFailure);
    assert.match(error.message, /ETIMEDOUT/);
    assert.ok(error.elapsedMS >= 900);
    assert.match(error.stderrTail, /installer waiting/);
    return true;
  });
});

test('nonzero commands preserve a bounded stderr tail and existing exit attribution', () => {
  assert.throws(() => run(process.execPath, ['--eval',
    'process.stderr.write("a".repeat(8192) + "final diagnostic"); process.exitCode = 7;']), error => {
    assert.ok(error instanceof CommandFailure);
    assert.match(error.message, /exited with 7/);
    assert.equal(error.stderrTail.length, 4096);
    assert.ok(error.stderrTail.endsWith('final diagnostic'));
    return true;
  });
});

test('successful commands still return their trimmed stdout', () => {
  assert.equal(run(process.execPath, ['--eval', 'console.log(" ready ");']), 'ready');
});
