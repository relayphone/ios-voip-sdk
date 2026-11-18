import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { HostAudioGuardFailure, requireSimulatorMedia, SimulatorMediaRefusal, withSimulatorMediaAudio } from './simulator-media.ts';

test('local simulator media is refused before the guard or journey starts', async () => {
  const unexpected = async (): Promise<never> => assert.fail('Local simulator setup started');
  await assert.rejects(withSimulatorMediaAudio(unexpected, {
    authorization: { environment: {} }, start: unexpected,
  }), {
    name: 'Error',
    message: /host speakers and microphone.*not available yet.*hosted GitHub Actions/,
  });
  assert.throws(() => requireSimulatorMedia({ environment: { GITHUB_ACTIONS: 'false' } }), SimulatorMediaRefusal);
});

test('a lease must prove isolation and both virtual audio routes', () => {
  const isolated = { isolated: true, virtualInputVerified: true, virtualOutputVerified: true };
  for (const field of ['isolated', 'virtualInputVerified', 'virtualOutputVerified'] as const) {
    assert.throws(() => requireSimulatorMedia({
      environment: {}, leaseAudio: { ...isolated, [field]: false },
    }), /requires isolated audio and verified virtual input and output routes.*hosted GitHub Actions/);
  }
  assert.throws(() => requireSimulatorMedia({ environment: {}, leaseAudio: isolated }),
    /lease verification is not available yet.*hosted GitHub Actions/);
});

test('hosted CI arms the guard before the journey and records its verdict after cleanup', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'simulator-media-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const summary = join(directory, 'summary.md');
  const order: string[] = [];
  const guardSignal = new AbortController().signal;
  const result = await withSimulatorMediaAudio(async signal => {
    assert.equal(signal, guardSignal);
    order.push('journey');
    return 42;
  }, {
    authorization: { environment: { GITHUB_ACTIONS: 'true', GITHUB_STEP_SUMMARY: summary } },
    start: async () => {
      order.push('arm');
      return { signal: guardSignal, finish: async () => { order.push('finish'); return 'no host devices'; } };
    },
  });
  assert.equal(result, 42);
  assert.deepEqual(order, ['arm', 'journey', 'finish']);
  assert.match(await readFile(summary, 'utf8'), /Core Audio guard passed \(no host devices\)/);
});

test('a guard trip aborts the journey and takes precedence over its result', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'simulator-media-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const summary = join(directory, 'summary.md');
  const controller = new AbortController();
  const trip = new Error('Host audio active on default output device');
  await assert.rejects(withSimulatorMediaAudio(async signal => {
    const tripped = new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }));
    controller.abort(trip);
    await tripped;
  }, {
    authorization: { environment: { GITHUB_ACTIONS: 'true', GITHUB_STEP_SUMMARY: summary } },
    start: async () => ({ signal: controller.signal, finish: async () => 'no host devices' }),
  }), (error: unknown) => error instanceof HostAudioGuardFailure && error.cause === trip);
  assert.match(await readFile(summary, 'utf8'), /Core Audio guard failed: .*Host audio active/);
});

test('the shipped entry points refuse a local invocation before setup', () => {
  const cases = [
    ['cli.ts', 'start', 'unused-harness'],
    ['cli.ts', 'serve', 'unused-harness'],
    ['cli.ts', 'act', 'unused-harness', '{"type":"hold"}'],
    ['feasibility.ts', 'unused-simulator', 'unused-app', 'unused-result'],
    ['run-native-tests.ts', '30', 'unused-results', 'unused-simulator', 'unused-spec', 'unused-host'],
    ['simulator-media.ts', 'unused-command'],
  ];
  for (const [entry, ...args] of cases) {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL(entry!, import.meta.url)), ...args], {
      encoding: 'utf8', env: { ...process.env, GITHUB_ACTIONS: '' }, timeout: 5000,
    });
    assert.equal(result.status, 1, entry);
    assert.match(result.stdout + result.stderr, /host speakers and microphone.*hosted GitHub Actions/, entry);
  }
});
