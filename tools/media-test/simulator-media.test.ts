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
    message: /host speakers and microphone.*hosted GitHub Actions/,
  });
  assert.throws(() => requireSimulatorMedia({ environment: { GITHUB_ACTIONS: 'false' } }), SimulatorMediaRefusal);
});

test('self-hosted Actions and Actions without a hosted runner identity refuse before the guard', async () => {
  const unexpected = async (): Promise<never> => assert.fail('Unverified simulator setup started');
  for (const environment of [
    { GITHUB_ACTIONS: 'true', RUNNER_ENVIRONMENT: 'self-hosted' },
    { GITHUB_ACTIONS: 'true' },
  ]) {
    await assert.rejects(withSimulatorMediaAudio(unexpected, {
      authorization: { environment }, start: unexpected,
    }), SimulatorMediaRefusal);
  }
});

test('a lease must prove isolation and both virtual audio routes', () => {
  const isolated = { isolated: true, virtualInputVerified: true, virtualOutputVerified: true };
  for (const field of ['isolated', 'virtualInputVerified', 'virtualOutputVerified'] as const) {
    assert.throws(() => requireSimulatorMedia({
      environment: {}, leaseAudio: { ...isolated, [field]: false },
    }), /requires isolated audio and verified virtual input and output routes.*hosted GitHub Actions/);
  }
  assert.doesNotThrow(() => requireSimulatorMedia({ environment: {}, leaseAudio: isolated }));
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
    authorization: { environment: { GITHUB_ACTIONS: 'true', RUNNER_ENVIRONMENT: 'github-hosted', GITHUB_STEP_SUMMARY: summary } },
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
    authorization: { environment: { GITHUB_ACTIONS: 'true', RUNNER_ENVIRONMENT: 'github-hosted', GITHUB_STEP_SUMMARY: summary } },
    start: async reportDevice => ({
      signal: controller.signal,
      finish: async () => {
        reportDevice('default output MacBook Pro Speakers, UID "BuiltInSpeakerDevice", transport built-in, verdict blocked');
        return 'monitoring default host devices';
      },
    }),
  }), (error: unknown) => error instanceof HostAudioGuardFailure && error.cause === trip);
  const report = await readFile(summary, 'utf8');
  assert.match(report, /Core Audio guard failed: .*Host audio active/);
  assert.match(report, /MacBook Pro Speakers, UID "BuiltInSpeakerDevice", transport built-in, verdict blocked/);
});

test('the shipped entry points refuse a local invocation before setup', () => {
  const cases = [
    ['cli.ts', 'start', 'unused-harness'],
    ['cli.ts', 'serve', 'unused-harness'],
    ['cli.ts', 'act', 'unused-harness', '{"type":"hold"}'],
    ['feasibility.ts', 'unused-simulator', 'unused-app', 'unused-result'],
    ['video-journey.ts', 'unused-simulator', 'unused-app', 'unused-result', 'initial-local'],
    ['run-native-tests.ts', '30', 'unused-results', 'unused-simulator', 'unused-spec', 'unused-host'],
    ['simulator-media.ts', 'unused-command'],
    ['simulator-media.ts', '--check-lease'],
  ];
  const environment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('ISOLATED_LEASE_')));
  for (const [entry, ...args] of cases) {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL(entry!, import.meta.url)), ...args], {
      encoding: 'utf8', env: { ...environment, GITHUB_ACTIONS: '' }, timeout: 5000,
    });
    assert.equal(result.status, 1, entry);
    assert.match(result.stdout + result.stderr, /host speakers and microphone.*hosted GitHub Actions/, entry);
  }
});

test('the generic command launcher remains hosted-only with local lease configuration', () => {
  const result = spawnSync(process.execPath,
    [fileURLToPath(new URL('./simulator-media.ts', import.meta.url)), '/usr/bin/true'], {
      encoding: 'utf8', env: {
        ...process.env, GITHUB_ACTIONS: '', ISOLATED_LEASE_CLI: '/unused-cli', ISOLATED_LEASE_CHECKER: '/unused-checker',
      }, timeout: 5000,
    });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /host speakers and microphone.*hosted GitHub Actions/);
});

test('an entry point without verified destination binding cannot start on a local lease', async () => {
  const unexpected = async (): Promise<never> => assert.fail('Local simulator setup started');
  await assert.rejects(withSimulatorMediaAudio(unexpected, {
    authorization: { environment: {
      ISOLATED_LEASE_CLI: '/lease',
      ISOLATED_LEASE_CHECKER: '/checker',
      ISOLATED_LEASE_CONFIG_DIR: '/lease-config',
      ISOLATED_LEASE_CLI_ERROR_PREFIX: 'example-lease:',
      ISOLATED_LEASE_CLI_SECRET_PATTERN: 'lease_secret_[A-Za-z0-9_-]+',
      ISOLATED_LEASE_CLI_SCOPE_ENV: 'EXAMPLE_LEASE_KEY',
      ISOLATED_LEASE_CLI_URL_ENV: 'EXAMPLE_URL',
      ISOLATED_LEASE_CLI_LEASE_ID_ENV: 'EXAMPLE_LEASE_ID',
      ISOLATED_LEASE_CLI_LEASE_TOKEN_ENV: 'EXAMPLE_LEASE_TOKEN',
      ISOLATED_LEASE_INPUT_DEVICE_PREFIX: 'Lease Mic',
      ISOLATED_LEASE_OUTPUT_DEVICE_PREFIX: 'Lease Speaker',
      ISOLATED_LEASE_CHECKER_APP_ID: 'test.example.audio-check',
      ISOLATED_LEASE_CHECKER_DIRECTORY_PREFIX: 'lease-audio-check.',
    } },
    start: unexpected,
    lease: unexpected,
  }), /must bind its destination to the isolated simulator lease/);
});
