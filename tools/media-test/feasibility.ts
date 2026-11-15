// One bounded example-app run against the reusable host harness.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { dispose } from '@livekit/rtc-node';
import { startHarness } from './harness.ts';

import { createMarker } from '../../expo/src/testing/marker.ts';
import { markerReport, measureMarker, type PCMCapture } from './marker-evidence.ts';
import { command, deadline } from './fixture-runtime.ts';
import { measureMarkerAsync } from './measure-marker.ts';
import { monitorReceiver, ReceiverObservationError } from './peer-window.ts';
import { observeSilence, SilenceObservationError, type SilenceWindow } from './silence-window.ts';
import { assertNativePassed, writeUnobservedResult } from './result-receipt.ts';

const [simulator, app, output] = process.argv.slice(2);
const processing = "synthetic";
assert.ok(simulator && app && output, 'Usage: feasibility.ts <simulator> <app> <result>');
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
const simctl = (...args: string[]) => phase(`simulator.${args[0]}`, () => command('xcrun', ['simctl', ...args]));
// Finish simulator setup before connecting either participant; never block its packet clock.
try { await simctl('terminate', simulator, bundle); } catch { /* First launch has no running app. */ }
await simctl('install', simulator, app);
await simctl('privacy', simulator, 'grant', 'microphone', bundle);
const container = await simctl('get_app_container', simulator, bundle, 'data');
const harnessDirectory = output + '.harness';
const harness = await phase('harness.ready', () => startHarness(harnessDirectory, fixtureId));
const watchdog = setTimeout(() => { harness.abort(); process.exit(124); }, 180_000);
watchdog.unref();
process.once('SIGALRM', () => { harness.abort(); process.exit(124); });
let uplinkEvidence: ReturnType<typeof measureMarker> | null = null;
let uplinkCapture: PCMCapture | null = null;
let resultDeadlineMs: number | undefined;
const resultPhase = Promise.withResolvers<void>();
let pendingSilence: Promise<SilenceWindow[]> | undefined;
type ControlStep = 'request' | 'drain' | 'window-1' | 'window-2' | 'window-3' | 'marker-analysis' | 'marker-gate' | 'silence-gate';
const controls: { leakControlCaught: boolean; publicationSilent: boolean;
  silenceWindows?: SilenceWindow[];
  failure?: { phase: ControlStep; reason: ReceiverObservationError['reason'] | 'unobserved' | 'leak' | 'control-failed'; health?: ReceiverObservationError['health']; gapMs?: number } } =
  { leakControlCaught: false, publicationSilent: false };
const control = createServer(async (request, response) => {
  let controlPhase: ControlStep = 'request';
  const step = <T>(name: ControlStep, operation: () => Promise<T>) => {
    controlPhase = name;
    return phase(`control.${request.url === '/muted' ? 'muted' : 'leak-control'}.${name}`, operation);
  };
  try {
    if (request.url === '/deadline') {
      await resultPhase.promise;
      assert.ok(resultDeadlineMs !== undefined, 'Result phase has not started');
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({ remainingMs: Math.max(0, resultDeadlineMs - performance.now()) }));
      return;
    }
    assert.ok(resultDeadlineMs !== undefined, 'Result phase has not started');
    assert.ok(['/leak-control', '/muted'].includes(request.url ?? ''));
    // Exclude queued pre-mute frames, then retain an entire observation window.
    await step('drain', () => delay(500)); await harness.act({ type: 'capture' });
    const observe = () => monitorReceiver(() => harness.status());
    if (request.url === '/leak-control') {
      await step('window-1', observe);
      // Three seconds cover an arbitrary emission phase, allowed drift and the complete post-roll.
      for (const window of ['window-2', 'window-3'] as const) {
        await step(window, observe);
      }
      uplinkCapture = harness.observation().capture;
      uplinkEvidence = await step('marker-analysis', () => measureMarkerAsync(uplinkCapture!, uplink));
      controlPhase = 'marker-gate';
      assert.ok(uplinkEvidence.clean && uplinkEvidence.complete && uplinkEvidence.postRollObserved, 'Complete unmuted tones-v2 marker and post-roll were not received');
      controls.leakControlCaught = true;
    } else {
      controlPhase = 'silence-gate';
      pendingSilence = step('silence-gate', () => observeSilence(() => {
        const state = harness.status();
        return { ...state, samples: state.receivedSamples };
      }, { durationMs: 1000, deadlineMs: resultDeadlineMs!, gapLimitMs: 250 }));
      controls.silenceWindows = await pendingSilence;
      controls.publicationSilent = true;
    }
    response.end('ok');
  } catch (error) {
    if (error instanceof SilenceObservationError) controls.silenceWindows = error.windows;
    controls.failure = { phase: controlPhase, reason: error instanceof SilenceObservationError ? error.reason : error instanceof ReceiverObservationError ? error.reason : 'control-failed',
      ...(error instanceof ReceiverObservationError ? { health: error.health, gapMs: error.gapMs } : {}) };
    console.log(JSON.stringify({ kind: 'control-failure', ...controls.failure }));
    response.statusCode = 500; response.end('failed');
  }
});
try {
  await deadline(5000, 'Control listener', () => new Promise<void>(resolve => control.listen(0, '127.0.0.1', resolve)));
  const controlAddress = control.address();
  assert.ok(controlAddress && typeof controlAddress !== 'string');
  await phase('peer.publish', () => harness.act({ type: 'publish', markerId: downlink.id }));
  const result = join(container, 'Documents/media-result.json');
  for (const name of ['result', 'decoded', 'output', 'silence-windows']) rmSync(join(container, `Documents/media-${name}.json`), { force: true });
  writeFileSync(join(container, 'Documents/media-fixture.json'), JSON.stringify({
    ...harness.credentials('example'), control: `http://127.0.0.1:${controlAddress.port}`,
    profile: "tones-v2", uplinkFrequencies: uplink.frequencies,
  }), { mode: 0o600 });
  await simctl('launch', '--terminate-running-process', simulator, bundle);
  resultDeadlineMs = performance.now() + 30_000;
  resultPhase.resolve();
  await phase('example.result', async () => {
    while (!existsSync(result) && performance.now() < resultDeadlineMs!) await delay(Math.min(100, resultDeadlineMs! - performance.now()));
    if (!existsSync(result)) {
      // Finish serialization of an already-expired host observation; this grants no observation time.
      await pendingSilence?.catch(() => {});
      const nativeWindows = join(container, 'Documents/media-silence-windows.json');
      writeUnobservedResult(output, resultDeadlineMs!, controls, nativeWindows);
      throw new Error('Result budget ended: unobserved');
    }
  });
  const evidence: unknown = JSON.parse(readFileSync(result, 'utf8'));
  let nativeFailure: unknown;
  try { assertNativePassed(evidence); } catch (error) { nativeFailure = error; }
  uplinkCapture ??= harness.observation().capture;
  if (!nativeFailure) uplinkEvidence ??= await measureMarkerAsync(uplinkCapture, uplink);
  const downlinkCaptures: Partial<Record<"decoded" | "output", PCMCapture>> = {};
  const downlinkEvidence = Object.fromEntries(await Promise.all((['decoded', 'output'] as const).map(async (stage): Promise<[string, ReturnType<typeof measureMarker> | { complete: false; error: string } | null]> => {
    const file = join(container, `Documents/media-${stage}.json`);
    try {
      if (!existsSync(file)) return [stage, null];
      const capture = JSON.parse(readFileSync(file, 'utf8')) as PCMCapture;
      downlinkCaptures[stage] = capture;
      return [stage, nativeFailure ? null : await measureMarkerAsync(capture, downlink)];
    } catch (error) { return [stage, { complete: false, error: String(error) }]; }
  })));
  writeFileSync(output, JSON.stringify({ processing, native: evidence, farEnd: controls,
    pcm: { fromDevice: uplinkCapture, toDevice: downlinkCaptures },
    receiver: harness.status(),
    markers: { fromDevice: uplinkEvidence, toDevice: downlinkEvidence } }, null, 2));
  if (nativeFailure) throw nativeFailure;
  console.log(JSON.stringify({ processing, markers: { fromDevice: uplinkEvidence, toDevice: downlinkEvidence } }));
  if (process.env.GITHUB_STEP_SUMMARY) {
    let report = markerReport(`${processing}: fromDevice / farEnd`, uplinkEvidence);
    for (const [stage, measurement] of Object.entries(downlinkEvidence)) report +=
      measurement && 'channels' in measurement ? markerReport(`${processing}: toDevice / ${stage}`, measurement)
        : `\n### ${processing}: toDevice / ${stage}\n\nMissing or invalid PCM observation.\n`;
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
  }
  assert.ok((uplinkEvidence as ReturnType<typeof measureMarker> | null)?.clean && (uplinkEvidence as ReturnType<typeof measureMarker> | null)?.complete && (uplinkEvidence as ReturnType<typeof measureMarker> | null)?.postRollObserved &&
    Object.values(downlinkEvidence).every(value => value?.complete && 'clean' in value && value.clean && "postRollObserved" in value && value.postRollObserved),
    'A complete tones-v2 marker with every slot >= 0.8 and post-roll coverage is required in both directions');
  assert.ok(controls.leakControlCaught && controls.publicationSilent, 'Far-end controls did not complete');
} finally {
  control.closeAllConnections(); control.close();
  try { await harness.stop(); await dispose(); }
  finally { clearTimeout(watchdog); rmSync(harnessDirectory, { recursive: true, force: true }); }
}
