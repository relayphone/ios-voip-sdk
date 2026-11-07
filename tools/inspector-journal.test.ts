import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertInspectorJournal } from './inspector-journal.ts';

const facts = [
  { event: 'report.incoming', callUUID: 'call', code: 0 },
  { event: 'action.settled', callUUID: 'call', kind: 'answer', fulfilled: true },
  { event: 'call.changed', uuid: 'call', connected: true },
  { event: 'action.settled', callUUID: 'call', kind: 'end', fulfilled: true },
  { event: 'call.changed', uuid: 'call', ended: true },
  { event: 'incomingFilter.configured', reason: 'do-not-disturb' },
];
const journal = (rows: readonly object[], extra = {}) => rows.map((row, index) => JSON.stringify({
  schemaVersion: 1, sequence: index + 1, runID: 'run', pid: 123, bundleID: 'app', profile: 'device',
  ...row, ...extra,
})).join('\n');

test('accepts ordered facts with additive fields and events', () => {
  assertInspectorJournal(journal(facts.flatMap(row => [{ event: 'future.event' }, { ...row, future: 1 }])));
});
test('rejects a missing event', () => {
  assert.throws(() => assertInspectorJournal(journal(facts.filter((_, i) => i !== 2))), /connected call/);
});
test('rejects out-of-order facts even when sequences are ordered', () => {
  assert.throws(() => assertInspectorJournal(journal([facts[1]!, facts[0]!, ...facts.slice(2)])), /answer settlement/);
});
test('rejects unsupported schemaVersion', () => {
  assert.throws(() => assertInspectorJournal(journal(facts, { schemaVersion: 2 })), /schemaVersion/);
});
test('rejects identity changes and sequence regression', () => {
  assert.throws(() => assertInspectorJournal(journal(facts) + '\n' + journal(facts, { runID: 'other' })), /identity/);
  assert.throws(() => assertInspectorJournal(journal(facts, { sequence: 1 })), /sequence/);
});
test('rejects failed actions and facts about another call', () => {
  assert.throws(() => assertInspectorJournal(journal(facts.map(row => ({ ...row, fulfilled: false })))), /settlement/);
  assert.throws(() => assertInspectorJournal(journal(facts.map((row, i) => i === 2 ? { ...row, uuid: 'other' } : row))), /connected/);
});
