// One bounded example-app run against the reusable host harness.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { withSimulatorMediaAudio } from './simulator-media.ts';

import { createMarker } from '../../expo/src/testing/marker.ts';
import { markerReport, measureMarker, type PCMCapture } from './marker-evidence.ts';
import { command, deadline } from './fixture-runtime.ts';
import { measureMarkerAsync } from './measure-marker.ts';
import { monitorReceiver, ReceiverObservationError, type ReceiverWindow } from './peer-window.ts';
import { observeSilence, SilenceObservationError, type SilenceWindow } from './silence-window.ts';
import { assertNativePassed, assertNativeTeardown, writeUnobservedResult } from './result-receipt.ts';
import { diagnoseNativeStartup } from './startup-diagnostics.ts';

const [requestedSimulator, app, output] = process.argv.slice(2);

await withSimulatorMediaAudio(async (guardSignal, leasedSimulator, trackSimulatorApp) => {
  const watchdogAbort = new AbortController();
  const signal = AbortSignal.any([guardSignal, watchdogAbort.signal]);
  const processing = "synthetic";
  assert.ok(requestedSimulator && app && output, 'Usage: feasibility.ts <simulator|lease> <app> <result>');
  const simulator = leasedSimulator ?? requestedSimulator;
  const { startHarness } = await import('./harness.ts');
  const { dispose } = await import('@livekit/rtc-node');
  // Report only phase names and timing, never command arguments, tokens or server config.
  const fixtureStarted = performance.now();
  async function phase<T>(name: string, operation: () => Promise<T>): Promise<T> {
    signal.throwIfAborted();
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
  const appParticipant = 'example';
  const simctl = (...args: string[]) => phase(`simulator.${args[0]}`, () => command('xcrun', ['simctl', ...args], 120_000, signal));
  // Finish simulator setup before connecting either participant; never block its packet clock.
  try { await simctl('terminate', simulator, bundle); } catch { /* First launch has no running app. */ }
  await simctl('install', simulator, app);
  await simctl('privacy', simulator, 'grant', 'microphone', bundle);
  const container = await simctl('get_app_container', simulator, bundle, 'data');
  const harnessDirectory = output + '.harness';
  const harness = await phase('harness.ready', () => startHarness(harnessDirectory, fixtureId));
  const hardStop = () => {
    process.exitCode = 124;
    watchdogAbort.abort(new Error('Media feasibility exceeded its run deadline'));
  };
  const watchdog = setTimeout(hardStop, 180_000);
  watchdog.unref();
  process.once('SIGALRM', hardStop);
  let uplinkEvidence: ReturnType<typeof measureMarker> | null = null;
  let uplinkCapture: PCMCapture | null = null;
  let resultDeadlineMs: number | undefined;
  const resultPhase = Promise.withResolvers<void>();
  let pendingSilence: Promise<SilenceWindow[]> | undefined;
  let pendingReceiver: Promise<ReceiverWindow[]> | undefined;
  type ControlStep = 'request' | 'drain' | 'window-1' | 'window-2' | 'window-3' | 'marker-analysis' | 'marker-gate' | 'silence-gate';
  type PeerObservation = ReturnType<typeof harness.observation>;
  const controls: { leakControlCaught: boolean; publicationSilent: boolean;
    silenceWindows?: SilenceWindow[];
    receiverWindows: { phase: ControlStep; window: ReceiverWindow }[];
    mutedCapture?: {
      requestedAtMs: number; startedAtMs: number; trackSid: string | undefined;
      trackMuteEvent: PeerObservation['lifecycle']['events'][number] | null;
      pcm: Pick<PCMCapture, 'sampleRate' | 'channels'>;
      lifecycle: Omit<PeerObservation['lifecycle'], 'afterDisconnect'>;
    };
    failure?: { phase: ControlStep; reason: ReceiverObservationError['reason'] | 'unobserved' | 'leak' | 'control-failed'; health?: ReceiverObservationError['health']; gapMs?: number } } =
    { leakControlCaught: false, publicationSilent: false, receiverWindows: [] };
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
      const requestedAtMs = performance.now();
      await step('drain', () => delay(500));
      const startedAtMs = performance.now();
      await harness.act({ type: 'capture' });
      const observe = async () => {
        const retain = (windows: ReceiverWindow[]) => controls.receiverWindows.push(
          ...windows.map(window => ({ phase: controlPhase, window })));
        pendingReceiver = monitorReceiver(() => harness.status(), { deadlineMs: resultDeadlineMs! });
        try { retain(await pendingReceiver); }
        catch (error) {
          if (error instanceof ReceiverObservationError) {
            retain(error.windows);
            controls.failure = { phase: controlPhase, reason: error.reason, health: error.health, gapMs: error.gapMs };
          }
          throw error;
        }
      };
      if (request.url === '/leak-control') {
        await step('window-1', observe);
        // Three seconds cover an arbitrary emission phase, allowed drift and the complete post-roll.
        for (const window of ['window-2', 'window-3'] as const) {
          await step(window, observe);
        }
        uplinkCapture = harness.observation().capture;
        uplinkEvidence = await step('marker-analysis', () => measureMarkerAsync(uplinkCapture!, uplink, 'host-poll'));
        controlPhase = 'marker-gate';
        assert.ok(uplinkEvidence.clean && uplinkEvidence.complete && uplinkEvidence.postRollObserved, 'Complete unmuted tones-v2 marker and post-roll were not received');
        controls.leakControlCaught = true;
      } else {
        controlPhase = 'silence-gate';
        const trackSid = harness.status().activeTrackSid;
        pendingSilence = step('silence-gate', () => observeSilence(() => {
          const state = harness.status();
          return { ...state, samples: state.receivedSamples };
        }, { durationMs: 1000, deadlineMs: resultDeadlineMs!, gapLimitMs: 250 }));
        try {
          controls.silenceWindows = await pendingSilence;
          controls.publicationSilent = true;
        } finally {
          const { capture, lifecycle: { afterDisconnect: _, ...lifecycle } } = harness.observation();
          const trackMuteEvent = trackSid === undefined ? null : lifecycle.events.findLast(event =>
            event.kind === 'trackMuted' && event.identity === appParticipant && event.trackSid === trackSid) ?? null;
          // The peer retains at most three seconds of mono PCM per capture.
          controls.mutedCapture = { requestedAtMs, startedAtMs, trackSid, trackMuteEvent, lifecycle,
            pcm: { sampleRate: capture.sampleRate, channels: capture.channels } };
        }
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
  let launchAttempted = false;
  const terminate = () => launchAttempted
    ? command('xcrun', ['simctl', 'terminate', simulator, bundle], 20_000)
        .catch(() => { /* The app may have already exited. */ })
    : undefined;
  let terminationOnAbort: ReturnType<typeof terminate>;
  const stop = () => {
    terminationOnAbort = terminate();
    control.closeAllConnections();
    harness.abort();
  };
  signal.addEventListener('abort', stop, { once: true });
  try {
    signal.throwIfAborted();
    await deadline(5000, 'Control listener', () => new Promise<void>(resolve => control.listen(0, '127.0.0.1', resolve)));
    const controlAddress = control.address();
    assert.ok(controlAddress && typeof controlAddress !== 'string');
    await phase('peer.publish', () => harness.act({ type: 'publish', markerId: downlink.id }));
    const result = join(container, 'Documents/media-result.json');
    for (const name of ['result', 'decoded', 'output', 'silence-windows']) rmSync(join(container, `Documents/media-${name}.json`), { force: true });
    writeFileSync(join(container, 'Documents/media-fixture.json'), JSON.stringify({
      ...harness.credentials(appParticipant), control: `http://127.0.0.1:${controlAddress.port}`,
      profile: "tones-v2", uplinkFrequencies: uplink.frequencies,
    }), { mode: 0o600 });
    launchAttempted = true;
    const launched = await simctl('launch', '--terminate-running-process', simulator, bundle);
    if (trackSimulatorApp) trackSimulatorApp(Number(/:\s*(\d+)\s*$/.exec(launched)?.[1]));
    resultDeadlineMs = performance.now() + 30_000;
    resultPhase.resolve();
    await phase('example.result', async () => {
      while (!existsSync(result) && performance.now() < resultDeadlineMs!) {
        await delay(Math.min(100, resultDeadlineMs! - performance.now()), undefined, { signal });
      }
      if (!existsSync(result)) {
        // Finish serialization of an already-expired host observation; this grants no observation time.
        await Promise.allSettled([pendingSilence, pendingReceiver]);
        const nativeWindows = join(container, 'Documents/media-silence-windows.json');
        writeUnobservedResult(output, resultDeadlineMs!, controls, nativeWindows);
        throw new Error('Result budget ended: unobserved');
      }
    });
    const evidence: unknown = JSON.parse(readFileSync(result, 'utf8'));
    let nativeFailure: unknown;
    try {
      assertNativePassed(evidence);
      assertNativeTeardown((evidence as { teardown?: unknown }).teardown);
    } catch (error) { nativeFailure = error; }
    uplinkCapture ??= harness.observation().capture;
    if (!nativeFailure) uplinkEvidence ??= await measureMarkerAsync(uplinkCapture, uplink, 'host-poll');
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
    writeFileSync(output, JSON.stringify({ processing, native: evidence, startupDiagnostics: diagnoseNativeStartup(evidence), farEnd: controls,
      pcm: { fromDevice: uplinkCapture, toDevice: downlinkCaptures },
      receiver: harness.status(),
      markers: { fromDevice: uplinkEvidence, toDevice: downlinkEvidence } }, null, 2));
    console.log(JSON.stringify({ processing, markers: { fromDevice: uplinkEvidence, toDevice: downlinkEvidence } }));
    if (process.env.GITHUB_STEP_SUMMARY) {
      let report = markerReport(`${processing}: fromDevice / farEnd`, uplinkEvidence);
      for (const [stage, measurement] of Object.entries(downlinkEvidence)) report +=
        measurement && 'channels' in measurement ? markerReport(`${processing}: toDevice / ${stage}`, measurement)
          : `\n### ${processing}: toDevice / ${stage}\n\nMissing or invalid PCM observation.\n`;
      appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
    }
    if (nativeFailure) throw nativeFailure;
    assert.ok((uplinkEvidence as ReturnType<typeof measureMarker> | null)?.clean && (uplinkEvidence as ReturnType<typeof measureMarker> | null)?.complete && (uplinkEvidence as ReturnType<typeof measureMarker> | null)?.postRollObserved &&
      Object.values(downlinkEvidence).every(value => value?.complete && 'clean' in value && value.clean && "postRollObserved" in value && value.postRollObserved),
      'A complete tones-v2 marker with every slot >= 0.8 and post-roll coverage is required in both directions');
    assert.ok(controls.leakControlCaught && controls.publicationSilent, 'Far-end controls did not complete');
  } finally {
    signal.removeEventListener('abort', stop);
    control.closeAllConnections(); control.close();
    await terminationOnAbort;
    // An interrupted launch may still have been completing during the first termination request.
    await terminate();
    try {
      await deadline(25_000, 'Harness cleanup', async () => { await harness.stop(); await dispose(); });
      signal.throwIfAborted();
    } catch (error) { harness.abort(); throw error; }
    finally {
      clearTimeout(watchdog);
      process.removeListener('SIGALRM', hardStop);
      rmSync(harnessDirectory, { recursive: true, force: true });
    }
  }
}, { localDestination: requestedSimulator ? { simulator: requestedSimulator } : undefined }).catch(error => {
  if (process.exitCode !== 124) throw error;
  console.error(error instanceof Error ? error.message : 'Media feasibility timed out');
  process.exit(124);
});
