import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeUnobservedResult } from './result-receipt.ts';

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
