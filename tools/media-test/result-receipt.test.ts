import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { assertNativePassed, assertNativeTeardown, writeUnobservedResult } from './result-receipt.ts';

test('deadline exhaustion retains completed and unfinished attempts when final native report is absent', () => {
  const directory = mkdtempSync(join(tmpdir(), 'silence-receipt-'));
  try {
    const checkpoint = join(directory, 'checkpoint.json'), output = join(directory, 'result.json');
    const native = { windows: [{ verdict: 'unobserved', gaps: [{ lengthMs: 389 }] }],
      activeWindow: { verdict: 'unobserved', startSeconds: 2, endSeconds: 2 }, deadlineSeconds: 3 };
    writeFileSync(checkpoint, JSON.stringify(native));
    writeUnobservedResult(output, 30000, { silenceWindows: [{ verdict: 'unobserved' }] }, checkpoint);
    const result = JSON.parse(readFileSync(output, 'utf8'));
    assert.equal(result.verdict, 'unobserved'); assert.deepEqual(result.nativeSilence, native);
    assert.equal(result.nativeFinalReportAvailable, false);
    writeFileSync(checkpoint, '{partial');
    writeUnobservedResult(output, 30000, {}, checkpoint);
    assert.equal(JSON.parse(readFileSync(output, 'utf8')).nativeSilence.reason, 'checkpoint-unavailable');
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('the native processing failure is reported before a subsequent marker rejection', () => {
  let markersRead = false;
  assert.throws(() => {
    assertNativePassed({ passed: false, phase: 'captureProcessing', processing: {} });
    markersRead = true;
    assert.fail('marker failure');
  }, /Native media check failed at captureProcessing/);
  assert.equal(markersRead, false);
  assert.doesNotThrow(() => assertNativePassed({ passed: true }));
  for (const value of [null, {}, { passed: 'true' }]) {
    assert.throws(() => assertNativePassed(value), /Native media check failed at unavailable/);
  }
});

test('all four measured native release events must use one ordered clock interval', () => {
  const events = ['tapUninstalled', 'roomDisconnected', 'engineStopped', 'audioSessionReleased'];
  const receipt = { clockID: '7ff6b8a0-0d99-49d1-bb5e-450bf6173543', startedAtMs: 10, observedAtMs: 100,
    observations: events.map((event, index) => ({ event, atMs: 20 + index * 10 })) };
  assert.doesNotThrow(() => assertNativeTeardown(receipt));
  for (const event of events) assert.throws(() => assertNativeTeardown({ ...receipt,
    observations: receipt.observations.filter(row => row.event !== event), complete: true }));
  for (const changed of [{ clockID: '' }, { startedAtMs: NaN }, { observedAtMs: 9 },
    { observations: receipt.observations.map(row => ({ ...row, atMs: 101 })) },
    { observations: receipt.observations.map(row => ({ ...row, event: 'tapUninstalled' })) },
    { observations: receipt.observations.toReversed() }])
    assert.throws(() => assertNativeTeardown({ ...receipt, ...changed }));
});

test('terminal binding rejects foreign clocks, replayed attempts and late release events', () => {
  const clockID = '7ff6b8a0-0d99-49d1-bb5e-450bf6173543';
  const expected = { clockID, startedAtMs: 10, deadlineMs: 50 };
  const receipt = { clockID, startedAtMs: 10, observedAtMs: 100,
    observations: ['tapUninstalled', 'engineStopped', 'roomDisconnected', 'audioSessionReleased']
      .map((event, index) => ({ event, atMs: 20 + index * 10 })) };
  // A delayed snapshot still proves events observed by the deadline, including its boundary.
  assert.doesNotThrow(() => assertNativeTeardown(receipt, expected));
  assert.throws(() => assertNativeTeardown({ ...receipt,
    clockID: 'a9aa1c90-cc38-4058-a8e7-d30f215763de' }, expected), /Foreign teardown clock/);
  assert.throws(() => assertNativeTeardown({ ...receipt, startedAtMs: 9 }, expected), /Stale teardown attempt/);
  assert.throws(() => assertNativeTeardown({ ...receipt,
    observations: receipt.observations.map(row => ({ ...row, atMs: row.atMs + 1 })) }, expected),
    /exceeded terminal deadline/);
  for (const invalid of [{ startedAtMs: NaN }, { startedAtMs: -1 },
    { deadlineMs: Infinity }, { deadlineMs: 9 }]) {
    assert.throws(() => assertNativeTeardown(receipt, { ...expected, ...invalid }));
  }
});
