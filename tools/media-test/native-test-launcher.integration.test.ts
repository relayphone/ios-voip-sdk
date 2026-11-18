import assert from 'node:assert/strict';
import { test } from 'node:test';
import { join } from 'node:path';
import { runNativeTests } from './run-native-tests.ts';

test('native failure, a stalled test and the following test preserve process isolation', {
  skip: !process.env.NATIVE_LAUNCHER_SPEC,
  timeout: 180_000,
}, async () => {
  const specification = process.env.NATIVE_LAUNCHER_SPEC!, simulator = process.env.NATIVE_LAUNCHER_SIMULATOR!;
  const host = process.env.NATIVE_LAUNCHER_HOST!, directory = process.env.NATIVE_LAUNCHER_DIRECTORY!;
  const original = process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL;
  try {
    for (const mode of ['failure', 'hang', 'success']) {
      process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL = mode;
      const marker = `NATIVE_LAUNCHER_CONTROL ${mode}`;
      const result = await runNativeTests({ specification, simulator, host,
        directory: join(directory, mode), timeoutMS: mode === 'hang' ? 10_000 : 15_000,
        readiness: { line: marker, timeoutMS: 35_000 },
        only: 'VoIPMediaTestingTests.NativeLauncherControls' });
      const diagnostic = `mode=${mode}, reason=${result.reason}, nativePID=${result.nativePID === undefined ? 'absent' : 'present'}, ` +
        `code=${result.code}, signal=${result.signal}, clean=${result.clean}, cleanupErrors=${result.cleanupErrors.join(',') || 'none'}, ` +
        `readyMS=${result.readyElapsedMS?.toFixed(0) ?? 'absent'}, processMS=${result.processElapsedMS.toFixed(0)}, ` +
        `totalMS=${result.elapsedMS.toFixed(0)}`;
      assert.ok(result.readyElapsedMS !== undefined, `Control must actually reach native execution (${diagnostic})`);
      assert.equal(result.clean, true, diagnostic);
      assert.equal(result.success, mode === 'success', diagnostic);
      if (mode === 'failure') {
        assert.equal(result.reason, 'exit', diagnostic);
        assert.notEqual(result.code, 0, diagnostic);
        assert.equal(result.signal, null, diagnostic);
      }
      if (mode === 'hang') {
        assert.equal(result.reason, 'timeout', diagnostic);
        assert.ok(result.elapsedMS - result.readyElapsedMS < 12_000, diagnostic);
      }
    }
  } finally {
    if (original === undefined) delete process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL;
    else process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL = original;
  }
});
