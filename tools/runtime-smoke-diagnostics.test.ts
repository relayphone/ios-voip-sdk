import assert from 'node:assert/strict';
import { test } from 'node:test';
import { smokeCommand, SmokeCommandFailure } from './runtime-smoke-diagnostics.ts';
import type { run } from './command.ts';

const original = new Error('cksim status exited with 1\nsimctl get_app_container timed out after 60s; inspect state before retrying.');
const fail = () => { throw original; };

test('a timed-out command records phase and bounded immediate health evidence without retrying', () => {
  let attempts = 0;
  const probes: string[] = [];
  assert.throws(() => smokeCommand('call:answer:status', '/package/cksim', ['status'], { timeout: 120 },
    () => { attempts++; throw original; }, (command, args, options) => {
      probes.push(command);
      if (command === 'xcrun') {
        assert.deepEqual(args, ['simctl', 'list', 'devices', '--json']);
        assert.equal(options?.timeout, 10);
        throw new Error('spawnSync xcrun ETIMEDOUT');
      }
      assert.deepEqual(args, ['-axo', 'pid=,etime=,comm=']);
      assert.equal(options?.timeout, 3);
      return '1 02:00 /sbin/launchd\n99 01:23 /Library/com.apple.CoreSimulator.CoreSimulatorService';
    }), error => {
      assert.ok(error instanceof SmokeCommandFailure);
      assert.equal(error.cause, original);
      assert.equal(error.hostUnresponsive, true);
      assert.equal(error.stage, 'call:answer:status');
      assert.match(error.message, /^infra:host-unresponsive/);
      assert.match(error.evidence, /99 01:23/);
      assert.doesNotMatch(error.evidence, /launchd/);
      return true;
    });
  assert.equal(attempts, 1);
  assert.deepEqual(probes, ['xcrun', 'ps']);
});

test('responsive and ordinary failed probes preserve command-timeout attribution', () => {
  for (const responsive of [true, false]) {
    assert.throws(() => smokeCommand('reporting:status', '/package/cksim', [], {}, fail,
      command => {
        if (command === 'xcrun' && !responsive) throw new Error('simctl exited with 1');
        return '';
      }), error => {
        assert.ok(error instanceof SmokeCommandFailure);
        assert.equal(error.hostUnresponsive, false);
        assert.match(error.message, /^runtime-smoke:command-timeout/);
        return true;
      });
  }
});

test('service probe failure is retained and never replaces the original command failure', () => {
  const inspect: typeof run = command => {
    if (command === 'ps') throw new Error('ps ETIMEDOUT');
    return '{}';
  };
  assert.throws(() => smokeCommand('setup:boot', 'xcrun', ['simctl', 'bootstatus'], {},
    () => { throw new Error('spawnSync xcrun ETIMEDOUT'); }, inspect), error => {
      assert.ok(error instanceof SmokeCommandFailure);
      assert.equal(error.hostUnresponsive, false);
      assert.match(error.evidence, /ps ETIMEDOUT/);
      return true;
    });
});

test('assertions, ordinary command failures and unrelated timeouts never probe or reclassify', () => {
  for (const error of [new assert.AssertionError({ message: 'wrong state' }),
    new Error('Timed out waiting for the call to connect'), new Error('simctl exited with 1')]) {
    assert.throws(() => smokeCommand('call:answer', '/package/cksim', [], {}, () => { throw error; },
      () => assert.fail('Unexpected probe')), candidate => candidate === error);
  }
  assert.throws(() => smokeCommand('build', 'swift', [], {}, () => { throw new Error('ETIMEDOUT'); },
    () => assert.fail('Unexpected probe')), /ETIMEDOUT/);
});

test('successful commands preserve output and original timeout unchanged', () => {
  assert.equal(smokeCommand('call:status', '/package/cksim', ['status'], { timeout: 120 },
    (_command, _args, options) => { assert.equal(options?.timeout, 120); return 'calls'; },
    () => assert.fail('Unexpected probe')), 'calls');
});

test('service evidence is capped and missing services remain explicit', () => {
  for (const rows of ['', `${'x'.repeat(10000)}/com.apple.CoreSimulator.CoreSimulatorService`]) {
    assert.throws(() => smokeCommand('call:status', '/package/cksim', [], {}, fail,
      command => command === 'ps' ? rows : '{}'), error => {
        assert.ok(error instanceof SmokeCommandFailure);
        assert.ok(error.evidence.length < 4200);
        if (!rows) assert.match(error.evidence, /not observed/);
        return true;
      });
  }
});
