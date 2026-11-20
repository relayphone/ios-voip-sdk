import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertExpoJournal, assertJavaScriptResults } from './expo-journey-results.ts';

const steps = ['incoming:ringing', 'incoming:connected', 'incoming:held', 'outgoing:connected',
  'preview:previewing', 'preview:connected', 'elsewhere:ringing', 'elsewhere:previewing', 'filtered:previewing'];
const result = () => ({ schemaVersion: 1, runID: 'run', stage: 'passed',
  completed: ['incoming', 'outgoing', 'preview', 'elsewhere', 'filtered'],
  snapshots: steps.map(step => {
    const [name, status] = step.split(':');
    const snapshot = { step, id: `run-${name}`, status, direction: name === 'outgoing' ? 'outgoing' : 'incoming' };
    if (status !== 'previewing') return snapshot;
    if (name === 'elsewhere') return { ...snapshot, previewReason: 'answeredElsewhere' };
    return { ...snapshot, previewReason: 'filtered', filterCause: 'doNotDisturb' };
  }),
  handlers: [{ kind: 'start', id: 'run-outgoing', origin: 'app' }, { kind: 'join', id: 'run-preview', origin: 'app' }],
  actions: ['incoming:answer', 'incoming:hold', 'incoming:end', 'outgoing:start', 'outgoing:end', 'preview:join', 'preview:end']
    .map(action => { const [name, kind] = action.split(':'); return { id: `run-${name}`, kind, origin: 'app' }; }),
  outcomes: ['incoming', 'preview', 'elsewhere', 'filtered'].map(name => {
    const identity = { id: `run-${name}`, eventID: `run-${name}-push` };
    return name === 'preview' || name === 'filtered'
      ? { ...identity, status: 'previewed', previewReason: 'filtered', filterCause: 'doNotDisturb' }
      : { ...identity, status: 'reported' };
  }),
  elsewhere: [{ conversationId: 'run-elsewhere', serverCallId: 'run-elsewhere', eventId: 'run-elsewhere-answered' }],
});
interface JournalFact {
  event: string;
  runID?: string;
  sequence?: number;
  callUUID?: string;
  uuid?: string;
  handle?: string;
  kind?: string;
  reason?: string;
  filterReason?: string;
  code?: number;
  mustReport?: boolean;
  fulfilled?: boolean;
  ringing?: boolean;
  connected?: boolean;
  held?: boolean;
  ended?: boolean;
  outgoing?: boolean;
}

const facts: readonly JournalFact[] = [
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
// Fixed vectors from the SDK's public deviceUUID(for:) mapping for run-<name>.
const systemUUIDs = new Map([
  ['incoming', '18B2E95A-B69B-847A-BE6F-1327665424E9'],
  ['outgoing', '584FD139-138F-8291-BC7C-C4D58B26B31E'],
  ['preview', '66C3D439-09B3-8427-BC9E-A9F41D007908'],
  ['elsewhere', '6743C347-097A-82C4-9888-2AC2848652BE'],
  ['filtered', 'B41A8F37-2DA7-89CC-B2A6-1ABD9E2EFD60'],
]);
const journal = (rows: readonly JournalFact[] = facts) => rows.map((row, index) => {
  const event = {
    schemaVersion: 1, runID: 'runtime-run', pid: 123, bundleID: 'com.example.voipconversations',
    profile: 'ios-27.0', sequence: index + 1, ...row,
  };
  if (row.callUUID !== undefined) event.callUUID = systemUUIDs.get(row.callUUID) ?? row.callUUID;
  if (row.uuid !== undefined) event.uuid = systemUUIDs.get(row.uuid) ?? row.uuid;
  return JSON.stringify(event);
}).join('\n');

test('accepts the five JavaScript journeys and matching ordered runtime evidence', () => {
  assertJavaScriptResults(result(), 'run');
  assertExpoJournal(journal(), 'run');
});
test('LiveCommunicationKit journal identities use device UUIDs even when caller handles are empty', () => {
  assertExpoJournal(journal(facts.map(row => row.event === 'call.changed' ? { ...row, handle: '' } : row)), 'run');
});
test('rejects a consistently substituted system UUID for every journey, even with matching caller handles', () => {
  for (const name of systemUUIDs.keys()) {
    const foreignUUID = '00000000-0000-8000-8000-000000000000';
    const substituted = facts.map(row => {
      const event = { ...row };
      if (row.callUUID === name) event.callUUID = foreignUUID;
      if (row.uuid === name) event.uuid = foreignUUID;
      return event;
    });
    assert.throws(() => assertExpoJournal(journal(substituted), 'run'), `substituted ${name} UUID`);
  }
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

test('accepts observation order when runtime writer sequences arrive out of order', () => {
  const sequenced = facts.map((row, index) => ({ ...row, sequence: index + 1 }));
  const fourth = sequenced[3];
  const fifth = sequenced[4];
  assert.ok(fourth && fifth);
  fourth.sequence = 5;
  fifth.sequence = 4;
  assertExpoJournal(journal(sequenced), 'run');
});

test('rejects missing, duplicate, fractional and nonpositive writer sequences', () => {
  for (const sequence of [0, -1, 1.5, 2, facts.length + 1]) {
    assert.throws(() => assertExpoJournal(journal(facts.map((row, index) =>
      index === 0 ? { ...row, sequence } : row)), 'run'));
  }
});
