import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import { CommandFailure } from './command.ts';
import { collectInstallLog, compareMinimalInstall, installBundleInventory } from './expo-install-profile.ts';
import { JourneySetupTrace } from './expo-journey-setup.ts';

function fixture(t: TestContext): string {
  const work = mkdtempSync(join(tmpdir(), 'expo-install-profile-'));
  t.after(() => rmSync(work, { recursive: true, force: true }));
  return work;
}

test('counts installed files and bytes without traversing links', t => {
  const app = join(fixture(t), 'Example.app');
  mkdirSync(join(app, 'Frameworks', 'One.framework'), { recursive: true });
  mkdirSync(join(app, 'Example.dSYM'));
  writeFileSync(join(app, 'main.jsbundle'), '12345');
  writeFileSync(join(app, 'Frameworks', 'One.framework', 'One'), '123');
  writeFileSync(join(app, 'Example.dSYM', 'symbols'), '12');
  symlinkSync('Frameworks', join(app, 'alias'));
  assert.deepEqual(installBundleInventory(app), {
    files: 3, bytes: 10, frameworkFiles: 1, frameworkBytes: 3, dSYMFiles: 1, dSYMBytes: 2,
  });
});

test('the control installs and locates its container before checking signatures', t => {
  const work = fixture(t);
  const comparison = join(work, 'attempt-1');
  const calls: { phase: string; timeout?: number }[] = [];
  compareMinimalInstall(work, join(work, 'Example.app'), 'owned', comparison, (_command, args, options) => {
    if (args.includes('--show-sdk-path')) return '/sdk';
    if (args.includes('swiftc')) {
      writeFileSync(args.at(-1)!, 'binary');
      return '';
    }
    if (args.includes('--verify')) calls.push({ phase: 'verify', timeout: options?.timeout });
    if (args[0] === 'simctl') {
      assert.equal(args[2], 'owned');
      calls.push({ phase: args[1]!, timeout: options?.timeout });
    }
    return '';
  });
  assert.deepEqual(calls, [{ phase: 'install', timeout: 180 }, { phase: 'get_app_container', timeout: 120 },
    { phase: 'verify', timeout: 60 }, { phase: 'verify', timeout: 60 }]);
  const receipt = JSON.parse(readFileSync(`${comparison}-install-comparison.json`, 'utf8'));
  assert.equal(receipt.minimal.install.outcome, 'succeeded');
  assert.equal(receipt.minimal.container.outcome, 'succeeded');
  assert.equal(receipt.minimal.bundle.files, 2);
});

test('installer logs are queried only for a recorded install window', t => {
  const prefix = join(fixture(t), 'attempt-1');
  const setup = new JourneySetupTrace();
  collectInstallLog(setup, prefix, () => assert.fail('install has not started'));
  const failure = new CommandFailure('install timeout', 180_002, '');
  assert.throws(() => setup.observe('install', () => { throw failure; }), error => error === failure);
  collectInstallLog(setup, prefix, (command, args, options) => {
    assert.equal(command, '/usr/bin/log');
    assert.equal(options?.timeout, 20);
    for (const bound of ['--start', '--end']) {
      const idx = args.indexOf(bound);
      assert.ok(idx >= 0);
      assert.match(args[idx + 1]!, /^@\d+$/);
    }
    return 'installer event';
  });
  const receipt = JSON.parse(readFileSync(`${prefix}-install-log.json`, 'utf8'));
  assert.equal(receipt.output, 'installer event');
});
