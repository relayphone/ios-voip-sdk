import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import type { Configuration, Input, Journey, State } from './model.ts';
import type { JourneyDriver, Observation } from './runner.ts';
import { check, runJourney, selectTransition } from './runner.ts';
import { decodeTransitions, wireID } from './schema.ts';
import { validTypeFixtures } from './fixtures.types.ts';

const configuration = { budgets: validTypeFixtures.budgets.value, outgoingMedia: 'whenProvided', connectionAuthority: 'application', maximumParticipatingCalls: 1, previewAnsweredElsewhere: false } as const satisfies Configuration;
const input = { kind: 'incoming', callID: wireID('call-α'), eventID: wireID('invite'), line: validTypeFixtures.incoming.value.line, party: validTypeFixtures.incoming.value.parties[0] } as const satisfies Input;
const journey: Journey = { version: 0, id: wireID('host-control'), configuration, steps: [
  { kind: 'input', input },
  { kind: 'expect', expectation: { kind: 'call', callID: wireID('call-α'), lifecycle: { kind: 'ringing' }, lineID: wireID('personal') } },
  { kind: 'expect', expectation: { kind: 'count', callID: wireID('call-α'), metric: 'claims', value: 0 } },
] };
const complete: Observation = { calls: [validTypeFixtures.incoming.value], participating: [], counts: [{ callID: wireID('call-α'), metric: 'claims', value: 0 }], systemEnds: [], errors: [] };
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
  assert.throws(() => check({ kind: 'count', callID: wireID('call-α'), metric: 'claims', value: 0 }, { ...complete, counts: [...complete.counts, ...complete.counts] }));
  assert.throws(() => check({ kind: 'participating', callIDs: [wireID('a')] }, complete));
  assert.throws(() => check({ kind: 'systemEnd', callID: wireID('a'), cause: 'remote' }, complete));
  assert.throws(() => check({ kind: 'error', callID: wireID('a'), error: 'refused' }, complete));
  const observed = { ...complete, calls: [validTypeFixtures.failed.kind === 'endReason' ? { ...validTypeFixtures.incoming.value, lifecycle: { kind: 'ended', reason: validTypeFixtures.failed.value, endedAt: '2026-11-17T00:00:00.000Z' } as const } : validTypeFixtures.incoming.value] };
  assert.doesNotThrow(() => check({ kind: 'call', callID: wireID('call-α'), lifecycle: { kind: 'ended', reason: { kind: 'failed', error: 'claimTimedOut' } } }, observed));
  assert.throws(() => check({ kind: 'call', callID: wireID('call-α'), lifecycle: { kind: 'ended', reason: { kind: 'failed', error: 'refused' } } }, observed));
});

test('refusal results and canonical ownership are checked independently', () => {
  const callID = wireID('call-α');
  const observed = { ...complete, calls: [{ ...validTypeFixtures.incoming.value, lifecycle: { kind: 'ended', reason: { kind: 'answeredElsewhere' }, endedAt: '2026-11-17T00:00:00.000Z' } as const }],
    errors: [{ callID, error: 'refused', reason: { kind: 'answeredElsewhere' } } as const] };
  check({ kind: 'call', callID, lifecycle: { kind: 'ended', reason: { kind: 'answeredElsewhere' } } }, observed);
  check({ kind: 'error', callID, error: 'refused', reason: { kind: 'answeredElsewhere' } }, observed);
  assert.throws(() => check({ kind: 'error', callID, error: 'refused', reason: { kind: 'notAllowed' } }, observed));
  assert.throws(() => check({ kind: 'error', callID, error: 'refused', reason: { kind: 'answeredElsewhere' } }, { ...observed, errors: [{ callID, error: 'refused' }] }));
  assert.throws(() => check({ kind: 'call', callID, lifecycle: { kind: 'ended', reason: { kind: 'failed', error: 'refused' } } }, observed));
});

const table = decodeTransitions(JSON.parse(readFileSync(new URL('../../spec/transitions.json', import.meta.url), 'utf8')));
test('participation guards, preparation failure and elsewhere fallback select explicit rules', () => {
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
  assert.equal(selectTransition(table, 'ringing', 'answerRefused', new Set(['currentAttempt']))?.to, undefined);
  const previewRefusal = selectTransition(table, 'ringing', 'answerRefused', new Set(['elsewhereRefusalPreview', 'elsewhereRefusal']));
  assert.equal(previewRefusal?.id, 'answer-refused-preview');
  assert.equal(previewRefusal?.to, 'previewing');
  assert.deepEqual(previewRefusal?.effects, ['rejectAction', 'closeMedia', 'requestRemoval', 'publish']);
  assert.equal(selectTransition(table, 'ringing', 'answerRefused', new Set(['elsewhereRefusal']))?.id, 'answer-refused-elsewhere');
  assert.equal(selectTransition(table, 'ringing', 'answerRefused', new Set(['notAllowedRefusal']))?.id, 'answer-refused-not-allowed');
  assert.equal(selectTransition(table, 'ending', 'answerRefused', new Set(['elsewhereRefusal']))?.to, undefined);
  assert.deepEqual(selectTransition(table, 'placing', 'placed', new Set(['incomingJoin']))?.effects, ['prepareMedia']);
  assert.equal(selectTransition(table, 'ringing', 'noAnswerExpired', new Set(['live'])), undefined);
  assert.equal(selectTransition(table, 'ending', 'mediaReleased', new Set(['mediaReleased']))?.to, 'ended');
  assert.equal(selectTransition(table, 'ended', 'systemRemoved', new Set(['always']))?.to, 'same');
});

test('control requests, confirmations and failures have separate effects', () => {
  for (const [request, applied, failed, effect] of [
    ['hold', 'holdApplied', 'holdFailed', 'applyHold'],
    ['mute', 'muteApplied', 'muteFailed', 'applyMute'],
    ['video', 'videoApplied', 'videoFailed', 'applyVideo'],
    ['tones', 'tonesApplied', 'tonesFailed', 'sendTones'],
  ] as const) {
    const requested = selectTransition(table, 'connected', request, new Set(['supported']));
    assert.equal(requested?.to, 'same');
    assert.deepEqual(requested?.effects, ['trackAction', effect]);
    assert.equal(selectTransition(table, 'connected', applied, new Set()), undefined);
    assert.deepEqual(selectTransition(table, 'connected', applied, new Set(['currentAttempt']))?.effects, ['publish', 'settleAction']);
    assert.deepEqual(selectTransition(table, 'connected', failed, new Set(['currentAttempt']))?.effects, ['rejectAction']);
  }
  assert.equal(selectTransition(table, 'reconnecting', 'tones', new Set(['supported'])), undefined);
  assert.deepEqual(selectTransition(table, 'reconnecting', 'tonesFailed', new Set(['currentAttempt']))?.effects, ['rejectAction']);
  assert.deepEqual(selectTransition(table, 'connected', 'tones', new Set(['noToneTransport']))?.effects, ['rejectAction']);
});

test('retention precedes admission and stale permits can only be released', () => {
  assert.deepEqual(selectTransition(table, 'absent', 'remoteEnd', new Set(['always']))?.effects, ['bufferEnd']);
  assert.deepEqual(selectTransition(table, 'reporting', 'remoteEnd', new Set(['firstTerminalIntent', 'previewPolicy']))?.effects, ['retainEnd']);
  assert.equal(selectTransition(table, 'reporting', 'admitted', new Set(['always', 'retainedEnd', 'retainedEndPreview']))?.to, 'previewing');
  assert.equal(selectTransition(table, 'reporting', 'admitted', new Set(['always', 'retainedEnd']))?.to, 'ending');
  assert.equal(selectTransition(table, 'reporting', 'admitted', new Set(['noRetainedEnd']))?.to, 'ringing');
  assert.deepEqual(selectTransition(table, 'ringing', 'claimExpired', new Set(['notReconciled']))?.effects, ['emitObservation', 'reconcile']);
  const states: readonly (State | 'absent')[] = ['absent', 'reporting', 'ringing', 'previewing', 'placing',
    'dialing', 'connecting', 'connected', 'reconnecting', 'ending', 'ended'];
  for (const state of states) {
    const stale = selectTransition(table, state, 'authorityAllowed', new Set(['staleAttempt']));
    assert.equal(stale?.to, 'same');
    assert.deepEqual(stale?.effects, ['releasePermit']);
  }
});

test('server-only End reports the original reason without borrowing a performed receipt', () => {
  const callID = validTypeFixtures.endedReceipt.value.receipt.callID;
  const expected = { kind: 'endResult', callID, result: validTypeFixtures.alreadyEnded.value } as const;
  const before = { callID, result: validTypeFixtures.endedReceipt.value };
  const after = { callID, result: validTypeFixtures.alreadyEnded.value };
  check(expected, { ...complete, endResults: [before, after] });
  assert.throws(() => check(expected, { ...complete, endResults: [after, before] }));
  assert.throws(() => check(expected, complete), /Missing End result/);
  assert.deepEqual(selectTransition(table, 'ended', 'localEnd', new Set(['always']))?.effects, ['returnAlreadyEnded']);
  assert.deepEqual(selectTransition(table, 'ended', 'localEnd', new Set(['always', 'hasLocalEndReceipt']))?.effects, ['returnOriginalEnd']);
});
