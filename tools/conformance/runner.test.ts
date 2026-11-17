import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Configuration, Input, Journey } from './model.ts';
import type { JourneyDriver, Observation } from './runner.ts';
import { check, runJourney } from './runner.ts';
import { validTypeFixtures } from './fixtures.types.ts';

const configuration = { budgets: validTypeFixtures.budgets.value, outgoingMedia: 'whenProvided', connectionAuthority: 'application', maximumParticipatingCalls: 1, previewAnsweredElsewhere: false } as const satisfies Configuration;
const input = { kind: 'incoming', callID: ' call-α ', eventID: 'invite', line: validTypeFixtures.incoming.value.line, party: validTypeFixtures.incoming.value.parties[0] } as const satisfies Input;
const journey: Journey = { version: 0, id: 'host-control', configuration, steps: [
  { kind: 'input', input },
  { kind: 'expect', expectation: { kind: 'call', callID: ' call-α ', lifecycle: { kind: 'ringing' }, lineID: 'personal' } },
  { kind: 'expect', expectation: { kind: 'count', callID: ' call-α ', metric: 'claims', value: 0 } },
] };
const complete: Observation = { calls: [validTypeFixtures.incoming.value], participating: [], counts: [{ callID: ' call-α ', metric: 'claims', value: 0 }], systemEnds: [], errors: [] };
class ScriptedDriver implements JourneyDriver {
  readonly inputs: Input[] = [];
  resets = 0;
  closes = 0;
  observation: Observation = complete;
  failure: 'reset' | 'apply' | 'observe' | 'close' | undefined;
  async reset(_: Configuration): Promise<void> { this.resets++; if (this.failure === 'reset') throw new Error('reset failed'); }
  async apply(input: Input): Promise<void> { if (this.failure === 'apply') throw new Error('apply failed'); this.inputs.push(input); }
  async observe(): Promise<Observation> { if (this.failure === 'observe') throw new Error('observe failed'); return this.observation; }
  async close(): Promise<void> { this.closes++; if (this.failure === 'close') throw new Error('close failed'); }
}

test('runner sends only controls and configuration, checks real observations, and closes once', async () => {
  const driver = new ScriptedDriver();
  await runJourney(journey, driver);
  assert.deepEqual(driver.inputs, [input]);
  assert.equal(driver.resets, 1);
  assert.equal(driver.closes, 1);
});

for (const failure of ['reset', 'apply', 'observe', 'close'] as const) test(`runner propagates ${failure} failure and still owns cleanup`, async () => {
  const driver = new ScriptedDriver(); driver.failure = failure;
  await assert.rejects(runJourney(journey, driver), new RegExp(`${failure} failed`));
  assert.equal(driver.closes, 1);
});

test('wrong state and missing zero counters remain failing controls', async () => {
  for (const observation of [{ ...complete, calls: [validTypeFixtures.connected.value] }, { ...complete, counts: [] }]) {
    const driver = new ScriptedDriver(); driver.observation = observation;
    await assert.rejects(runJourney(journey, driver));
    assert.equal(driver.closes, 1);
  }
});

test('assertion and cleanup failures are both retained', async () => {
  const driver = new ScriptedDriver(); driver.observation = { ...complete, calls: [] }; driver.failure = 'close';
  await assert.rejects(runJourney(journey, driver), error => {
    assert.ok(error instanceof AggregateError);
    assert.equal(error.errors.length, 2);
    assert.match(String(error.errors[0]), /Missing call/);
    assert.match(String(error.errors[1]), /close failed/);
    return true;
  });
});

test('every expectation kind rejects incomplete or contradictory evidence', () => {
  assert.throws(() => check({ kind: 'count', callID: ' call-α ', metric: 'claims', value: 0 }, { ...complete, counts: [...complete.counts, ...complete.counts] }));
  assert.throws(() => check({ kind: 'participating', callIDs: ['a'] }, complete));
  assert.throws(() => check({ kind: 'systemEnd', callID: 'a', cause: 'remote' }, complete));
  assert.throws(() => check({ kind: 'error', callID: 'a', error: 'refused' }, complete));
  const observed = { ...complete, calls: [validTypeFixtures.failed.kind === 'endReason' ? { ...validTypeFixtures.incoming.value, lifecycle: { kind: 'ended', reason: validTypeFixtures.failed.value, endedAt: '2026-11-17T00:00:00.000Z' } as const } : validTypeFixtures.incoming.value] };
  assert.doesNotThrow(() => check({ kind: 'call', callID: ' call-α ', lifecycle: { kind: 'ended', reason: { kind: 'failed', error: 'claimTimedOut' } } }, observed));
  assert.throws(() => check({ kind: 'call', callID: ' call-α ', lifecycle: { kind: 'ended', reason: { kind: 'failed', error: 'refused' } } }, observed));
});

test('participation guards, preparation failure and elsewhere fallback select explicit rules', async () => {
  const { readFileSync } = await import('node:fs');
  const { decodeTransitions } = await import('./schema.ts');
  const { selectTransition } = await import('./runner.ts');
  const table = decodeTransitions(JSON.parse(readFileSync(new URL('../../spec/transitions.json', import.meta.url), 'utf8')));
  assert.equal(selectTransition(table, 'absent', 'start', new Set(['newCall'])), undefined);
  assert.equal(selectTransition(table, 'absent', 'start', new Set(['newCallAndSlot']))?.to, 'placing');
  assert.equal(selectTransition(table, 'previewing', 'join', new Set(['live'])), undefined);
  assert.equal(selectTransition(table, 'previewing', 'join', new Set(['joinEligible']))?.to, 'placing');
  assert.equal(selectTransition(table, 'placing', 'mediaFailed', new Set(['currentAttempt']))?.to, 'ending');
  assert.equal(selectTransition(table, 'placing', 'mediaFailed', new Set(['currentAttempt', 'incomingJoin']))?.to, 'previewing');
  assert.equal(selectTransition(table, 'placing', 'mediaFailed', new Set()), undefined);
  assert.equal(selectTransition(table, 'placing', 'deadlineExpired', new Set()), undefined);
  assert.equal(selectTransition(table, 'ringing', 'remoteEnd', new Set(['previewPolicy', 'firstTerminalIntent']))?.to, 'previewing');
  assert.equal(selectTransition(table, 'ringing', 'remoteEnd', new Set(['firstTerminalIntent']))?.to, 'ending');
  assert.deepEqual(selectTransition(table, 'placing', 'placed', new Set(['incomingJoin']))?.effects, ['prepareMedia']);
  assert.equal(selectTransition(table, 'ringing', 'noAnswerExpired', new Set(['live'])), undefined);
  assert.equal(selectTransition(table, 'ending', 'mediaReleased', new Set(['mediaReleased']))?.to, 'ended');
  assert.equal(selectTransition(table, 'ended', 'systemRemoved', new Set(['always']))?.to, 'same');
});
