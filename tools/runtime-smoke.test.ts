import assert from 'node:assert/strict';
import { test } from 'node:test';
import { launchToleratingASlowSimulator } from './runtime-smoke.ts';

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
