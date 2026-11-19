import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertRuntimeBoundaries, launchToleratingASlowSimulator } from './runtime-smoke.ts';

const identity = { runID: 'runtime-run', pid: 123 };
const entry = { ...identity, event: 'process.entered', sequence: 1,
  uptimeNanoseconds: 100, t_ms: 0, boundarySource: 'runtime-preparation' };
const ready = { ...identity, event: 'runtime.ready', sequence: 5,
  uptimeNanoseconds: 200, t_ms: 1, boundarySource: 'hooks-installed' };
const journal = (...rows: object[]) => rows.map(row => JSON.stringify(row)).join('\n') + '\n';

test('runtime boundary evidence includes entry, hook completion and invocation identity', () => {
  assertRuntimeBoundaries(journal(entry, ready), identity);
});

test('missing, repeated, stale or fabricated runtime boundaries cannot qualify', () => {
  for (const rows of [
    [entry], [ready], [entry, entry, ready], [entry, ready, ready],
    [entry, { ...ready, pid: 456 }], [entry, { ...ready, runID: 'old-run' }],
    [entry, { ...ready, uptimeNanoseconds: 99 }], [entry, { ...ready, sequence: 1 }],
    [{ ...entry, t_ms: 1 }, ready], [{ ...entry, uptimeNanoseconds: 0 }, ready],
    [{ ...entry, uptimeNanoseconds: '100' }, ready], [entry, { ...ready, sequence: '5' }],
    [entry, { ...ready, boundarySource: 'push-registry' }],
  ]) assert.throws(() => assertRuntimeBoundaries(journal(...rows), identity));
});

const slowRead = new Error(
  'cksim --simulator X --bundle dev.callkitsim.smoke launch exited with 1\n' +
    'Reading simulator environment key CKSIM_RUNTIME timed out after 60s.',
);

/** A launch that fails with each error in turn, then succeeds, and counts its attempts. */
function launcher(...failures: Error[]) {
  let attempts = 0;
  const launch = () => {
    attempts += 1;
    const failure = failures[attempts - 1];
    if (failure) throw failure;
    return 'launched';
  };
  return { launch, attempts: () => attempts };
}

test('a launch whose environment read timed out runs once more', (context) => {
  context.mock.method(console, 'warn', () => {});
  const { launch, attempts } = launcher(slowRead);
  assert.equal(launchToleratingASlowSimulator(launch), 'launched');
  assert.equal(attempts(), 2);
});

test('a launch runs at most twice', (context) => {
  context.mock.method(console, 'warn', () => {});
  const { launch, attempts } = launcher(slowRead, slowRead);
  assert.throws(() => launchToleratingASlowSimulator(launch), slowRead);
  assert.equal(attempts(), 2);
});

test('any other launch failure fails at once', () => {
  const failure = new Error('Uninstall the other simulator runtime before launching this release.');
  const { launch, attempts } = launcher(failure);
  assert.throws(() => launchToleratingASlowSimulator(launch), failure);
  assert.equal(attempts(), 1);
});
