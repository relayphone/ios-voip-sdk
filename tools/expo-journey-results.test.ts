import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertExpoJournal, assertJavaScriptResults } from './expo-journey-results.ts';

const steps = ['incoming:ringing', 'incoming:connected', 'incoming:held', 'outgoing:connected',
  'preview:previewing', 'preview:connected', 'elsewhere:ringing', 'elsewhere:previewing', 'filtered:previewing'];
const result = () => ({ schemaVersion: 1, runID: 'run', stage: 'passed',
  completed: ['incoming', 'outgoing', 'preview', 'elsewhere', 'filtered'],
  snapshots: steps.map(step => {
    const [name, status] = step.split(':');
    return { step, id: `run-${name}`, status, direction: name === 'outgoing' ? 'outgoing' : 'incoming',
      ...(status === 'previewing' ? { previewReason: name === 'elsewhere' ? 'answeredElsewhere' : 'filtered',
        ...(name !== 'elsewhere' ? { filterCause: 'doNotDisturb' } : {}) } : {}) };
  }),
  handlers: [{ kind: 'start', id: 'run-outgoing', origin: 'app' }, { kind: 'join', id: 'run-preview', origin: 'app' }],
  actions: ['incoming:answer', 'incoming:hold', 'incoming:end', 'outgoing:start', 'outgoing:end', 'preview:join', 'preview:end']
    .map(action => { const [name, kind] = action.split(':'); return { id: `run-${name}`, kind, origin: 'app' }; }),
  outcomes: ['incoming', 'preview', 'elsewhere', 'filtered'].map(name => ({
    id: `run-${name}`, eventID: `run-${name}-push`, status: ['preview', 'filtered'].includes(name) ? 'previewed' : 'reported',
    ...(['preview', 'filtered'].includes(name) ? { previewReason: 'filtered', filterCause: 'doNotDisturb' } : {}),
  })),
  elsewhere: [{ conversationId: 'run-elsewhere', serverCallId: 'run-elsewhere', eventId: 'run-elsewhere-answered' }],
});
const facts = [
  { event: 'runtime.installed' },
  { event: 'push.received', mustReport: true },
  { event: 'report.incoming', callUUID: 'incoming', code: 0 },
  { event: 'call.changed', uuid: 'incoming', handle: 'run-incoming', ringing: true },
  { event: 'action.settled', callUUID: 'incoming', kind: 'answer', fulfilled: true },
  { event: 'call.changed', uuid: 'incoming', connected: true },
  { event: 'action.settled', callUUID: 'incoming', kind: 'hold', held: true, fulfilled: true },
  { event: 'call.changed', uuid: 'incoming', connected: true, held: true },
  { event: 'action.settled', callUUID: 'incoming', kind: 'end', fulfilled: true },
  { event: 'call.changed', uuid: 'incoming', ended: true },
  { event: 'action.settled', callUUID: 'outgoing', kind: 'start', fulfilled: true },
  { event: 'call.changed', uuid: 'outgoing', handle: 'run-outgoing', outgoing: true, connected: true },
  { event: 'action.settled', callUUID: 'outgoing', kind: 'end', fulfilled: true },
  { event: 'call.changed', uuid: 'outgoing', ended: true },
  { event: 'incomingFilter.configured', reason: 'do-not-disturb' },
  { event: 'push.received', mustReport: true },
  { event: 'report.incoming', callUUID: 'preview', code: 3, filterReason: 'do-not-disturb' },
  { event: 'action.settled', callUUID: 'preview', kind: 'start', fulfilled: true },
  { event: 'call.changed', uuid: 'preview', connected: true },
  { event: 'action.settled', callUUID: 'preview', kind: 'end', fulfilled: true },
  { event: 'call.changed', uuid: 'preview', ended: true },
  { event: 'incomingFilter.configured', reason: 'none' },
  { event: 'push.received', mustReport: true },
  { event: 'report.incoming', callUUID: 'elsewhere', code: 0 },
  { event: 'call.changed', uuid: 'elsewhere', handle: 'run-elsewhere', ringing: true },
  { event: 'push.received', mustReport: false },
  { event: 'report.ended', callUUID: 'elsewhere' },
  { event: 'call.changed', uuid: 'elsewhere', ended: true },
  { event: 'incomingFilter.configured', reason: 'do-not-disturb' },
  { event: 'push.received', mustReport: true },
  { event: 'report.incoming', callUUID: 'filtered', code: 3, filterReason: 'do-not-disturb' },
];
const journal = (rows: readonly object[] = facts) => rows.map((row, index) => JSON.stringify({
  schemaVersion: 1, runID: 'runtime-run', pid: 123, bundleID: 'com.example.voipconversations', profile: 'ios-27.0', sequence: index + 1,
  ...row,
})).join('\n');

test('accepts the five JavaScript journeys and matching ordered runtime evidence', () => {
  assertJavaScriptResults(result(), 'run');
  assertExpoJournal(journal(), 'run');
});
test('rejects stale, incomplete and failed app results', () => {
  for (const replacement of [{ runID: 'stale' }, { stage: 'failed' }, { completed: [] }, { snapshots: [] }, { handlers: [] },
    { handlers: [...result().handlers, { kind: 'join', id: 'run-incoming', origin: 'app' }] }, { actions: [] }, { outcomes: [] }, { elsewhere: [] }]) {
    assert.throws(() => assertJavaScriptResults({ ...result(), ...replacement }, 'run'));
  }
});
test('rejects a wrong preview reason or identity even with the expected completion labels', () => {
  assert.throws(() => assertJavaScriptResults({ ...result(), snapshots: result().snapshots.map(row => ({ ...row, id: 'wrong' })) }, 'run'));
  assert.throws(() => assertJavaScriptResults({ ...result(), snapshots: result().snapshots.map(row => ({ ...row, previewReason: 'policy' })) }, 'run'));
});
test('every required journal fact is necessary; failed actions and filtered calls must never connect', () => {
  for (let i = 0; i < facts.length; i++) {
    assert.throws(() => assertExpoJournal(journal(facts.filter((_, index) => index !== i)), 'run'), `missing fact ${i}`);
  }
  assert.throws(() => assertExpoJournal(journal(facts.map(row => ({ ...row, fulfilled: false }))), 'run'));
  assert.throws(() => assertExpoJournal(journal([...facts, { event: 'call.changed', uuid: 'filtered', connected: true }]), 'run'));
  assert.throws(() => assertExpoJournal(journal([...facts, { event: 'action.expired' }]), 'run'));
  assert.throws(() => assertExpoJournal(journal([...facts, { event: 'diagnostic.pushReportingViolation' }]), 'run'));
});
test('rejects journal identity changes, invalid sequences and swapped call facts', () => {
  assert.throws(() => assertExpoJournal(journal([...facts, { event: 'other', runID: 'different' }]), 'run'));
  assert.throws(() => assertExpoJournal(journal(facts.map(row => ({ ...row, sequence: 1 }))), 'run'));
  assert.throws(() => assertExpoJournal(journal(facts.map(row => row.event === 'call.changed' ? { ...row, uuid: 'wrong' } : row)), 'run'));
});
