import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { classifySimulatorFailure, runnerHungBeforeConnecting, systemMemoryFailures } from './simulator-test-result.ts';

test('retries only a pre-connection hang with zero failed tests', () => {
  const hang = 'runner hung before establishing connection';
  assert.equal(runnerHungBeforeConnecting('{"failedTests":0}', hang), true);
  for (const summary of ['{}', '{"failedTests":1}', '{"failedTests":-1}', '{"failedTests":"0"}']) {
    assert.equal(runnerHungBeforeConnecting(summary, hang), false);
  }
  assert.equal(runnerHungBeforeConnecting('{"failedTests":0}', 'assertion failed'), false);
});

const busSummary = JSON.stringify({ failedTests: 1, testFailures: [{ failureText: 'Test crashed with signal bus.' }] });
const restart = 'Restarting after unexpected exit, crash, or test timeout';
const lockdown = 'unable to connect to "com.apple.instruments.deviceservice.lockdown"';
const memoryErrors = [{ process: 'containermanager', file: 'one.ips' }, { process: 'siriactionsd', file: 'two.ips' }];

test('a crash-only restart requires corroborating unrelated service memory failures', () => {
  assert.equal(classifySimulatorFailure(busSummary, `${lockdown}\n${restart}`, memoryErrors), 'infra:test-host-restart');
  for (const evidence of [[], memoryErrors.slice(0, 1), [memoryErrors[0]!, memoryErrors[0]!]]) {
    assert.equal(classifySimulatorFailure(busSummary, `${lockdown}\n${restart}`, evidence), 'product:tests');
  }
  for (const log of [lockdown, restart, `${lockdown}\n${restart}\nExpectation failed: result == expected`]) {
    assert.equal(classifySimulatorFailure(busSummary, log, memoryErrors), 'product:tests');
  }
});

test('assertions, other crashes and incomplete failure lists never permit a retry', () => {
  for (const summary of [
    '{}', 'null', 'malformed', '{"failedTests":1}',
    JSON.stringify({ failedTests: 2, testFailures: [{ failureText: 'Test crashed with signal bus.' }] }),
    JSON.stringify({ failedTests: 1, testFailures: [{ failureText: 'Expectation failed: result == expected' }] }),
    JSON.stringify({ failedTests: 1, testFailures: [{ failureText: 'Test crashed with signal segmentation fault.' }] }),
    JSON.stringify({ failedTests: 2, testFailures: [{ failureText: 'Test crashed with signal bus.' }, { failureText: 'Assertion failed' }] }),
  ]) assert.equal(classifySimulatorFailure(summary, `${lockdown}\n${restart}`, memoryErrors), 'product:tests');
  assert.equal(classifySimulatorFailure('{"failedTests":0}', 'runner hung before establishing connection'), 'infra:runner-hang');
  assert.equal(classifySimulatorFailure('{"failedTests":0}', 'runner hung before establishing connection\nExpectation failed: false'), 'product:tests');
});

test('only valid first-party simulator service KERN_MEMORY_ERROR reports corroborate a restart', () => {
  const folder = mkdtempSync(join(tmpdir(), 'test-host-crashes-'));
  try {
    mkdirSync(join(folder, 'nested'));
    const crash = (name: string, app: string, firstParty: number, signal = 'SIGBUS', subtype = 'KERN_MEMORY_ERROR at 0x1000') => {
      writeFileSync(join(folder, 'nested', name), `${JSON.stringify({ app_name: app, is_first_party: firstParty })}\n${JSON.stringify({ exception: { signal, subtype } })}`);
    };
    crash('one.ips', 'containermanager', 1);
    crash('two.ips', 'siriactionsd', 1);
    crash('fixture.ips', 'RuntimeTests', 1);
    crash('third-party.ips', 'containermanager', 0);
    crash('pointer.ips', 'containermanager', 1, 'SIGBUS', 'KERN_INVALID_ADDRESS at 0x0');
    crash('other-signal.ips', 'containermanager', 1, 'SIGSEGV');
    writeFileSync(join(folder, 'partial.ips'), '{');
    assert.deepEqual(systemMemoryFailures(folder).sort((a, b) => a.file.localeCompare(b.file)), memoryErrors);
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
