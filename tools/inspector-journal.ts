/** Validates the ordered facts produced by the Inspector GUI journey. */
export function assertInspectorJournal(journal: string): void {
  const rows: Record<string, unknown>[] = [];
  let identity: string | undefined;
  let sequence = 0;
  for (const line of journal.split('\n').filter(line => line.trim())) {
    const row: unknown = JSON.parse(line);
    if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('Invalid journal row');
    const event = row as Record<string, unknown>;
    if (event.schemaVersion !== 1) throw new Error('Unsupported schemaVersion');
    const current = JSON.stringify([event.runID, event.pid, event.bundleID, event.profile]);
    if (typeof event.runID !== 'string' || !Number.isSafeInteger(event.pid)
        || typeof event.bundleID !== 'string' || typeof event.profile !== 'string'
        || (identity !== undefined && identity !== current)) throw new Error('Journal identity mismatch');
    if (!Number.isSafeInteger(event.sequence) || Number(event.sequence) <= sequence) {
      throw new Error('Journal sequence out of order');
    }
    identity = current;
    sequence = Number(event.sequence);
    rows.push(event);
  }
  let cursor = 0;
  const next = (description: string, matches: (row: Record<string, unknown>) => boolean) => {
    const index = rows.findIndex((row, index) => index >= cursor && matches(row));
    if (index < 0) throw new Error(`Missing or out-of-order ${description}`);
    cursor = index + 1;
    return rows[index]!;
  };
  const report = next('incoming report', row => row.event === 'report.incoming' && row.code === 0);
  const call = report.callUUID;
  if (typeof call !== 'string' || !call) throw new Error('Report has no callUUID');
  next('answer settlement', row => row.event === 'action.settled' && row.kind === 'answer'
    && row.callUUID === call && row.fulfilled === true);
  next('connected call', row => row.event === 'call.changed' && row.uuid === call && row.connected === true);
  next('end settlement', row => row.event === 'action.settled' && row.kind === 'end'
    && row.callUUID === call && row.fulfilled === true);
  next('ended call', row => row.event === 'call.changed' && row.uuid === call && row.ended === true);
  next('filter confirmation', row => row.event === 'incomingFilter.configured' && row.reason === 'do-not-disturb');
}
