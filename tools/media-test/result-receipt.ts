import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { diagnoseNativeStartup } from './startup-diagnostics.ts';

/** Persist failure evidence even when the native observer cannot finish its final report. */
export function writeUnobservedResult<T>(output: string, deadlineMs: number, farEnd: T, checkpoint: string): void {
  let nativeSilence: unknown;
  try { nativeSilence = JSON.parse(readFileSync(checkpoint, 'utf8')); }
  catch { nativeSilence = { verdict: 'unobserved', reason: 'checkpoint-unavailable' }; }
  writeFileSync(output, JSON.stringify({ verdict: 'unobserved', phase: 'example.result',
    deadlineMs, farEnd, nativeSilence, nativeFinalReportAvailable: false }, null, 2));
}

/** Preserve the earliest native failure before evaluating later host marker gates. */
export function assertNativePassed(evidence: unknown): void {
  const report = evidence && typeof evidence === 'object' ? evidence : undefined;
  const phase = report && 'phase' in report && typeof report.phase === 'string' ? report.phase : 'unavailable';
  assert.ok(report && 'passed' in report && report.passed === true,
    `Native media check failed at ${phase}; startup=${diagnoseNativeStartup(evidence).boundary}`);
}

/** Expected native clock and arm acknowledgement for the current terminal phase. */
export interface NativeTeardownExpectation {
  readonly clockID: string;
  readonly startedAtMs: number;
  readonly deadlineMs: number;
}

/** Validate measured release events, optionally binding them to an acknowledged terminal phase. */
export function assertNativeTeardown(value: unknown, expected?: NativeTeardownExpectation): void {
  assert.ok(value && typeof value === 'object', 'Missing native teardown evidence');
  const data = value as Record<string, unknown>;
  assert.ok(typeof data.clockID === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(data.clockID), 'Missing teardown clock');
  assert.ok(typeof data.startedAtMs === 'number' && Number.isFinite(data.startedAtMs) && data.startedAtMs >= 0);
  assert.ok(typeof data.observedAtMs === 'number' && Number.isFinite(data.observedAtMs) && data.observedAtMs >= data.startedAtMs);
  if (expected) {
    assert.ok(Number.isFinite(expected.startedAtMs) && expected.startedAtMs >= 0);
    assert.ok(Number.isFinite(expected.deadlineMs) && expected.deadlineMs >= expected.startedAtMs);
    assert.equal(data.clockID, expected.clockID, 'Foreign teardown clock');
    assert.equal(data.startedAtMs, expected.startedAtMs, 'Stale teardown attempt');
  }
  assert.ok(Array.isArray(data.observations) && data.observations.length === 4, 'Incomplete native teardown');
  const remainingEvents = new Set(['tapUninstalled', 'engineStopped', 'roomDisconnected', 'audioSessionReleased']);
  let previous = data.startedAtMs;
  for (const row of data.observations) {
    assert.ok(row && typeof row === 'object' && remainingEvents.delete(row.event), 'Duplicate or unknown release observation');
    assert.ok(typeof row.atMs === 'number' && Number.isFinite(row.atMs) && row.atMs >= previous && row.atMs <= data.observedAtMs, 'Release observation outside its clock interval');
    if (expected) assert.ok(row.atMs <= expected.deadlineMs, 'Release observation exceeded terminal deadline');
    previous = row.atMs;
  }
  assert.equal(remainingEvents.size, 0, 'Missing release observation');
}
