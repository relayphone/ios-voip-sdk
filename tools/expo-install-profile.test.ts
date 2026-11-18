import assert from 'node:assert/strict';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import { CommandFailure, run } from './command.ts';
import { collectInstallLog, compareMinimalInstall, compareWarmInstalls, installBundleInventory,
  prepareMinimalInstall } from './expo-install-profile.ts';
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
  mkdirSync(join(work, 'build'));
  mkdirSync(join(work, 'results'));
  const comparison = join(work, 'attempt-1');
  const calls: { phase: string; timeout?: number }[] = [];
  const minimalApp = prepareMinimalInstall(work, (_command, args, options) => {
    assert.equal(options?.timeout, 120);
    assert.notEqual(args[0], 'simctl');
    if (args.includes('--show-sdk-path')) return '/sdk';
    if (args.includes('swiftc')) {
      writeFileSync(args.at(-1)!, 'binary');
      return '';
    }
    return '';
  });
  assert.ok(minimalApp);
  const preparation = JSON.parse(readFileSync(join(work, 'results', 'install-probe-build.json'), 'utf8'));
  assert.equal(preparation.outcome, 'succeeded');
  compareMinimalInstall(minimalApp, join(work, 'Example.app'), 'owned', comparison, (_command, args, options) => {
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

test('a timed-out compile leaves a preparation diagnostic and no app to install', t => {
  const work = fixture(t);
  mkdirSync(join(work, 'build'));
  mkdirSync(join(work, 'results'));
  t.mock.method(console, 'warn', () => {});
  const minimalApp = prepareMinimalInstall(work, (_command, args) => {
    if (args.includes('--show-sdk-path')) return '/sdk';
    throw new CommandFailure('swiftc ETIMEDOUT', 120_000, '');
  });
  assert.equal(minimalApp, undefined);
  const receipt = JSON.parse(readFileSync(join(work, 'results', 'install-probe-build.json'), 'utf8'));
  assert.equal(receipt.outcome, 'failed');
  assert.match(receipt.output, /swiftc ETIMEDOUT/);
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

test('warm installs use the same path twice, then compare a fresh install of a smaller copy', t => {
  const work = fixture(t);
  const app = join(work, 'Example.app');
  const framework = 'Frameworks/Large Framework.framework';
  const executable = 'Large Framework';
  mkdirSync(join(app, framework), { recursive: true });
  writeFileSync(join(app, framework, executable), Buffer.alloc(65_536, 1));
  writeFileSync(join(app, 'main.jsbundle'), 'app');
  mkdirSync(join(work, 'build'));
  const copy = join(work, 'build', 'StrippedExample.app');
  const prefix = join(work, 'attempt-1');
  const operations: string[][] = [];
  compareWarmInstalls(app, 'owned', 'example', work, prefix, (command, args, options) => {
    operations.push([command, ...args]);
    if (command === '/usr/bin/du') return run(command, args, options);
    if (command === '/usr/bin/ditto') { cpSync(app, copy, { recursive: true }); return ''; }
    if (command === '/usr/bin/plutil') return executable;
    if (command === '/usr/bin/codesign') throw new CommandFailure('Unsigned', 1, 'code object is not signed at all');
    if (args[0] === 'strip') {
      assert.deepEqual(args, ['strip', '-S', join(copy, framework, executable)]);
      writeFileSync(args[2]!, 'stripped');
    }
    if (args[1] === 'install') assert.equal(options?.timeout, 180);
    return '';
  });
  const first = operations.findIndex(args => args[2] === 'install');
  assert.deepEqual(operations.slice(first - 1, first + 2), [
    ['xcrun', 'simctl', 'uninstall', 'owned', 'example'],
    ['xcrun', 'simctl', 'install', 'owned', app],
    ['xcrun', 'simctl', 'install', 'owned', app],
  ]);
  assert.deepEqual(operations.slice(-2), [
    ['xcrun', 'simctl', 'uninstall', 'owned', 'example'],
    ['xcrun', 'simctl', 'install', 'owned', copy],
  ]);
  const receipt = JSON.parse(readFileSync(`${prefix}-warm-installs.json`, 'utf8'));
  assert.equal(receipt.original.largest[0].path, framework);
  assert.equal(receipt.original.files, 2);
  assert.equal(receipt.original.allocated.outcome, 'succeeded');
  assert.equal(receipt.original.hostVerification.outcome, 'failed');
  assert.equal(receipt.original.repeat.outcome, 'succeeded');
  assert.equal(receipt.stripped.first.outcome, 'succeeded');
  assert.equal(receipt.stripped.bytes, 11);
  assert.equal(readFileSync(join(app, framework, executable)).length, 65_536);
});

test('a failed warm first install leaves a measurement and consumes no diagnostic retry', t => {
  const work = fixture(t);
  const app = join(work, 'Example.app');
  mkdirSync(app);
  writeFileSync(join(app, 'main.jsbundle'), 'app');
  const prefix = join(work, 'attempt-1');
  const installs: string[] = [];
  compareWarmInstalls(app, 'owned', 'example', work, prefix, (command, args, options) => {
    if (command === '/usr/bin/du') return run(command, args, options);
    if (args[1] === 'install') {
      installs.push(args[3]!);
      throw new CommandFailure('install ETIMEDOUT', 180_002, '');
    }
    return '';
  });
  assert.deepEqual(installs, [app]);
  const receipt = JSON.parse(readFileSync(`${prefix}-warm-installs.json`, 'utf8'));
  assert.match(receipt.original.first.output, /ETIMEDOUT/);
  assert.equal(receipt.original.repeat, undefined);
  assert.equal(receipt.stripped, undefined);
});
