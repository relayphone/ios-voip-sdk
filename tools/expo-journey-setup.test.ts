import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import { CommandFailure } from './command.ts';
import { JourneySetupTrace, warmSimulatorInstaller } from './expo-journey-setup.ts';

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

test('the probe is installed and removed on the owned device before the full install', t => {
  const trace = new JourneySetupTrace();
  const calls: [string, readonly string[], number | undefined][] = [];
  warmSimulatorInstaller('owned', '/fixture/Probe.app', trace, (command, args, options) => {
    calls.push([command, args, options?.timeout]);
    return '';
  });
  assert.deepEqual(calls, [
    ['xcrun', ['simctl', 'install', 'owned', '/fixture/Probe.app'], 180],
    ['xcrun', ['simctl', 'uninstall', 'owned', 'com.example.voip.install-probe'], 120],
  ]);
  const [install, uninstall] = savedTrace(t, trace);
  assert.equal(install.phase, 'probe-install');
  assert.equal(install.outcome, 'succeeded');
  assert.equal(uninstall.phase, 'probe-uninstall');
  assert.equal(uninstall.outcome, 'succeeded');
});

test('a timed-out probe install leaves failure evidence and never starts uninstall', t => {
  const trace = new JourneySetupTrace();
  const cause = new CommandFailure('spawnSync xcrun ETIMEDOUT', 180_001, 'installer output');
  assert.throws(() => warmSimulatorInstaller('owned', '/fixture/Probe.app', trace, (_command, args) => {
    assert.equal(args[1], 'install');
    throw cause;
  }), error => error === cause);
  const [install, uninstall] = savedTrace(t, trace);
  assert.equal(install.phase, 'probe-install');
  assert.equal(install.outcome, 'failed');
  assert.equal(install.stderrTail, 'installer output');
  assert.equal(uninstall, undefined);
});
