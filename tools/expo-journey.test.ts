import assert from 'node:assert/strict';
import { test } from 'node:test';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { run } from './command.ts';
import { classifyJourneyFailure, HostUnresponsiveFailure, deleteJourneySimulator, InfrastructureFailure, launchBundledExample, openJourneyLink, withInfrastructureRetry } from './expo-journey.ts';

test('the journey link is approved for the owned simulator before opening it without a UI prompt', t => {
  const root = mkdtempSync(join(tmpdir(), 'expo-journey-link-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const plist = join(root, 'Library/Preferences/com.apple.launchservices.schemeapproval.plist');
  mkdirSync(join(root, 'Library/Preferences'), { recursive: true });
  const commands: { command: string; args: readonly string[] }[] = [];
  openJourneyLink('owned', 'run-1', (command, args, options) => {
    commands.push({ command, args });
    assert.equal(options?.timeout, 120);
    return JSON.stringify({ devices: { runtime: [{ udid: 'unrelated', dataPath: '/unrelated' }, { udid: 'owned', dataPath: root }] } });
  });
  assert.deepEqual(commands, [
    { command: 'xcrun', args: ['simctl', 'list', 'devices', '--json'] },
    { command: 'plutil', args: ['-create', 'binary1', plist] },
    { command: 'plutil', args: ['-replace', String.raw`com\.apple\.CoreSimulator\.CoreSimulatorBridge-->conversations-example`, '-string', 'com.example.voipconversations', plist] },
    { command: 'xcrun', args: ['simctl', 'openurl', 'owned', 'conversations-example://journey?runID=run-1'] },
  ]);
});

for (const existing of [false, true]) {
  test(`scheme approval ${existing ? 'preserves other binary plist entries' : 'creates a missing binary plist'}`,
    { skip: process.platform !== 'darwin' }, t => {
      const root = mkdtempSync(join(tmpdir(), 'expo-journey-link-'));
      t.after(() => rmSync(root, { recursive: true, force: true }));
      const plist = join(root, 'Library/Preferences/com.apple.launchservices.schemeapproval.plist');
      mkdirSync(join(root, 'Library/Preferences'), { recursive: true });
      const key = 'com.apple.CoreSimulator.CoreSimulatorBridge-->conversations-example';
      if (existing) {
        writeFileSync(plist, JSON.stringify({ 'other.scheme': 'other.app', [key]: 'previous.app' }));
        run('plutil', ['-convert', 'binary1', plist]);
      }
      let opens = 0;
      openJourneyLink('owned', 'run-1', (command, args, options) => {
        if (command === 'xcrun' && args[1] === 'list') {
          return JSON.stringify({ devices: { runtime: [{ udid: 'owned', dataPath: root }] } });
        }
        if (command === 'xcrun' && args[1] === 'openurl') {
          opens++;
          assert.deepEqual(JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', plist])), {
            ...(existing ? { 'other.scheme': 'other.app' } : {}), [key]: 'com.example.voipconversations',
          });
          return '';
        }
        return run(command, args, options);
      });
      assert.equal(opens, 1);
    });
}

test('approval failures never dispatch the journey link or retry the failed command', t => {
  const root = mkdtempSync(join(tmpdir(), 'expo-journey-link-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  let replacements = 0;
  assert.throws(() => openJourneyLink('owned', 'run-1', (command, args) => {
    assert.ok(!(command === 'xcrun' && args[1] === 'openurl'), 'Link dispatched after approval failed');
    if (command === 'plutil' && args[0] === '-replace') {
      replacements++;
      throw new Error('Approval write failed');
    }
    return JSON.stringify({ devices: { runtime: [{ udid: 'owned', dataPath: root }] } });
  }), /Approval write failed/);
  assert.equal(replacements, 1);
  assert.throws(() => openJourneyLink('missing', 'run-1', (command, args) => {
    assert.equal(command, 'xcrun');
    assert.deepEqual(args, ['simctl', 'list', 'devices', '--json']);
    return JSON.stringify({ devices: { runtime: [{ udid: 'unrelated', dataPath: root }] } });
  }), /Missing data path for journey simulator missing/);
});

test('launching the bundled app preserves both standard streams for startup failures', () => {
  const output = launchBundledExample('simulator', '/fixture/attempt-1', (command, args, options) => {
    assert.equal(command, 'xcrun');
    assert.deepEqual(args, ['simctl', 'launch', '--stdout=/fixture/attempt-1-stdout.log',
      '--stderr=/fixture/attempt-1-stderr.log', 'simulator', 'com.example.voipconversations']);
    assert.equal(options?.timeout, 180);
    return 'com.example.voipconversations: 123';
  });
  assert.equal(output, 'com.example.voipconversations: 123');
});

test('first success reports zero infrastructure retries', async () => {
  const attempts: number[] = []; const summaries: string[] = [];
  await withInfrastructureRetry(async index => { attempts.push(index); }, message => summaries.push(message));
  assert.deepEqual(attempts, [0]);
  assert.match(summaries.at(-1)!, /infrastructure retries used: 0/);
});
test('setup failure permits one new simulator attempt and reports the retry', async () => {
  const attempts: number[] = []; const summaries: string[] = [];
  await withInfrastructureRetry(async index => {
    attempts.push(index); if (index === 0) throw new InfrastructureFailure('boot', new Error('boot failed'));
  }, message => summaries.push(message));
  assert.deepEqual(attempts, [0, 1]);
  assert.match(summaries[0]!, /infra:boot.*fresh simulator/);
  assert.match(summaries.at(-1)!, /infrastructure retries used: 1/);
});
test('never retries an assertion or a command after the journeys start', async () => {
  for (const error of [new assert.AssertionError({ message: 'Wrong snapshot' }), new Error('push command failed')]) {
    let attempts = 0;
    await assert.rejects(withInfrastructureRetry(async () => { attempts++; throw error; }, () => {}), value => value === error);
    assert.equal(attempts, 1);
  }
});
test('a second infrastructure failure exhausts the retry', async () => {
  let attempts = 0;
  await assert.rejects(withInfrastructureRetry(async () => { attempts++; throw new InfrastructureFailure('create', 'unavailable'); }, () => {}), /infra:create/);
  assert.equal(attempts, 2);
});

test('cleanup finds a partially created simulator by name and leaves other devices alone', () => {
  const markers = mkdtempSync(join(tmpdir(), 'expo-journey-test-'));
  try {
    writeFileSync(join(markers, 'owned'), ''); const calls: string[][] = [];
    deleteJourneySimulator('owned', markers, (_command, args) => {
      calls.push([...args]);
      return JSON.stringify({ devices: { runtime: [{ name: 'owned', udid: 'target' }, { name: 'other', udid: 'unrelated' }] } });
    });
    assert.deepEqual(calls, [['simctl', 'list', 'devices', '--json'], ['simctl', 'shutdown', 'target'], ['simctl', 'delete', 'target']]);
    assert.equal(existsSync(join(markers, 'owned')), false);
  } finally { rmSync(markers, { recursive: true, force: true }); }
});

test('a failed create with no device can still retry; failed deletion keeps its cleanup marker', () => {
  const markers = mkdtempSync(join(tmpdir(), 'expo-journey-test-'));
  try {
    writeFileSync(join(markers, 'owned'), '');
    deleteJourneySimulator('owned', markers, () => JSON.stringify({ devices: {} }));
    assert.equal(existsSync(join(markers, 'owned')), false);
    writeFileSync(join(markers, 'owned'), '');
    assert.throws(() => deleteJourneySimulator('owned', markers, (_command, args) => {
      if (args[1] === 'delete') throw new Error('Delete failed');
      return JSON.stringify({ devices: { runtime: [{ name: 'owned', udid: 'target' }] } });
    }), /Delete failed/);
    assert.equal(existsSync(join(markers, 'owned')), true);
  } finally { rmSync(markers, { recursive: true, force: true }); }
});


test('an immediate simulator timeout classifies bootstrap failure without retrying it', async () => {
  const original = new Error('Timed out waiting for JavaScript bootstrap');
  let attempts = 0;
  await assert.rejects(withInfrastructureRetry(async () => {
    attempts++;
    throw classifyJourneyFailure(original, 'javascript-start', 'owned', false, (command, args, options) => {
      assert.equal(command, 'xcrun');
      assert.deepEqual(args, ['simctl', 'list', 'devices', '--json']);
      assert.equal(options?.timeout, 10);
      throw new Error('spawnSync xcrun ETIMEDOUT');
    });
  }, () => {}), error => {
    assert.ok(error instanceof HostUnresponsiveFailure);
    assert.equal(error.message, 'infra:host-unresponsive');
    assert.equal(error.cause, original);
    assert.match(error.evidence, /ETIMEDOUT/);
    return true;
  });
  assert.equal(attempts, 1);
});

test('responsive probes and non-timeout probe failures preserve product attribution', () => {
  const original = new Error('Bootstrap failed');
  for (const execute of [() => '{}', () => { throw new Error('simctl exited with 1'); }]) {
    assert.equal(classifyJourneyFailure(original, 'javascript-start', 'owned', false, execute), original);
  }
});

test('prior bootstatus failure classifies bootstrap failure and preserves its cause', () => {
  const original = new Error('Bootstrap failed');
  const classified = classifyJourneyFailure(original, 'javascript-start', 'owned', true,
    () => { throw new Error('Unexpected probe'); });
  assert.ok(classified instanceof HostUnresponsiveFailure);
  assert.equal(classified.cause, original);
  assert.match(classified.evidence, /bootstatus failed/);
});

test('later assertions, setup failures and missing simulator never trigger the startup probe', () => {
  const setup = new InfrastructureFailure('boot', 'timeout');
  const assertion = new assert.AssertionError({ message: 'Wrong call state' });
  const probe = () => { assert.fail('Unexpected probe'); };
  assert.equal(classifyJourneyFailure(setup, 'setup', 'owned', true, probe), setup);
  assert.equal(classifyJourneyFailure(assertion, 'javascript', 'owned', true, probe), assertion);
  assert.equal(classifyJourneyFailure(assertion, 'journal', 'owned', false, probe), assertion);
  assert.equal(classifyJourneyFailure(assertion, 'javascript-start', undefined, true, probe), assertion);
});

test('boot retry followed by a host-attributed bootstrap failure exhausts the existing budget', async () => {
  const attempts: number[] = [];
  const original = new Error('Bootstrap deadline expired');
  await assert.rejects(withInfrastructureRetry(async index => {
    attempts.push(index);
    if (index === 0) throw new InfrastructureFailure('boot', new Error('bootstatus ETIMEDOUT'));
    throw classifyJourneyFailure(original, 'javascript-start', 'owned', true);
  }, () => {}), error => error instanceof HostUnresponsiveFailure && error.cause === original);
  assert.deepEqual(attempts, [0, 1]);
});
