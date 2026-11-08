import assert from 'node:assert/strict';
import { test } from 'node:test';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deleteJourneySimulator, InfrastructureFailure, withInfrastructureRetry } from './expo-journey.ts';

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
