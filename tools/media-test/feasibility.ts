// One bounded example-app feasibility run; the reusable fixture lifecycle is separate.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { AudioFrame, AudioSource, AudioStream, ConnectionState, LocalAudioTrack, Room, RoomEvent, TrackPublishOptions, TrackSource, dispose } from '@livekit/rtc-node';

import { createMarker, emissionSamples } from '../../expo/src/testing/marker.ts';
import { markerReport, measureMarker, type PCMCapture } from './marker-evidence.ts';
import { command, deadline, stopChild, unusedPort } from './fixture-runtime.ts';
import { measureMarkerAsync } from './measure-marker.ts';
import { monitorReceiver } from './peer-window.ts';

const [simulator, app, binary, output] = process.argv.slice(2);
const processing = "synthetic";
assert.ok(simulator && app && binary && output, 'Usage: feasibility.ts <simulator> <app> <livekit-server> <result>');
// Report only phase names and timing, never command arguments, tokens or server config.
const fixtureStarted = performance.now();
async function phase<T>(name: string, operation: () => Promise<T>): Promise<T> {
  const started = performance.now();
  const report = (state: "started" | "succeeded" | "failed") => {
    const progress = { kind: "fixture-progress", phase: name, state,
      elapsedMs: performance.now() - fixtureStarted, phaseMs: performance.now() - started };
    console.log(JSON.stringify(progress));
    writeFileSync(output + '.progress.json', JSON.stringify(progress));
  };
  report("started");
  try { const value = await operation(); report("succeeded"); return value; }
  catch (error) { report("failed"); throw error; }
}
console.log(JSON.stringify({ kind: "fixture-progress", phase: "moduleLoaded", at: new Date().toISOString() }));
const fixtureId = randomBytes(16).toString('hex');
const uplink = createMarker(`${fixtureId}:fromDevice`), downlink = createMarker(`${fixtureId}:toDevice`);
const bundle = 'com.example.voipconversations';
const secret = randomBytes(32).toString('hex');
const roomName = `media-${process.pid}`;
function token(identity: string): string {
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const data = part({ alg: 'HS256', typ: 'JWT' }) + '.' + part({ iss: 'probe', sub: identity,
    exp: Math.floor(Date.now() / 1000) + 180, video: { roomJoin: true, room: roomName, canPublish: true, canSubscribe: true } });
  return data + '.' + createHmac('sha256', secret).update(data).digest('base64url');
}
const simctl = (...args: string[]) => phase(`simulator.${args[0]}`, () => command('xcrun', ['simctl', ...args]));
// Finish simulator setup before connecting either participant; never block its packet clock.
try { await simctl('terminate', simulator, bundle); } catch { /* First launch has no running app. */ }
await simctl('install', simulator, app);
await simctl('privacy', simulator, 'grant', 'microphone', bundle);
const container = await simctl('get_app_container', simulator, bundle, 'data');
const signalPort = await unusedPort(), tcpPort = await unusedPort(), udpPort = await unusedPort("udp");
const serverURL = `http://127.0.0.1:${signalPort}`, roomURL = `ws://127.0.0.1:${signalPort}`;
const server = spawn(binary, ['--dev', '--bind', '127.0.0.1', '--node-ip', '127.0.0.1', '--config-body', JSON.stringify({
  port: signalPort, rtc: { tcp_port: tcpPort, udp_port: udpPort, use_external_ip: false, enable_loopback_candidate: true },
  keys: { probe: secret }, logging: { level: 'error' },
})], { stdio: 'ignore' });
// A native FFI shutdown must not leave this run or its owned server alive indefinitely.
const watchdog = setTimeout(() => { server.kill('SIGKILL'); process.exit(124); }, 180_000);
watchdog.unref();
process.once('SIGALRM', () => { server.kill('SIGKILL'); process.exit(124); });
const peer = new Room();
let running = true, receivedSamples = 0, energy = 0, readers: Promise<void>[] = [];
let readerLive = false, trackAvailable = false, readerFailed = false;
const cancelReaders: (() => Promise<void>)[] = [];
const source = new AudioSource(48_000, 1, 100);
let received: number[] = [];
let uplinkEvidence: ReturnType<typeof measureMarker> | null = null;
let uplinkCapture: PCMCapture | null = null;
const controls = { leakControlCaught: false, publicationSilent: false };
const control = createServer(async (request, response) => {
  try {
    assert.ok(['/leak-control', '/muted'].includes(request.url ?? ''));
    // Exclude queued pre-mute frames, then retain an entire observation window.
    await delay(500); receivedSamples = 0; energy = 0;
    if (request.url === "/leak-control") received = [];
    await monitorReceiver(() => ({ connected: peer.connectionState === ConnectionState.CONN_CONNECTED,
      readerLive: readerLive && !readerFailed, trackAvailable }));
    const rms = receivedSamples ? Math.sqrt(energy / receivedSamples) : 0;
    if (request.url === '/leak-control') {
      // Three seconds cover an arbitrary emission phase, allowed drift and the complete post-roll.
      for (let window = 0; window < 2; window++) {
        await monitorReceiver(() => ({ connected: peer.connectionState === ConnectionState.CONN_CONNECTED,
          readerLive: readerLive && !readerFailed, trackAvailable }));
      }
      uplinkCapture = { sampleRate: 48_000, channels: [received.slice()], formatChanged: false };
      uplinkEvidence = await measureMarkerAsync(uplinkCapture, uplink);
      assert.ok(uplinkEvidence.complete && uplinkEvidence.postRollObserved, 'Complete unmuted tones-v2 marker and post-roll were not received');
      controls.leakControlCaught = true;
    } else { assert.ok(rms < 0.001, 'Muted publication leaked PCM'); controls.publicationSilent = true; }
    response.end('ok');
  } catch { response.statusCode = 500; response.end('failed'); }
});
let publish: Promise<void> | undefined;
try {
  await phase('server.ready', async () => {
    let ready = false;
    for (let attempt = 0; attempt < 100 && !ready; attempt++) {
      ready = await fetch(serverURL, { signal: AbortSignal.timeout(1000) }).then(value => value.ok, () => false);
      if (!ready) await delay(100);
    }
    assert.ok(ready, 'Local LiveKit server unavailable');
  });
  await deadline(5000, 'Control listener', () => new Promise<void>(resolve => control.listen(0, '127.0.0.1', resolve)));
  const controlAddress = control.address();
  assert.ok(controlAddress && typeof controlAddress !== 'string');
  peer.on(RoomEvent.TrackUnsubscribed, () => { trackAvailable = false; });
  peer.on(RoomEvent.TrackSubscribed, track => {
    trackAvailable = true; readerLive = true;
    const reader = new AudioStream(track, 48_000, 1).getReader();
    cancelReaders.push(() => reader.cancel());
    readers.push((async () => {
      while (running) {
        const { done, value: frame } = await reader.read();
        if (done) { readerLive = false; break; }
        for (const sample of frame.data) {
          const value = sample / 32768;
          energy += value * value;
          if (received.length < 48_000 * 3) received.push(value);
        }
        receivedSamples += frame.data.length;
      }
    })().catch(() => { readerFailed = true; readerLive = false; }));
  });
  await phase('peer.connect', () => deadline(30_000, 'Peer connect', () => peer.connect(roomURL, token('far-end'))));
  const track = LocalAudioTrack.createAudioTrack('marker', source);
  const options = new TrackPublishOptions(); options.source = TrackSource.SOURCE_MICROPHONE;
  await phase('peer.publish', () => deadline(15_000, 'Peer publish', () => peer.localParticipant!.publishTrack(track, options)));
  const emission = Int16Array.from(emissionSamples(downlink, 48_000, 48_000 / 50 * 51), value => Math.round(value * 32767));
  publish = (async () => {
    let sample = 0;
    while (running) {
      const pcm = emission.slice(sample, sample + 480);
      sample = (sample + 480) % emission.length;
      await source.captureFrame(new AudioFrame(pcm, 48_000, 1, 480));
    }
  })();
  const result = join(container, 'Documents/media-result.json');
  for (const name of ['result', 'decoded', 'output']) rmSync(join(container, `Documents/media-${name}.json`), { force: true });
  writeFileSync(join(container, 'Documents/media-fixture.json'), JSON.stringify({
    url: roomURL, token: token('example'), control: `http://127.0.0.1:${controlAddress.port}`,
    profile: "tones-v2", uplinkFrequencies: uplink.frequencies,
  }), { mode: 0o600 });
  await simctl('launch', '--terminate-running-process', simulator, bundle);
  await phase('example.result', async () => {
    for (let attempt = 0; attempt < 300 && !existsSync(result); attempt++) await delay(100);
    assert.ok(existsSync(result), 'Example produced no result');
  });
  const evidence: unknown = JSON.parse(readFileSync(result, 'utf8'));
  uplinkCapture ??= { sampleRate: 48_000, channels: [received.slice()], formatChanged: false };
  uplinkEvidence ??= await measureMarkerAsync(uplinkCapture, uplink);
  const downlinkCaptures: Partial<Record<"decoded" | "output", PCMCapture>> = {};
  const downlinkEvidence = Object.fromEntries(await Promise.all((['decoded', 'output'] as const).map(async (stage): Promise<[string, ReturnType<typeof measureMarker> | { complete: false; error: string } | null]> => {
    const file = join(container, `Documents/media-${stage}.json`);
    try {
      if (!existsSync(file)) return [stage, null];
      const capture = JSON.parse(readFileSync(file, 'utf8')) as PCMCapture;
      downlinkCaptures[stage] = capture;
      return [stage, await measureMarkerAsync(capture, downlink)];
    } catch (error) { return [stage, { complete: false, error: String(error) }]; }
  })));
  writeFileSync(output, JSON.stringify({ processing, native: evidence, farEnd: controls,
    pcm: { fromDevice: uplinkCapture, toDevice: downlinkCaptures },
    receiver: { connected: peer.connectionState === ConnectionState.CONN_CONNECTED, readerLive, trackAvailable,
      readerFailed, receivedSamples, rms: receivedSamples ? Math.sqrt(energy / receivedSamples) : null },
    markers: { fromDevice: uplinkEvidence, toDevice: downlinkEvidence } }, null, 2));
  console.log(JSON.stringify({ processing, markers: { fromDevice: uplinkEvidence, toDevice: downlinkEvidence } }));
  if (process.env.GITHUB_STEP_SUMMARY) {
    let report = markerReport(`${processing}: fromDevice / farEnd`, uplinkEvidence);
    for (const [stage, measurement] of Object.entries(downlinkEvidence)) report +=
      measurement && 'channels' in measurement ? markerReport(`${processing}: toDevice / ${stage}`, measurement)
        : `\n### ${processing}: toDevice / ${stage}\n\nMissing or invalid PCM observation.\n`;
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
  }
  assert.ok((uplinkEvidence as ReturnType<typeof measureMarker> | null)?.complete && (uplinkEvidence as ReturnType<typeof measureMarker> | null)?.postRollObserved &&
    Object.values(downlinkEvidence).every(value => value?.complete && "postRollObserved" in value && value.postRollObserved),
    'A complete tones-v2 marker with every slot >= 0.8 and post-roll coverage is required in both directions');
  assert.ok(evidence && typeof evidence === 'object' && 'passed' in evidence && evidence.passed === true, 'Native media check failed');
  assert.ok(controls.leakControlCaught && controls.publicationSilent, 'Far-end controls did not complete');
} finally {
  running = false;
  control.closeAllConnections(); control.close();
  try {
    await deadline(10_000, 'Peer cleanup', async () => {
      await Promise.allSettled(cancelReaders.map(cancel => cancel()));
      await Promise.allSettled(readers);
      await peer.disconnect(); await source.close();
      await publish;
      await dispose();
    });
  } finally {
    await stopChild(server);
    clearTimeout(watchdog);
  }
}
