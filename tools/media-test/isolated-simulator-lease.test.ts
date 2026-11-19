import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { checkerPhaseLog, isolatedLeaseConfiguration, withIsolatedSimulatorLease } from './isolated-simulator-lease.ts';

const id = 'lse_test';
const udid = '345336B4-5696-4443-9D5B-E866DB7EB79A';
const now = 1_795_000_000_000;
const audio = { isolated: true, input: 'xcr Mic 2_UID', output: 'xcr Speaker 2_UID', verifiedAt: now - 1_000 };
const valid = {
  udid, lease: { id, audio: { ...audio, required: true } },
  sims: [{ udid, leaseId: id, primary: true, platform: 'ios-sim', state: 'booted', audio }],
};
const config = { cli: '/lease', checker: '/checker', environment: {} };
const waiting = { lease: { id, audio: { required: true, isolated: false } } };

function fixture(views: unknown[], { acquisitionError, project, attached = false, downError }: {
  acquisitionError?: Error; project?: string; attached?: boolean; downError?: string;
} = {}) {
  const events: string[] = [];
  const reports: string[] = [];
  const keys = new Set<string>();
  const start = (
    run: Parameters<typeof withIsolatedSimulatorLease<void>>[2],
    check: Parameters<typeof withIsolatedSimulatorLease<void>>[3] = async (checker, simulator) => {
      assert.equal(checker, config.checker);
      assert.equal(simulator, udid);
      events.push('checker');
      return 'PASS: slot 2 isolated (both devices)';
    },
    signal = new AbortController().signal,
    arm?: (proof: { udid: string }, signal: AbortSignal) => Promise<AbortSignal>,
  ) => withIsolatedSimulatorLease({
    ...config, project, environment: attached ? { XCR_LEASE_ID: id, XCR_LEASE_TOKEN: 'test' } : {},
  }, signal, run, check, line => reports.push(line), {
    now: () => now, arm,
    pause: (ms, signal) => delay(views.length ? 0 : ms, undefined, { signal }),
    shutdown: async simulator => { assert.equal(simulator, udid); events.push('shutdown'); return ''; },
    command: async (file, args, { env }) => {
      assert.equal(file, config.cli);
      if (env.XCR_LEASE_KEY) keys.add(env.XCR_LEASE_KEY);
      const verb = args[0]!;
      events.push(verb);
      switch (verb) {
        case 'up':
          assert.deepEqual(args, ['up', '--audio', 'isolated', '--platform', 'ios-sim', '--wait', '10',
            ...(project ? ['--project', project] : [])]);
          if (acquisitionError) throw acquisitionError;
          return { stdout: JSON.stringify({ lease: id, udid, audio }), stderr: '' };
        case 'lease':
          return { stdout: JSON.stringify(views.shift() ?? valid), stderr: '' };
        case 'down':
          return { stdout: '', stderr: downError ? `release: ${downError}\n` : '' };
        default:
          throw new Error(`Unexpected command ${verb}`);
      }
    },
  });
  return { start, events, reports, keys };
}

test('waits for a first heartbeat, checks the matching slot, runs and releases in the same scope', async () => {
  const { start, events, reports, keys } = fixture([waiting, valid]);
  await start(async ({ leaseAudio, udid: simulator }) => {
    assert.equal(simulator, udid);
    assert.deepEqual(leaseAudio, { isolated: true, virtualInputVerified: true, virtualOutputVerified: true });
    events.push('journey');
  });
  assert.deepEqual(events, ['up', 'lease', 'lease', 'checker', 'lease', 'journey', 'down']);
  assert.equal(keys.size, 1);
  assert.match(reports.join('\n'), /"verifiedAt":1794999999000/);
  assert.match(reports.join('\n'), /PASS: slot 2 isolated/);
});

test('uses and releases an existing lease without acquiring another', async () => {
  const { start, events } = fixture([{ ...valid, udid: undefined }], { attached: true });
  await start(async () => { events.push('journey'); });
  assert.deepEqual(events, ['lease', 'checker', 'lease', 'journey', 'down']);
});

test('refuses a simulator record owned by a different lease', async () => {
  const { start, events } = fixture([{ ...valid, sims: [{ ...valid.sims[0], leaseId: 'lse_other' }] }]);
  await assert.rejects(start(async () => assert.fail('journey started')), /UDID is missing from its simulator list/);
  assert.deepEqual(events, ['up', 'lease', 'down']);
});

test('refuses invalid proofs before the checker or journey', async () => {
  const proofs: [Partial<typeof valid.lease.audio>, RegExp][] = [
    [{ required: undefined }, /required must be true/],
    [{ isolated: undefined }, /isolated must be true/],
    [{ input: undefined }, /input is missing/],
    [{ output: undefined }, /output is missing/],
    [{ input: 'BuiltInMicrophoneDevice' }, /input is not a virtual microphone UID/],
    [{ output: 'xcr Mic 2_UID' }, /output is not a virtual speaker UID/],
    [{ output: 'xcr Speaker 3_UID' }, /device slots do not match/],
    [{ verifiedAt: undefined }, /verifiedAt must be an epoch timestamp/],
    [{ verifiedAt: now + 1 }, /verifiedAt is in the future/],
    [{ verifiedAt: now - 120_001 }, /verifiedAt is older than 120 seconds/],
  ];
  const cases: [unknown, RegExp][] = [
    ...proofs.map(([changes, expected]): [unknown, RegExp] => [{
      ...valid, lease: { id, audio: { ...valid.lease.audio, ...changes } },
    }, expected]),
    [{ ...valid, sims: [] }, /UDID is missing from its simulator list/],
    [{ ...valid, udid: undefined }, /no valid simulator UDID/],
    [{ ...valid, sims: [{ ...valid.sims[0], audio: { isolated: false, reason: 'route lost' } }] },
      /simulator.audio.isolated must be true: route lost/],
    [{ ...waiting, lease: { id, audio: { ...waiting.lease.audio, reason: 'route lost' } } },
      /lease.audio.isolated must be true: route lost/],
  ];
  for (const [view, expected] of cases) {
    const { start, events } = fixture([view]);
    await assert.rejects(start(async () => assert.fail('journey started')), expected);
    assert.deepEqual(events, ['up', 'lease', 'down']);
  }
});

test('reports the CLI refusal and releases even if acquisition fails', async () => {
  const { start, events, reports, keys } = fixture([], { acquisitionError: Object.assign(new Error('failed'), {
    stderr: 'working...\nxcr: conflict: no Mac can isolate audio\n',
    stdout: 'xcj_testroute_1234',
  }) });
  await assert.rejects(start(async () => assert.fail('journey started')), /conflict: no Mac can isolate audio/);
  assert.deepEqual(events, ['up', 'down']);
  assert.equal(keys.size, 1);
  assert.match(reports.join('\n'), /working\.\.\.\n.*conflict: no Mac can isolate audio/);
  assert.doesNotMatch(reports.join('\n'), /testroute_1234/);
});

test('a timed-out request uses its configured project and releases the same pending lease', async () => {
  const configured = isolatedLeaseConfiguration({
    SIMULATOR_LEASE_CLI: '/lease', SIMULATOR_LEASE_AUDIO_CHECKER: '/checker', ISOLATED_LEASE_PROJECT: '  media  ',
  });
  assert.equal(configured?.project, 'media');
  const { start, events, keys } = fixture([], {
    project: configured?.project,
    acquisitionError: Object.assign(new Error('waiting'), { stderr: 'xcr: still waiting for a Mac' }),
  });
  await assert.rejects(start(async () => assert.fail('journey started')), /still waiting for a Mac/);
  assert.deepEqual(events, ['up', 'down']);
  assert.equal(keys.size, 1);
});

const transportError = 'cannot reach https://leases.example.test: Transport error';
const heartbeatFailure = Object.assign(new Error('heartbeat failed'), { stderr: `xcr: ${transportError}\n` });

test('reattaches to the same pending lease after a transport error and only releases after the journey', async () => {
  const original = { XCR_CONFIG_DIR: '/lease-config', XCR_URL: 'https://leases.example.test', XCR_TOKEN: 'test-token' };
  const order: string[] = [];
  const environments: NodeJS.ProcessEnv[] = [];
  const directories: string[] = [];
  const acquired = { lease: id, udid, audio };
  const result = await withIsolatedSimulatorLease({ ...config, project: 'media', environment: original },
    new AbortController().signal, async () => { order.push('journey'); return true; },
    async () => { order.push('checker'); return 'PASS: slot 2 isolated (both devices)'; }, () => {}, {
      now: () => now,
      command: async (_, args, { cwd, env }) => {
        order.push(args[0]!);
        if (args[0] === 'up') {
          environments.push(env);
          directories.push(cwd);
          assert.deepEqual(args, ['up', '--audio', 'isolated', '--platform', 'ios-sim', '--wait', '10', '--project', 'media']);
          if (environments.length === 1) throw heartbeatFailure;
          return { stdout: JSON.stringify(acquired), stderr: '' };
        }
        return { stdout: JSON.stringify(valid), stderr: '' };
      },
      pause: (ms, signal) => delay(environments.length === 1 ? 0 : ms, undefined, { signal }),
    });
  assert.equal(result, true);
  assert.deepEqual(order, ['up', 'up', 'lease', 'checker', 'lease', 'journey', 'down']);
  assert.equal(environments[0], environments[1]);
  assert.equal(environments[0]?.XCR_CONFIG_DIR, original.XCR_CONFIG_DIR);
  assert.equal(environments[0]?.XCR_URL, original.XCR_URL);
  assert.equal(environments[0]?.XCR_TOKEN, original.XCR_TOKEN);
  assert.deepEqual(directories, [process.cwd(), process.cwd()]);
});

test('stops reattaching at fifteen minutes and then releases the pending lease', async () => {
  let time = 0;
  const calls: [string, number][] = [];
  await assert.rejects(withIsolatedSimulatorLease(config, new AbortController().signal,
    async () => assert.fail('journey started'), async () => assert.fail('checker started'), () => {}, {
      elapsed: () => time,
      pause: async ms => { time += ms; },
      command: async (_, [verb], { timeout }) => {
        calls.push([verb!, timeout]);
        if (verb === 'up') { time += 600_000; throw heartbeatFailure; }
        return { stdout: '', stderr: '' };
      },
    }), /transport retry deadline expired/);
  assert.deepEqual(calls, [['up', 615_000], ['up', 298_000], ['down', 30_000]]);
});

test('release retries the same authenticated lease after the CLI clears its record', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'sim-lease-config-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const leases = join(directory, 'leases.json');
  const log: string[] = [];
  const savedToken = 'xcl_savedtesttoken';
  let releases = 0;
  await withIsolatedSimulatorLease({ ...config, environment: { XCR_CONFIG_DIR: directory, XCR_URL: 'https://leases.example.test' } },
    new AbortController().signal, async () => {}, async () => 'PASS: slot 2 isolated (both devices)',
    line => log.push(line), {
      now: () => now,
      command: async (_, [verb], { env }) => {
        if (verb === 'up') {
          await writeFile(leases, JSON.stringify({ [env.XCR_LEASE_KEY!]: { leaseId: id, token: savedToken } }));
          return { stdout: JSON.stringify({ lease: id, udid, audio }), stderr: '' };
        }
        if (verb === 'lease') return { stdout: JSON.stringify(valid), stderr: '' };
        if (++releases === 1) {
          assert.equal(env.XCR_LEASE_ID, undefined);
          await unlink(leases);
          return { stdout: '', stderr: `release: ${transportError}\n` };
        }
        assert.equal(env.XCR_LEASE_ID, id);
        assert.equal(env.XCR_LEASE_TOKEN, savedToken);
        assert.equal(env.XCR_CONFIG_DIR, directory);
        if (releases === 2) throw Object.assign(new Error('timed out'), { killed: true });
        return { stdout: '', stderr: '' };
      },
      pause: (ms, signal) => delay(releases ? 0 : ms, undefined, { signal }),
    });
  assert.equal(releases, 3);
  assert.doesNotMatch(log.join('\n'), new RegExp(savedToken));
});

test('refuses a checker failure or a pass for a different audio slot', async () => {
  for (const check of [
    async () => 'PASS: slot 1 isolated (both devices)',
    async () => { throw new Error('FAIL: recording did not hear the fed tone'); },
  ]) {
    const { start, events } = fixture([valid]);
    await assert.rejects(start(async () => assert.fail('journey started'), check), /host-side audio isolation checker/);
    assert.deepEqual(events, ['up', 'lease', 'down']);
  }
});

test('shuts down and releases when a heartbeat reports lost isolation during the journey', async () => {
  const lost = { ...waiting, lease: { id, audio: { ...waiting.lease.audio, reason: 'output route lost' } } };
  const { start, events } = fixture([valid, valid, lost]);
  await assert.rejects(start(async (_, signal) => {
    events.push('journey');
    await delay(10_000, undefined, { signal });
  }), /output route lost/);
  assert.deepEqual(events, ['up', 'lease', 'checker', 'lease', 'journey', 'lease', 'shutdown', 'down']);
});

test('releases after a journey error and reports release failures', async () => {
  const runError = new Error('journey failed');
  const { start, events, reports } = fixture([valid], { downError: 'backend unreachable' });
  await assert.rejects(start(async () => { throw runError; }), error => error === runError);
  assert.equal(events.at(-1), 'down');
  assert.ok(reports.includes('Could not release isolated simulator lease: backend unreachable'));
});

test('a per-process guard trip aborts the checker and shuts down before release', async () => {
  const { start, events } = fixture([valid]);
  const guard = new AbortController();
  const checkerReady = Promise.withResolvers<void>();
  const run = start(async () => assert.fail('journey started'), async (_, simulator, signal) => {
    assert.equal(simulator, udid);
    events.push('checker');
    checkerReady.resolve();
    await delay(10_000, undefined, { signal });
    assert.fail('checker was not aborted');
  }, undefined, async proof => {
    assert.equal(proof.udid, udid);
    events.push('arm');
    return guard.signal;
  });
  await checkerReady.promise;
  guard.abort(new Error('PID 42, executable "Example", direction output'));
  await assert.rejects(run, /PID 42, executable "Example", direction output/);
  assert.deepEqual(events, ['up', 'lease', 'arm', 'checker', 'shutdown', 'down']);
});

test('a recording failure retains the checker output and refuses the journey', async () => {
  const { start, events } = fixture([valid]);
  const diagnostic = 'simulator recording log\nFAIL: the recording launch did not finish';
  await assert.rejects(start(async () => assert.fail('journey started'), async () => {
    throw new Error(diagnostic);
  }), /simulator recording log\nFAIL: the recording launch did not finish/);
  assert.deepEqual(events, ['up', 'lease', 'down']);
});

test('a checker pass cannot admit a journey with stale lease proof', async () => {
  const stale = { ...valid, lease: { id, audio: { ...valid.lease.audio, verifiedAt: now - 120_001 } } };
  const { start, events } = fixture([valid, stale]);
  await assert.rejects(start(async () => assert.fail('journey started')), /verifiedAt is older than 120 seconds/);
  assert.deepEqual(events, ['up', 'lease', 'checker', 'lease', 'down']);
});

test('retains checker phase logs on timeout', async t => {
  const scratch = await mkdtemp(join(tmpdir(), 'checker-log-test-'));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const work = join(scratch, 'xcr-audio-check.test');
  await mkdir(work);
  const process = 'process pid=42 dev.xcr.simtone in=false["xcr Mic 2_UID"] out=true["xcr Speaker 2_UID"]';
  await Promise.all([
    writeFile(join(work, 'tone.txt'), 'done\n'),
    writeFile(join(work, 'feed.txt'), 'feed started\n'),
    writeFile(join(work, 'record.txt'), ''),
    writeFile(join(work, 'probe.txt'), process + '\nprocess pid=123 OtherApp'),
  ]);
  const result = await checkerPhaseLog(scratch);
  assert.match(result, /Playback phase:\ndone/);
  assert.match(result, /Virtual microphone feed phase:\nfeed started/);
  assert.match(result, /Recording phase:\nNo output before timeout/);
  assert.ok(result.includes(process));
  assert.ok(!result.includes('OtherApp'));
});
