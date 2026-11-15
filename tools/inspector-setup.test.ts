import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SimulatorSetupFailure, setupInspectorSimulator, transientSetupFailure, type SetupResult } from './inspector-setup.ts';

const success: SetupResult = { status: 0, signal: null, stderr: '' };
const timeout: SetupResult = { status: null, signal: 'SIGKILL', stderr: 'install stalled', errorCode: 'ETIMEDOUT' };
const invalidApp: SetupResult = { status: 149, signal: null, stderr: 'ApplicationVerificationFailed: invalid signature' };

function fixture(reply: (phase: string, attempt: number) => SetupResult = () => success) {
  const calls: { args: readonly string[]; timeoutMS: number }[] = [];
  const reports: string[] = [];
  const delays: number[] = [];
  const counts = new Map<string, number>();
  let elapsed = 0;
  const options = {
    execute(args: readonly string[], timeoutMS: number) {
      calls.push({ args, timeoutMS });
      const phase = args[0]!;
      const attempt = (counts.get(phase) ?? 0) + 1;
      counts.set(phase, attempt);
      return reply(phase, attempt);
    },
    report(message: string) { reports.push(message); },
    async delay(milliseconds: number) { delays.push(milliseconds); elapsed += milliseconds; },
    now: () => elapsed,
  };
  return { calls, reports, delays, options, elapse: (ms: number) => { elapsed += ms; } };
}

test('boot completion gates installation, with bounded commands and each result in the summary', async () => {
  const f = fixture();
  await setupInspectorSimulator('owned', '/app', f.options);
  assert.deepEqual(f.calls.map(c => c.args), [['boot', 'owned'], ['bootstatus', 'owned', '-b'], ['install', 'owned', '/app']]);
  assert.deepEqual(f.calls.map(c => c.timeoutMS), [120_000, 300_000, 90_000]);
  for (const phase of ['boot', 'bootstatus', 'install']) {
    assert.ok(f.reports.some(row => row.includes(`"phase":"${phase}"`) && row.includes('"exitCode":0') && row.includes('"stderr":""')));
  }
});

test('transient installs back off and recheck boot readiness before retrying', async () => {
  const f = fixture((phase, attempt) => phase === 'install' && attempt < 3 ? timeout : success);
  await setupInspectorSimulator('owned', '/app', f.options);
  assert.deepEqual(f.delays, [2000, 5000]);
  assert.deepEqual(f.calls.map(c => c.args[0]), ['boot', 'bootstatus', 'install', 'bootstatus', 'install', 'bootstatus', 'install']);
  assert.equal(f.reports.filter(row => row.includes('"errorCode":"ETIMEDOUT"')).length, 2);
  assert.ok(f.reports.some(row => row.includes('"exitCode":null') && row.includes('"signal":"SIGKILL"') && row.includes('install stalled')));
});

test('unrecognized install failures fail immediately without retry or erase', async () => {
  const f = fixture(phase => phase === 'install' ? invalidApp : success);
  await assert.rejects(setupInspectorSimulator('owned', '/app', f.options),
    error => error instanceof SimulatorSetupFailure && error.phase === 'install' && error.result.status === 149);
  assert.deepEqual(f.delays, []);
  assert.deepEqual(f.calls.map(c => c.args[0]), ['boot', 'bootstatus', 'install']);
  assert.ok(f.reports.some(row => row.includes('ApplicationVerificationFailed')));
});

test('exhausted transient installs erase only the owned device, reboot, then install', async () => {
  const f = fixture((phase, attempt) => phase === 'install' && attempt <= 3 ? timeout : success);
  await setupInspectorSimulator('owned', '/app', f.options);
  assert.deepEqual(f.calls.slice(-5).map(c => c.args[0]), ['shutdown', 'erase', 'boot', 'bootstatus', 'install']);
  assert.ok(f.calls.every(c => c.args[1] === 'owned'));
  assert.equal(f.calls.filter(c => c.args[0] === 'erase').length, 1);
});

test('a transient bootstatus failure recovers before any install', async () => {
  const f = fixture((phase, attempt) => phase === 'bootstatus' && attempt === 1 ? timeout : success);
  await setupInspectorSimulator('owned', '/app', f.options);
  assert.deepEqual(f.calls.map(c => c.args[0]), ['boot', 'bootstatus', 'shutdown', 'erase', 'boot', 'bootstatus', 'install']);
});

test('a permanently unhealthy device fails after exactly one erase', async () => {
  const f = fixture(phase => phase === 'install' ? timeout : success);
  await assert.rejects(setupInspectorSimulator('owned', '/app', f.options), SimulatorSetupFailure);
  assert.equal(f.calls.filter(c => c.args[0] === 'erase').length, 1);
  assert.equal(f.calls.filter(c => c.args[0] === 'install').length, 6);
});

test('erase failure stops setup and a stopped device does not block erase', async () => {
  const f = fixture(phase => {
    if (phase === 'bootstatus') return timeout;
    if (phase === 'shutdown') return { ...success, status: 149, stderr: 'Unable to shutdown device in current state: Shutdown' };
    if (phase === 'erase') return { ...success, status: 1, stderr: 'cannot erase' };
    return success;
  });
  await assert.rejects(setupInspectorSimulator('owned', '/app', f.options),
    error => error instanceof SimulatorSetupFailure && error.phase === 'erase');
  assert.equal(f.calls.at(-1)!.args[0], 'erase');
});

test('setup has an aggregate budget and never extends it with retries', async () => {
  const f = fixture(phase => {
    if (phase === 'boot') f.elapse(720_000);
    return success;
  });
  await assert.rejects(setupInspectorSimulator('owned', '/app', f.options),
    error => error instanceof SimulatorSetupFailure && error.result.errorCode === 'SETUP_DEADLINE');
  assert.deepEqual(f.calls.map(c => c.args[0]), ['boot']);
});

test('stderr is retained as data rather than summary markup', async () => {
  const f = fixture(phase => phase === 'install' ? { ...invalidApp, stderr: '<details>& failure\nline 2' } : success);
  await assert.rejects(setupInspectorSimulator('owned', '/app', f.options), SimulatorSetupFailure);
  assert.ok(f.reports.some(row => row.includes('&lt;details&gt;&amp; failure\\nline 2')));
});

test('transient recognition excludes invalid apps, unknown signals and generic failures', () => {
  for (const result of [invalidApp, { ...success, status: null, signal: 'SIGTERM' }, { ...success, status: 1, stderr: 'installation failed' }]) {
    assert.equal(transientSetupFailure(result), false);
  }
  assert.equal(transientSetupFailure({ ...success, status: 1, stderr: 'Failed to connect to installd' }), true);
});
