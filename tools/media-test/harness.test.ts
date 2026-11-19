import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';
import { setImmediate as nextTurn, setTimeout as delay } from 'node:timers/promises';
import { dispose, Room, RoomEvent } from '@livekit/rtc-node';
import { command, deadline } from './fixture-runtime.ts';
import { serverBinary, startServer } from './server.ts';
import { MediaPeer } from './peer.ts';
import { parseAction, startHarness } from './harness.ts';
import { createMarker, detectMarker, emissionSamples } from '../../expo/src/testing/marker.ts';
import { measureMarker, markerReport, type PCMCapture } from './marker-evidence.ts';
import { measureMarkerAsync } from './measure-marker.ts';
import { monitorReceiver } from './peer-window.ts';

const root = mkdtempSync(join(tmpdir(), 'media-harness-test-'));
let binary: string;
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const pause = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
async function waitFor<T>(label: string, observe: () => T | undefined): Promise<T> {
  let observing = true;
  try {
    return await deadline(15_000, label, async () => {
      while (observing) {
        const value = observe();
        if (value !== undefined) return value;
        await pause(50);
      }
      throw Error(`${label} observation ended`);
    });
  } finally { observing = false; }
}
const until = (condition: () => boolean) => waitFor('Test condition', () => condition() || undefined);
const reconnectSampleRate = 48_000;
const reconnectWindowSamples = 3 * reconnectSampleRate;
type DuplexCapture = readonly [PCMCapture, PCMCapture];

async function captureReconnectWindow(read: () => DuplexCapture, received: () => readonly [number, number]) {
  try {
    return await waitFor('Reconnect PCM and receiver counters', () => {
      if (received().some(samples => samples < reconnectWindowSamples)) return;
      const window = read();
      if (window.every(capture => capture.channels[0]!.length >= reconnectWindowSamples &&
        (capture.transport?.at(-1)?.sample ?? 0) >= reconnectWindowSamples)) return window;
    });
  } catch (cause) {
    const progress = read().map((capture, index) =>
      `${index === 0 ? 'downlink' : 'uplink'} PCM=${capture.channels[0]!.length}, counters through=${capture.transport?.at(-1)?.sample ?? 'missing'}`);
    throw new Error(`Incomplete reconnect capture for ${reconnectWindowSamples} samples (${progress.join(' | ')})`, { cause });
  }
}
before(async () => { binary = await serverBinary(root); });
after(async () => { await dispose(); rmSync(root, { recursive: true, force: true }); });
const directory = (name: string) => { const path = join(root, name); mkdirSync(path); cpSync(join(root, 'server.tgz'), join(path, 'server.tgz')); return path; };
const rejectsServer = async (name: string, port: number) => {
  let unexpected: Awaited<ReturnType<typeof startServer>> | undefined;
  try { await assert.rejects(async () => { unexpected = await startServer(binary, directory(name), port); }); }
  finally { await unexpected?.close(); }
};

test('pinned archive corruption cannot launch an unverified binary', async () => {
  const dir = directory('corrupt'); writeFileSync(join(dir, 'server.tgz'), 'corrupt');
  await assert.rejects(serverBinary(dir), /checksum mismatch/);
});
test('server clean stop is awaited and repeatable', async () => {
  const server = await startServer(binary, directory('server'));
  try { assert.ok(server.alive()); assert.ok(alive(server.pid)); }
  finally { await server.close(); await server.close(); }
  assert.ok(!alive(server.pid));
});
test('an occupied health port cannot qualify an unrelated server', async () => {
  const listener = createServer((_, res) => res.end('OK'));
  await new Promise<void>(resolve => listener.listen(0, '127.0.0.1', resolve));
  try {
    const address = listener.address(); assert.ok(address && typeof address !== 'string');
    await rejectsServer('occupied', address.port);
  } finally { await new Promise<void>(resolve => listener.close(() => resolve())); }
});
test('another LiveKit instance cannot qualify with different credentials', async () => {
  const existing = await startServer(binary, directory('existing'));
  try {
    await rejectsServer('different-key', Number(new URL(existing.url).port));
    assert.ok(existing.alive(), 'The unrelated instance must remain running');
  } finally { await existing.close(); }
});
test('video updates arrive from the fixture server under a room-admin grant', async (t) => {
  const harness = await startHarness(directory('server-video'), 'fixture-video');
  const app = new Room();
  const signals: string[] = [];
  app.on(RoomEvent.RoomMetadataChanged, (metadata: string) => signals.push(metadata));
  const update = { conversationId: 'call', sessionId: randomUUID(), phaseId: 'live', enabled: true };
  const budget = () => ({ signal: new AbortController().signal, deadlineMs: performance.now() + 5000 });
  try {
    const { url, token } = harness.credentials('example');
    await app.connect(url, token);
    const participantAttempt = await fetch(
      `${url.replace('ws:', 'http:')}/twirp/livekit.RoomService/UpdateRoomMetadata`, {
        method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ room: app.name, metadata: 'participant update' }), signal: AbortSignal.timeout(5000),
      });
    await participantAttempt.body?.cancel();
    assert.equal(participantAttempt.status, 401);
    await assert.rejects(harness.updateVideo(update, { ...budget(), deadlineMs: performance.now() - 1 }), /deadline/);
    await assert.rejects(harness.updateVideo(update, { ...budget(), signal: AbortSignal.abort(Error('cancelled')) }), /cancelled/);
    await assert.rejects(harness.updateVideo({ ...update, phaseId: '' }, budget()), /Invalid server video update/);
    for (const enabled of [true, false]) {
      const previous = signals.length;
      const pending = harness.updateVideo({ ...update, enabled }, budget());
      await assert.rejects(harness.updateVideo(update, budget()), /already pending/);
      await pending;
      await until(() => signals.length > previous);
      const value: Record<string, unknown> = JSON.parse(signals.at(-1)!);
      const { id, ...message } = value;
      assert.match(String(id), /^[0-9a-f-]{36}$/);
      assert.deepEqual(message, { type: 'video', fixtureId: 'fixture-video', ...update, enabled });
    }
    assert.equal(signals.length, 2);
    assert.notEqual(JSON.parse(signals[0]!).id, JSON.parse(signals[1]!).id);

    const cancelled = new AbortController();
    const send = globalThis.fetch;
    t.mock.method(globalThis, 'fetch', async (...args: Parameters<typeof fetch>) => {
      const response = await send(...args);
      // Lose the host acknowledgement after the real server commits the update.
      cancelled.abort(Error('Lost update acknowledgement'));
      return response;
    });
    await assert.rejects(harness.updateVideo(update, { ...budget(), signal: cancelled.signal }));
    await until(() => signals.length === 3);
    await assert.rejects(harness.updateVideo(update, budget()), /uncertain/);
  } finally {
    try { await app.disconnect(); } finally { await harness.stop(); }
  }
});
test('real peer publishes markers, captures app audio, holds silent and leaves', async () => {
  const harness = await startHarness(directory('peer'), 'controls');
  const app = new MediaPeer();
  try {
    await assert.rejects(startHarness(join(root, 'peer'), 'duplicate'), /EEXIST/);
    await app.connect(harness.credentials('app'));
    await until(() => app.status().readerLive && harness.status().readerLive);
    await harness.act({ type: 'publish', markerId: 'controls:toDevice' });
    app.publish('controls:fromDevice');
    await delay(500); app.beginCapture(); await harness.act({ type: 'capture' });
    await delay(3000);
    for (const [capture, id] of [[app.capture(), 'controls:toDevice'], [harness.observation().capture, 'controls:fromDevice']] as const) {
      const measured = await measureMarkerAsync(capture, createMarker(id));
      assert.ok(measured.clean && measured.complete && measured.postRollObserved);
    }
    await harness.act({ type: 'hold' }); await delay(500); app.beginCapture();
    await monitorReceiver(() => app.status(), { deadlineMs: performance.now() + 30000 });
    assert.ok(app.status().receivedSamples > 0); assert.ok(app.status().rms! < 0.001);
    await harness.act({ type: 'leave' }); assert.ok(!harness.status().connected);
    await until(() => !app.status().trackAvailable);
  } finally { await app.close(); await harness.stop(); }
});
test('full peer transport reconnect republishes real audio and requires fresh clean markers', async () => {
  const harness = await startHarness(directory('reconnect'), 'reconnect');
  const app = new MediaPeer();
  try {
    await app.connect(harness.credentials('app'));
    await until(() => app.status().readerLive && harness.status().readerLive);
    await harness.act({ type: 'publish', markerId: 'reconnect:before:toDevice' });
    app.publish('reconnect:before:fromDevice');
    await delay(3000);
    assert.ok(detectMarker(Float32Array.from(app.capture().channels[0]!), 48000, createMarker('reconnect:before:toDevice')));
    assert.equal(harness.observation().reconnect, null);
    const anchor = app.lifecycleObservation().observedAtMs;
    await harness.act({ type: 'reconnect' });
    const evidence = harness.observation().reconnect;
    assert.ok(evidence && evidence.reconnectingAtMs !== undefined && evidence.reconnectedAtMs !== undefined);
    assert.equal(evidence.clock.id, harness.observation().lifecycle.clock.id);
    assert.ok(evidence.requestedAtMs <= evidence.reconnectingAtMs);
    assert.ok(evidence.reconnectingAtMs <= evidence.reconnectedAtMs);
    assert.ok(evidence.requestCompletedAtMs! >= evidence.requestedAtMs);
    assert.equal(evidence.publicationSidsBefore.length, 1);
    assert.equal(evidence.publicationSidsAfter?.length, 1);
    await until(() => [app.status(), harness.status()].every(status => status.trackAvailable && status.readerLive));
    // Independent receiver events prove real publication teardown/recreation, not just status.
    const events = app.lifecycleObservation().events.filter(row => row.identity === 'far-end' && row.atMs >= anchor);
    assert.ok(events.some(row => row.kind === 'trackUnpublished'));
    assert.ok(events.some(row => row.kind === 'trackPublished'));
    const appBeforePublication = app.status().receivedSamples;
    const peerBeforePublication = harness.status().receivedSamples;
    await harness.act({ type: 'publish', markerId: 'reconnect:after:toDevice' });
    app.publish('reconnect:after:fromDevice');
    const warmupSamples = reconnectSampleRate / 2;
    await until(() => app.status().receivedSamples - appBeforePublication >= warmupSamples &&
      harness.status().receivedSamples - peerBeforePublication >= warmupSamples);
    app.beginCapture(); await harness.act({ type: 'capture' });
    const [downlink, uplink] = await captureReconnectWindow(
      () => [app.capture(), harness.observation().capture],
      () => [app.status().receivedSamples, harness.status().receivedSamples],
    );
    for (const [capture, id] of [[downlink, 'reconnect:after:toDevice'], [uplink, 'reconnect:after:fromDevice']] as const) {
      const measured = await measureMarkerAsync(capture, createMarker(id));
      assert.ok(measured.clean && measured.complete && measured.postRollObserved, markerReport(id, measured));
      assert.equal(detectMarker(Float32Array.from(capture.channels[0]!), 48000,
        createMarker(id.replace(':after:', ':before:'))), null);
    }
    assert.ok(app.status().readerLive && harness.status().readerLive);
    assert.deepEqual(harness.observation().reconnect, evidence, 'capture reset retains independent reconnect evidence');
    await harness.act({ type: 'leave' });
    await assert.rejects(harness.act({ type: 'reconnect' }), /cannot reconnect/);
  } finally { await app.close(); await harness.stop(); }
});

test('reconnect capture waits for decoded samples and counters beyond the nominal wall window', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const marker = createMarker('reconnect:after:toDevice');
  const samples = Array.from(emissionSamples(marker, reconnectSampleRate, reconnectWindowSamples, reconnectSampleRate / 2));
  const transport = Array.from({ length: 31 }, (_, timestamp) => ({
    sample: timestamp * 4800, timestamp, streamID: 'replacement-track',
    packetsLost: 0, concealedSamples: 0, insertedSamples: 0, removedSamples: 0,
  }));
  const full = { sampleRate: reconnectSampleRate, channels: [samples], formatChanged: false, transport };
  let downlink: PCMCapture = { ...full, channels: [samples.slice(0, 60_000)], transport: transport.slice(0, 13) };
  const pending = captureReconnectWindow(() => [downlink, full], () => [downlink.channels[0]!.length, reconnectWindowSamples]);
  t.mock.timers.tick(3000);
  await nextTurn();

  downlink = { ...full, transport: transport.slice(0, 13) };
  t.mock.timers.tick(50);
  await nextTurn();

  downlink = full;
  t.mock.timers.tick(50);
  const [capture] = await pending;
  const measured = measureMarker(capture, marker);
  assert.ok(measured.clean && measured.complete && measured.postRollObserved, markerReport(marker.id, measured));
});
const cliTests = {
  skip: (process.env.GITHUB_ACTIONS !== 'true' || process.env.RUNNER_ENVIRONMENT !== 'github-hosted') &&
    'The CLI requires hosted CI',
};
test('JSON CLI supports clean stop and cleanup after a daemon crash', cliTests, async () => {
  const dir = directory('cli'), cli = fileURLToPath(new URL('./cli.ts', import.meta.url));
  const call = (...args: string[]) => command(process.execPath, [cli, ...args.slice(0, 1), dir, ...args.slice(1)], 180_000);
  for (const crash of [false, true]) {
    let daemon: number | undefined;
    try {
      const started = JSON.parse(await call('start'));
      daemon = JSON.parse(readFileSync(join(dir, 'control.json'), 'utf8')).pid;
      assert.ok(JSON.parse(await call('status')).connected);
      assert.ok(JSON.parse(await call('credentials')).credentialsFile);
      assert.ok(!started.status.token);
      await call('act', JSON.stringify({ type: 'hold' }));
      if (crash) {
        process.kill(daemon!, 'SIGKILL');
        await until(() => !alive(daemon!));
      }
      await call('stop');
      assert.ok(!alive(started.status.serverPid)); assert.ok(!existsSync(join(dir, 'control.json')));
    } finally { if (daemon && alive(daemon)) process.kill(daemon, 'SIGTERM'); }
  }
});
test('a real app disconnect retains audio unpublication and independent terminal capture', async () => {
  const harness = await startHarness(directory('terminal'), 'terminal');
  const app = new MediaPeer();
  try {
    await app.connect(harness.credentials('app'));
    await until(() => harness.status().readerLive);
    app.publish('terminal:before-end');
    await delay(3000);
    assert.ok(detectMarker(Float32Array.from(harness.observation().capture.channels[0]!), 48_000, createMarker('terminal:before-end')));
    const anchor = harness.observation().lifecycle.observedAtMs;
    await app.close();
    await until(() => harness.observation().lifecycle.afterDisconnect !== null);
    const before = harness.observation().lifecycle;
    assert.ok(harness.status().connected, 'The independent observer must remain connected');
    for (const kind of ['trackUnpublished', 'participantDisconnected'] as const)
      assert.ok(before.events.some(row => row.identity === 'app' && row.kind === kind && row.atMs >= anchor));
    await until(() => harness.observation().lifecycle.observedAtMs >= before.observedAtMs + 1000);
    const terminal = harness.observation().lifecycle;
    assert.equal(terminal.droppedEvents, 0);
    assert.equal(terminal.afterDisconnect!.overflowSamples, 0);
    assert.equal(detectMarker(Float32Array.from(terminal.afterDisconnect!.channels[0]!), 48_000, createMarker('terminal:before-end')), null);
    await harness.act({ type: 'capture' });
    assert.deepEqual(harness.observation().lifecycle.afterDisconnect, terminal.afterDisconnect);
    assert.ok(terminal.observedAtMs >= before.observedAtMs + 1000);
  } finally { await app.close(); await harness.stop(); }
});
test('untrusted JSON commands reject invalid publication controls', () => {
  for (const input of [null, {}, { type: 'publish' }, { type: 'publish', markerId: '' }, { type: 'unknown' }]) assert.throws(() => parseAction(input));
  assert.deepEqual(parseAction({ type: 'publish', markerId: 'test' }), { type: 'publish', markerId: 'test' });
  assert.deepEqual(parseAction({ type: 'reconnect' }), { type: 'reconnect' });
});

test('a killed invoking runner cannot leave its daemon or server running', cliTests, async () => {
  const dir = directory('runner-crash'), cli = fileURLToPath(new URL('./cli.ts', import.meta.url));
  const runnerFile = join(dir, 'runner.ts');
  writeFileSync(runnerFile, `import { execFileSync } from 'node:child_process';
execFileSync(process.execPath, [process.argv[2], 'start', process.argv[3]], { stdio: 'ignore', timeout: 180000 });
setInterval(() => {}, 1000);`);
  const runner = spawn(process.execPath, [runnerFile, cli, dir], { stdio: 'ignore' });
  try {
    await until(() => existsSync(join(dir, 'control.json')));
    const { pid } = JSON.parse(readFileSync(join(dir, 'control.json'), 'utf8'));
    const status = JSON.parse(await command(process.execPath, [cli, 'status', dir]));
    runner.kill('SIGKILL');
    await until(() => !alive(pid) && !alive(status.serverPid));
    await command(process.execPath, [cli, 'stop', dir]);
  } finally { runner.kill('SIGKILL'); }
});

test('peer capture retires pending statistics, deduplicates counters and awaits polling on close', async () => {
  const harness = await startHarness(directory('statistics'), 'statistics');
  const first = Promise.withResolvers<void>(), last = Promise.withResolvers<void>();
  let reads = 0, streamID = 'first', stall = false;
  const app = new MediaPeer(async (_, sample) => {
    reads++;
    const count = reads;
    if (count === 1) await first.promise;
    if (stall) await last.promise;
    return { sample: sample(), streamID, timestamp: count === 1 ? 10 : 20,
      packetsLost: 0, concealedSamples: 0, insertedSamples: 0, removedSamples: 0 };
  });
  try {
    await app.connect(harness.credentials('statistics-app'));
    await until(() => reads === 1);
    app.beginCapture(); first.resolve();
    await until(() => reads >= 3);
    assert.deepEqual(app.capture().transport?.map(row => row.timestamp), [20]);
    const prior = app.capture();
    streamID = 'second'; await until(() => app.capture().transport?.length === 2);
    assert.equal(prior.transport?.length, 1, 'capture returns independent counter storage');
    app.beginCapture(); assert.deepEqual(app.capture().transport, []);
    await until(() => app.capture().transport?.length === 1);
    assert.equal(app.capture().transport?.[0]?.streamID, 'second');
    stall = true; const before = reads; await until(() => reads > before);
    let closed = false; const closing = app.close().then(() => { closed = true; });
    await delay(150); assert.equal(closed, false, 'close must await pending statistics');
    last.resolve(); await closing;
    const stoppedReads = reads; await delay(150); assert.equal(reads, stoppedReads);
  } finally { first.resolve(); last.resolve(); await app.close(); await harness.stop(); }
});
