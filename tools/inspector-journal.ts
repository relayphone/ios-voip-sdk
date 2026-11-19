import { isNumber, isRecord, isString } from './json-fields.ts';

export function isInspectorSession(value: unknown): value is {
  schemaVersion: 1; bundleID: string; runID: string; pid?: unknown;
} {
  return isRecord(value) && 'schemaVersion' in value && value.schemaVersion === 1
    && 'bundleID' in value && isString(value.bundleID)
    && 'runID' in value && isString(value.runID) && /^[A-Za-z0-9_-]{1,64}$/.test(value.runID);
}

interface JournalFacts {
  event: unknown;
  code: unknown;
  callUUID: unknown;
  kind: unknown;
  fulfilled: unknown;
  uuid: unknown;
  connected: unknown;
  ended: unknown;
  reason: unknown;
}

/** Validates the ordered facts produced by the Inspector GUI journey. */
export function assertInspectorJournal(journal: string) {
  const rows: JournalFacts[] = [];
  let identity: string | undefined;
  let sequence = 0;
  for (const line of journal.split('\n').filter(line => line.trim())) {
    const row: unknown = JSON.parse(line);
    if (!isRecord(row)) throw new Error('Invalid journal row');
    if (!('schemaVersion' in row) || row.schemaVersion !== 1) throw new Error('Unsupported schemaVersion');
    if (!('runID' in row) || !isString(row.runID) || !('pid' in row) || !Number.isSafeInteger(row.pid)
        || !('bundleID' in row) || !isString(row.bundleID)
        || !('profile' in row) || !isString(row.profile)) throw new Error('Journal identity mismatch');
    const current = JSON.stringify([row.runID, row.pid, row.bundleID, row.profile]);
    if (identity !== undefined && identity !== current) throw new Error('Journal identity mismatch');
    if (!('sequence' in row) || !isNumber(row.sequence) || !Number.isSafeInteger(row.sequence) || row.sequence <= sequence) {
      throw new Error('Journal sequence out of order');
    }
    identity = current;
    sequence = row.sequence;
    rows.push({
      event: 'event' in row ? row.event : undefined,
      code: 'code' in row ? row.code : undefined,
      callUUID: 'callUUID' in row ? row.callUUID : undefined,
      kind: 'kind' in row ? row.kind : undefined,
      fulfilled: 'fulfilled' in row ? row.fulfilled : undefined,
      uuid: 'uuid' in row ? row.uuid : undefined,
      connected: 'connected' in row ? row.connected : undefined,
      ended: 'ended' in row ? row.ended : undefined,
      reason: 'reason' in row ? row.reason : undefined,
    });
  }
  let cursor = 0;
  const next = (description: string, event: string, matches: (row: JournalFacts) => boolean) => {
    const index = rows.findIndex((row, index) => index >= cursor && row.event === event && matches(row));
    const row = rows[index];
    if (!row) throw new Error(`Missing or out-of-order ${description}`);
    cursor = index + 1;
    return row;
  };
  const report = next('incoming report', 'report.incoming', row => row.code === 0);
  const call = report.callUUID;
  if (!isString(call) || !call) throw new Error('Report has no callUUID');
  const settled = (row: JournalFacts, kind: 'answer' | 'end') =>
    row.kind === kind && row.callUUID === call && row.fulfilled === true;
  next('answer settlement', 'action.settled', row => settled(row, 'answer'));
  next('connected call', 'call.changed', row =>
    row.uuid === call && row.connected === true);
  next('end settlement', 'action.settled', row => settled(row, 'end'));
  next('ended call', 'call.changed', row =>
    row.uuid === call && row.ended === true);
  next('filter confirmation', 'incomingFilter.configured', row =>
    row.reason === 'do-not-disturb');
}
