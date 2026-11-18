import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import { CommandFailure } from './command.ts';
import { JourneySetupTrace, waitForJourneyBoot } from './expo-journey-setup.ts';

function savedTrace(t: TestContext, trace: JourneySetupTrace) {
  const directory = mkdtempSync(join(tmpdir(), 'expo-journey-setup-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  trace.save(join(directory, 'attempt-1'));
  return JSON.parse(readFileSync(join(directory, 'attempt-1-setup.json'), 'utf8'));
}

test('keeps bootstatus output and command failure evidence without recording a container path', t => {
  const trace = new JourneySetupTrace();
  const bootstatus = 'x'.repeat(8192) + '\nDevice already booted';
  assert.equal(trace.observe('bootstatus', () => bootstatus, stdout => stdout), bootstatus);
  assert.equal(trace.observe('container', () => '/simulator/container'), '/simulator/container');
  const cause = new CommandFailure('install timed out', 180_014, 'installer diagnostics');
  const original = new Error('infra:install', { cause });
  assert.throws(() => trace.observe('install', () => { throw original; }), error => error === original);

  const [boot, container, install] = savedTrace(t, trace);
  assert.equal(boot.phase, 'bootstatus');
  assert.equal(boot.outcome, 'succeeded');
  assert.equal(boot.stdout.length, 8192);
  assert.ok(boot.stdout.endsWith('Device already booted'));
  assert.equal(boot.lastMigrationElapsedMS, undefined);
  assert.equal(container.phase, 'container');
  assert.equal(container.stdout, undefined);
  assert.equal(install.phase, 'install');
  assert.equal(install.outcome, 'failed');
  assert.equal(install.stderrTail, 'installer diagnostics');
  for (const row of [boot, container, install]) {
    assert.ok(Number.isFinite(Date.parse(row.startedAt)));
    assert.ok(Number.isInteger(row.elapsedMS) && row.elapsedMS >= 0);
  }
});

test('boot starts under the readiness monitor and retains the last reported migration time', t => {
  const trace = new JourneySetupTrace();
  waitForJourneyBoot('owned', trace, (command, args, options) => {
    assert.equal(command, 'xcrun');
    assert.deepEqual(args, ['simctl', 'bootstatus', 'owned', '-b', '-d']);
    assert.equal(options?.timeout, 300);
    return '\tMigration Elapsed:00:02 seconds\n\tMigration Elapsed:01:46 seconds\n' + 'x'.repeat(8192);
  });
  const [boot] = savedTrace(t, trace);
  assert.equal(boot.phase, 'bootstatus');
  assert.equal(boot.lastMigrationElapsedMS, 106_000);
  assert.equal(boot.stdout.length, 8_192);
});

test('a timed-out simulator service probe still retains independent host diagnostics', t => {
  const trace = new JourneySetupTrace();
  const calls: [string, readonly string[], number | undefined][] = [];
  trace.captureInstallFailure('owned', (command, args, options) => {
    calls.push([command, args, options?.timeout]);
    if (command === '/bin/ps') {
      return '123 7 S /usr/bin/installd\n124 7 S /System/com.apple.CoreSimulator.CoreSimulatorService\n44 4 S /usr/bin/unrelated';
    }
    if (command === 'xcrun') throw new CommandFailure('spawnSync xcrun ETIMEDOUT', 8001, '');
    return 'installer log';
  });
  assert.deepEqual(calls[0], ['/bin/ps', ['-axo', 'pid,ppid,state,comm'], 3]);
  assert.deepEqual(calls[1], ['xcrun', ['simctl', 'spawn', 'owned', 'launchctl', 'list'], 8]);
  assert.equal(calls[2]?.[0], '/usr/bin/log');
  assert.equal(calls[2]?.[2], 15);

  const [processes, services, logs] = savedTrace(t, trace);
  assert.equal(processes.stdout, '123 7 S /usr/bin/installd\n124 7 S /System/com.apple.CoreSimulator.CoreSimulatorService');
  assert.equal(services.outcome, 'failed');
  assert.match(services.error, /ETIMEDOUT/);
  assert.equal(logs.stdout, 'installer log');
});
