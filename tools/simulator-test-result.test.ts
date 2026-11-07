import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runnerHungBeforeConnecting } from './simulator-test-result.ts';

test('retries only a pre-connection hang with zero failed tests', () => {
  const hang = 'runner hung before establishing connection';
  assert.equal(runnerHungBeforeConnecting('{"failedTests":0}', hang), true);
  for (const summary of ['{}', '{"failedTests":1}', '{"failedTests":-1}', '{"failedTests":"0"}']) {
    assert.equal(runnerHungBeforeConnecting(summary, hang), false);
  }
  assert.equal(runnerHungBeforeConnecting('{"failedTests":0}', 'assertion failed'), false);
});
