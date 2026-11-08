import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { journeyIDs } from '../expo/example/client/journeys/results.ts';

function object(value: unknown): Record<string, unknown> {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), 'Expected an object');
  return value as Record<string, unknown>;
}
function rows(value: unknown): Record<string, unknown>[] {
  assert.ok(Array.isArray(value), 'Expected an array');
  return value.map(object);
}

/** The SDK's deviceUUID(for:) contract: SHA-256 prefix with UUID version 8 and RFC variant bits. */
function deviceUUID(id: string): string {
  const bytes = createHash('sha256').update(id, 'utf8').digest().subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x80;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString('hex').toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Checks observable JS state, placement callbacks and native events, independently of completion labels. */
export function assertJavaScriptResults(value: unknown, runID: string): void {
  const result = object(value);
  const ids = journeyIDs(runID);
  assert.equal(result.schemaVersion, 1);
  assert.equal(result.runID, runID, 'Stale app results');
  assert.equal(result.stage, 'passed', String(result.failure ?? 'Incomplete JavaScript journeys'));
  assert.equal(result.failure, undefined);
  assert.deepEqual(result.completed, ['incoming', 'outgoing', 'preview', 'elsewhere', 'filtered']);
  const expected = ['incoming:ringing', 'incoming:connected', 'incoming:held', 'outgoing:connected',
    'preview:previewing', 'preview:connected', 'elsewhere:ringing', 'elsewhere:previewing', 'filtered:previewing'];
  assert.deepEqual(rows(result.snapshots).map(row => [row.step, row.id, row.status, row.direction]),
    expected.map(step => { const [name, status] = step.split(':');
      return [step, `${runID}-${name}`, status, name === 'outgoing' ? 'outgoing' : 'incoming']; }));
  for (const row of rows(result.snapshots).filter(row => row.status === 'previewing')) {
    assert.equal(row.previewReason, row.id === ids.elsewhere ? 'answeredElsewhere' : 'filtered');
    if (row.id !== ids.elsewhere) assert.equal(row.filterCause, 'doNotDisturb');
  }
  assert.deepEqual(result.handlers, [
    { kind: 'start', id: ids.outgoing, origin: 'app' }, { kind: 'join', id: ids.preview, origin: 'app' },
  ], 'Only start and preview join may consult a handler');
  const actions = rows(result.actions);
  let cursor = 0;
  for (const action of ['incoming:answer', 'incoming:hold', 'incoming:end', 'outgoing:start', 'outgoing:end', 'preview:join', 'preview:end']) {
    const [name, kind] = action.split(':');
    const index = actions.findIndex((row, i) => i >= cursor && row.id === `${runID}-${name}` && row.kind === kind && row.origin === 'app');
    assert.ok(index >= 0, `Missing JS action event ${action}`);
    cursor = index + 1;
  }
  assert.deepEqual(result.outcomes, ['incoming', 'preview', 'elsewhere', 'filtered'].map(name => ({
    id: `${runID}-${name}`, eventID: `${runID}-${name}-push`, status: ['preview', 'filtered'].includes(name) ? 'previewed' : 'reported',
    ...(['preview', 'filtered'].includes(name) ? { previewReason: 'filtered', filterCause: 'doNotDisturb' } : {}),
  })));
  assert.deepEqual(result.elsewhere, [{ conversationId: ids.elsewhere, serverCallId: ids.elsewhere, eventId: `${ids.elsewhere}-answered` }]);
}

/** Requires ordered system-side evidence for the same calls as the app's results. */
export function assertExpoJournal(journal: string, runID: string): void {
  const events = journal.split('\n').filter(line => line.trim()).map(line => object(JSON.parse(line)));
  let identity: string | undefined;
  let sequence = 0;
  for (const row of events) {
    assert.equal(row.schemaVersion, 1);
    assert.equal(row.bundleID, 'com.example.voipconversations');
    assert.equal(typeof row.runID, 'string');
    assert.ok(Number.isSafeInteger(row.pid));
    assert.equal(row.profile, 'ios-27.0');
    const current = JSON.stringify([row.runID, row.pid, row.bundleID, row.profile]);
    assert.ok(identity === undefined || identity === current, 'Journal identity changed');
    assert.ok(Number.isSafeInteger(row.sequence) && Number(row.sequence) > sequence, 'Invalid journal sequence');
    identity = current; sequence = Number(row.sequence);
    assert.ok(!['action.expired', 'action.timeout', 'diagnostic.pushReportingViolation', 'diagnostic.pushReportExpired']
      .includes(String(row.event)), `Unexpected ${row.event}`);
    if (row.event === 'action.settled') assert.equal(row.fulfilled, true, 'An action failed');
  }
  const reports = events.filter(row => row.event === 'report.incoming');
  assert.deepEqual(reports.map(row => row.code), [0, 3, 0, 3]);
  assert.deepEqual(reports.map(row => row.callUUID), ['incoming', 'preview', 'elsewhere', 'filtered']
    .map(name => deviceUUID(`${runID}-${name}`)), 'Incoming journal UUIDs must name the JavaScript calls');
  const [incoming, preview, elsewhere, filtered] = reports.map(row => row.callUUID);
  assert.ok(reports.every(row => typeof row.callUUID === 'string' && row.callUUID.length > 0));
  assert.equal(new Set(reports.map(row => row.callUUID)).size, 4);
  assert.deepEqual(events.filter(row => row.event === 'push.received').map(row => row.mustReport), [true, true, true, false, true]);
  let cursor = 0;
  const next = (label: string, matches: (row: Record<string, unknown>) => boolean) => {
    const index = events.findIndex((row, index) => index >= cursor && matches(row));
    assert.ok(index >= 0, `Missing or out-of-order ${label}`);
    cursor = index + 1; return events[index]!;
  };
  const event = (name: string) => next(name, row => row.event === name);
  const settled = (call: unknown, kind: string) => next(`${kind} settlement`, row => row.event === 'action.settled'
    && row.callUUID === call && row.kind === kind && row.fulfilled === true && (kind !== 'hold' || row.held === true));
  const changed = (call: unknown, state: string) => next(state, row => row.event === 'call.changed' && row.uuid === call && row[state] === true);
  const report = (call: unknown) => next('incoming report', row => row.event === 'report.incoming' && row.callUUID === call);
  const filter = (reason: string) => next(`filter ${reason}`, row => row.event === 'incomingFilter.configured' && row.reason === reason);
  event('runtime.installed'); event('push.received'); report(incoming);
  changed(incoming, 'ringing');
  settled(incoming, 'answer'); changed(incoming, 'connected');
  settled(incoming, 'hold'); changed(incoming, 'held');
  settled(incoming, 'end'); changed(incoming, 'ended');
  const outgoing = next('outgoing start', row => row.event === 'action.settled' && row.kind === 'start').callUUID;
  assert.equal(outgoing, deviceUUID(`${runID}-outgoing`), 'Outgoing journal UUID must name the JavaScript call');
  assert.ok(typeof outgoing === 'string' && !reports.some(row => row.callUUID === outgoing), 'Outgoing call identity collided');
  assert.equal(changed(outgoing, 'connected').outgoing, true);
  settled(outgoing, 'end'); changed(outgoing, 'ended');
  filter('do-not-disturb'); event('push.received'); report(preview);
  settled(preview, 'start'); changed(preview, 'connected'); settled(preview, 'end'); changed(preview, 'ended');
  filter('none');
  event('push.received'); report(elsewhere);
  changed(elsewhere, 'ringing');
  event('push.received'); next('server end', row => row.event === 'report.ended' && row.callUUID === elsewhere);
  changed(elsewhere, 'ended');
  filter('do-not-disturb'); event('push.received'); report(filtered);
  assert.ok(!events.some(row => row.event === 'call.changed' && row.uuid === filtered), 'Filtered call entered system state');
}
