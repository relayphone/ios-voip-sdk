import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';

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
  assert.ok(report && 'passed' in report && report.passed === true, `Native media check failed at ${phase}`);
}
