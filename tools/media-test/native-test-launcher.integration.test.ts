import assert from 'node:assert/strict';
import { test } from 'node:test';
import { join } from 'node:path';
import { runNativeTests } from './run-native-tests.ts';

test('native failure, a stalled test and the following test preserve process isolation', {
  skip: !process.env.NATIVE_LAUNCHER_SPEC,
  timeout: 60_000,
}, async () => {
  const specification = process.env.NATIVE_LAUNCHER_SPEC!, simulator = process.env.NATIVE_LAUNCHER_SIMULATOR!;
  const host = process.env.NATIVE_LAUNCHER_HOST!, directory = process.env.NATIVE_LAUNCHER_DIRECTORY!;
  const original = process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL;
  try {
    for (const mode of ['failure', 'hang', 'success']) {
      process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL = mode;
      const result = await runNativeTests({ specification, simulator, host,
        directory: join(directory, mode), timeoutMS: mode === 'hang' ? 10_000 : 15_000,
        only: 'VoIPMediaTestingTests.NativeLauncherControls' });
      assert.ok(result.log.includes(`NATIVE_LAUNCHER_CONTROL ${mode}`), 'Control must actually reach native execution');
      assert.equal(result.clean, true);
      assert.equal(result.success, mode === 'success');
      if (mode === 'failure') { assert.equal(result.reason, 'exit'); assert.notEqual(result.code, 0); }
      if (mode === 'hang') { assert.equal(result.reason, 'timeout'); assert.ok(result.elapsedMS < 12_000); }
    }
  } finally {
    if (original === undefined) delete process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL;
    else process.env.SIMCTL_CHILD_NATIVE_LAUNCHER_CONTROL = original;
  }
});
