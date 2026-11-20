import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { isList, isRecord, isString } from './json-fields.ts';
import { journeyIDs } from '../expo/example/client/journeys/results.ts';

function fields(value: unknown) {
  assert.ok(isRecord(value), 'Expected an object');
  return new Map<string, unknown>(Object.entries(value));
}
function rows(value: unknown) {
  assert.ok(isList(value), 'Expected an array');
  return value.map(fields);
}

/** The SDK's deviceUUID(for:) contract: SHA-256 prefix with UUID version 8 and RFC variant bits. */
function deviceUUID(id: string) {
  const bytes = createHash('sha256').update(id, 'utf8').digest().subarray(0, 16);
  bytes.writeUInt8((bytes.readUInt8(6) & 0x0f) | 0x80, 6);
  bytes.writeUInt8((bytes.readUInt8(8) & 0x3f) | 0x80, 8);
  const hex = bytes.toString('hex').toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Checks observable JS state, placement callbacks and native events, independently of completion labels. */
export function assertJavaScriptResults(value: unknown, runID: string) {
  const result = fields(value);
  const ids = journeyIDs(runID);
  assert.equal(result.get('schemaVersion'), 1);
  assert.equal(result.get('runID'), runID, 'Stale app results');
  assert.equal(result.get('stage'), 'passed', String(result.get('failure') ?? 'Incomplete JavaScript journeys'));
  assert.equal(result.get('failure'), undefined);
  assert.deepEqual(result.get('completed'), ['incoming', 'outgoing', 'preview', 'elsewhere', 'filtered']);
  const expected = ['incoming:ringing', 'incoming:connected', 'incoming:held', 'outgoing:connected',
    'preview:previewing', 'preview:connected', 'elsewhere:ringing', 'elsewhere:previewing', 'filtered:previewing'];
  assert.deepEqual(rows(result.get('snapshots')).map(row => [row.get('step'), row.get('id'), row.get('status'), row.get('direction')]),
    expected.map(step => { const [name, status] = step.split(':');
      return [step, `${runID}-${name}`, status, name === 'outgoing' ? 'outgoing' : 'incoming']; }));
  for (const row of rows(result.get('snapshots')).filter(row => row.get('status') === 'previewing')) {
    assert.equal(row.get('previewReason'), row.get('id') === ids.elsewhere ? 'answeredElsewhere' : 'filtered');
    if (row.get('id') !== ids.elsewhere) assert.equal(row.get('filterCause'), 'doNotDisturb');
  }
  assert.deepEqual(result.get('handlers'), [
    { kind: 'start', id: ids.outgoing, origin: 'app' }, { kind: 'join', id: ids.preview, origin: 'app' },
  ], 'Only start and preview join may consult a handler');
  const actions = rows(result.get('actions'));
  let cursor = 0;
  for (const action of ['incoming:answer', 'incoming:hold', 'incoming:end', 'outgoing:start', 'outgoing:end', 'preview:join', 'preview:end']) {
    const [name, kind] = action.split(':');
    const index = actions.findIndex((row, i) => i >= cursor && row.get('id') === `${runID}-${name}` && row.get('kind') === kind && row.get('origin') === 'app');
    assert.ok(index >= 0, `Missing JS action event ${action}`);
    cursor = index + 1;
  }
  const outcomes = ['incoming', 'preview', 'elsewhere', 'filtered'].map(name => {
    const identity = { id: `${runID}-${name}`, eventID: `${runID}-${name}-push` };
    if (name === 'preview' || name === 'filtered') {
      return { ...identity, status: 'previewed', previewReason: 'filtered', filterCause: 'doNotDisturb' };
    }
    return { ...identity, status: 'reported' };
  });
  assert.deepEqual(result.get('outcomes'), outcomes);
  assert.deepEqual(result.get('elsewhere'), [{ conversationId: ids.elsewhere, serverCallId: ids.elsewhere, eventId: `${ids.elsewhere}-answered` }]);
}

/** Requires ordered system-side evidence for the same calls as the app's results. */
export function assertExpoJournal(journal: string, runID: string) {
  const events = journal.split('\n').filter(line => line.trim()).map(line => fields(JSON.parse(line)));
  let identity: string | undefined;
  const sequences: number[] = [];
  for (const row of events) {
    assert.equal(row.get('schemaVersion'), 1);
    assert.equal(row.get('bundleID'), 'com.example.voipconversations');
    assert.ok(isString(row.get('runID')), 'Invalid journal run ID');
    assert.ok(Number.isSafeInteger(row.get('pid')));
    assert.equal(row.get('profile'), 'ios-27.0');
    const current = JSON.stringify([row.get('runID'), row.get('pid'), row.get('bundleID'), row.get('profile')]);
    assert.ok(identity === undefined || identity === current, 'Journal identity changed');
    assert.ok(Number.isSafeInteger(row.get('sequence')) && Number(row.get('sequence')) > 0, 'Invalid journal sequence');
    sequences.push(Number(row.get('sequence')));
    identity = current;
    assert.ok(!['action.expired', 'action.timeout', 'diagnostic.pushReportingViolation', 'diagnostic.pushReportExpired']
      .includes(String(row.get('event'))), `Unexpected ${row.get('event')}`);
    if (row.get('event') === 'action.settled') assert.equal(row.get('fulfilled'), true, 'An action failed');
  }
  // The merged timeline orders source observations by uptime. An observation can reach
  // the runtime writer after a later observation, so writer sequence need not be time order.
  assert.deepEqual(sequences.toSorted((a, b) => a - b),
    sequences.map((_, index) => index + 1), 'Missing or duplicate journal sequence');
  const reports = events.filter(row => row.get('event') === 'report.incoming');
  assert.deepEqual(reports.map(row => row.get('code')), [0, 3, 0, 3]);
  const incoming = deviceUUID(`${runID}-incoming`);
  const preview = deviceUUID(`${runID}-preview`);
  const elsewhere = deviceUUID(`${runID}-elsewhere`);
  const filtered = deviceUUID(`${runID}-filtered`);
  const observedUUIDs = reports.map(row => row.get('callUUID'));
  assert.deepEqual(observedUUIDs, [incoming, preview, elsewhere, filtered], 'Incoming journal UUIDs must name the JavaScript calls');
  assert.equal(new Set(observedUUIDs).size, 4);
  assert.deepEqual(events.filter(row => row.get('event') === 'push.received').map(row => row.get('mustReport')), [true, true, true, false, true]);
  let cursor = 0;
  const next = (label: string, matches: (row: ReadonlyMap<string, unknown>) => boolean) => {
    const index = events.findIndex((row, index) => index >= cursor && matches(row));
    const row = events[index];
    assert.ok(row, `Missing or out-of-order ${label}`);
    cursor = index + 1;
    return row;
  };
  const event = (name: string) => next(name, row => row.get('event') === name);
  const settled = (call: string, kind: string) => next(`${kind} settlement`, row => row.get('event') === 'action.settled'
    && row.get('callUUID') === call && row.get('kind') === kind && row.get('fulfilled') === true && (kind !== 'hold' || row.get('held') === true));
  const changed = (call: string, state: 'ringing' | 'connected' | 'held' | 'ended') => next(state, row => row.get('event') === 'call.changed' && row.get('uuid') === call && row.get(state) === true);
  const report = (call: string) => next('incoming report', row => row.get('event') === 'report.incoming' && row.get('callUUID') === call);
  const filter = (reason: string) => next(`filter ${reason}`, row => row.get('event') === 'incomingFilter.configured' && row.get('reason') === reason);
  event('runtime.installed'); event('push.received'); report(incoming);
  changed(incoming, 'ringing');
  settled(incoming, 'answer'); changed(incoming, 'connected');
  settled(incoming, 'hold'); changed(incoming, 'held');
  settled(incoming, 'end'); changed(incoming, 'ended');
  const outgoing = deviceUUID(`${runID}-outgoing`);
  const start = next('outgoing start', row => row.get('event') === 'action.settled' && row.get('kind') === 'start');
  assert.equal(start.get('callUUID'), outgoing, 'Outgoing journal UUID must name the JavaScript call');
  assert.ok(!observedUUIDs.includes(outgoing), 'Outgoing call identity collided');
  assert.equal(changed(outgoing, 'connected').get('outgoing'), true);
  settled(outgoing, 'end'); changed(outgoing, 'ended');
  filter('do-not-disturb'); event('push.received'); report(preview);
  settled(preview, 'start'); changed(preview, 'connected'); settled(preview, 'end'); changed(preview, 'ended');
  filter('none');
  event('push.received'); report(elsewhere);
  changed(elsewhere, 'ringing');
  event('push.received'); next('server end', row => row.get('event') === 'report.ended' && row.get('callUUID') === elsewhere);
  changed(elsewhere, 'ended');
  filter('do-not-disturb'); event('push.received'); report(filtered);
  assert.ok(!events.some(row => row.get('event') === 'call.changed' && row.get('uuid') === filtered), 'Filtered call entered system state');
}
