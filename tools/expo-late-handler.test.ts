import assert from 'node:assert/strict';
import { ChildProcess } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { lateHandlerJourneys } from './expo-late-handler.ts';

test('cold push discovers its container; running-app diagnostics reuse the cached container', async t => {
  const root = mkdtempSync(join(tmpdir(), 'late-handler-launch-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const container = join(root, 'container');
  mkdirSync(join(container, 'Documents'), { recursive: true });
  const prefix = join(root, 'attempt');
  let launches = 0;
  let terminations = 0;
  let watches = 0;
  await assert.rejects(lateHandlerJourneys(root, 'owned-simulator', container, prefix, 'test-run',
    () => assert.fail('Incoming scenario must use a supervised push launch'),
    (command, args, options) => {
      launches++;
      assert.equal(command, join(root, 'runtime/cksim'));
      // cksim refuses cached discovery for push --launch, even for a known data container.
      assert.ok(args.includes('--launch'));
      assert.ok(!args.includes('--app-container'));
      assert.ok(args.includes('owned-simulator'));
      assert.ok(args.includes('test-run-before-deadline'));
      assert.equal(options.timeout, 180000);
      const child = new ChildProcess();
      queueMicrotask(() => child.emit('exit', 64, null));
      return child;
    },
    (command, args) => {
      if (command === 'xcrun') {
        assert.equal(args[1], 'terminate');
        terminations++;
      } else {
        assert.equal(args[args.indexOf('--app-container') + 1], container);
        assert.ok(args.includes('watch'));
        watches++;
      }
      return '';
    }), /Push launcher exited early: 64/);
  assert.equal(launches, 1);
  assert.equal(terminations, 2);
  assert.equal(watches, 1);
  assert.equal(existsSync(join(container, 'Documents/late-handler-config.json')), false);
  assert.match(readFileSync(`${prefix}-before-deadline-failure.log`, 'utf8'), /exited early: 64/);
});
