import assert from 'node:assert/strict';
import { createMarker, detectMarker } from '../../expo/src/testing/marker.ts';
import type { MediaMarker } from '../../expo/src/testing/types.ts';
import type { IsolatedHarness } from './harness.ts';
import type { PCMCapture } from './marker-evidence.ts';
import { measureMarkerAsync } from './measure-marker.ts';
import type { NativeJourneyReply } from './native-journey.ts';

export const journeyCaptureSeconds = 4;
// A hosted capture acknowledgement stalled for 1,378 ms with simultaneous observation lag.
export const journeyAudioQueueMs = 1_600;
// The native hold command also allows 300 ms for pre-hold media to drain.
export const heldAudioDrainMs = 300;

type AudioStage = { pcm?: PCMCapture; sampleRate: number; retainedSamples: number; transportCount: number; lastTransportSample: number;
  observation: { installed: boolean; frameSeconds: number };
  droppedCallbacks: number; lastCallbackAtMs?: number };
export type JourneyAudio = {
  decoded: AudioStage; output: AudioStage; audioActive: boolean; audioEngineRunning: boolean;
  remoteAudioPublication?: string;
  audioOutputAvailable: boolean;
  audioEngineStoppedAtMs?: number;
  heldOutputStartAtMs?: number;
  startup: { lastAudioDeactivatedAtMs?: number };
  onHold: boolean; audioMode: string; outputPorts: string[];
  monitorTicksMs: number[]; droppedMonitorTicks: number;
  heldOutput?: { activeWindow?: unknown; windows: { verdict: 'silent' | 'leak' | 'unobserved';
    startSeconds: number; endSeconds: number; coveredSeconds: number; gaps: unknown[] }[] };
};

export function readJourneyAudio(reply: NativeJourneyReply): JourneyAudio {
  const audio = reply.evidence as JourneyAudio;
  assert.ok(audio && Number.isSafeInteger(audio.droppedMonitorTicks) && audio.droppedMonitorTicks === 0,
    'Missing native audio coverage');
  for (const stage of [audio.decoded, audio.output]) {
    assert.equal(stage?.droppedCallbacks, 0, 'Incomplete native PCM callbacks');
  }
  return audio;
}

type HostStatus = Awaited<ReturnType<IsolatedHarness['status']>>;

export function hasUplinkSamples(host: HostStatus) {
  return host.connected && host.readerLive && host.trackAvailable && !host.publicationFailed &&
    host.receivedSamples >= 48_000 * 3;
}

export function hasDuplexSamples(audio: JourneyAudio, host: HostStatus) {
  return audio.audioActive && hasUplinkSamples(host) && [audio.decoded, audio.output].every(s =>
      s.observation.installed && s.sampleRate > 0 && s.retainedSamples >= s.sampleRate * journeyCaptureSeconds &&
      s.transportCount >= 2 && s.lastTransportSample >= s.sampleRate * journeyCaptureSeconds);
}

export async function captureDuplexAudio(audio: JourneyAudio, harness: IsolatedHarness) {
  assert.ok(audio.decoded.pcm && audio.output.pcm, 'Missing native PCM from the requested audio snapshot');
  const host = await harness.observation();
  return { pcm: { up: host.capture, decoded: audio.decoded.pcm, output: audio.output.pcm },
    uplinkCapture: { retainedSamples: host.capture.channels[0]?.length ?? 0, receivedSamples: host.receiver.receivedSamples } };
}

export async function measureDuplexAudio(pcm: Awaited<ReturnType<typeof captureDuplexAudio>>['pcm'],
  markers: { up: MediaMarker; down: MediaMarker }) {
  const [up, decoded, output] = await Promise.all([
    measureMarkerAsync(pcm.up, markers.up, 'host-poll'),
    measureMarkerAsync(pcm.decoded, markers.down),
    measureMarkerAsync(pcm.output, markers.down),
  ]);
  return { up, decoded, output };
}

export function heldOutputReceipt(audio: JourneyAudio, beforeHoldAtMs: number, holdAtMs: number, observedAtMs: number) {
  assert.ok(audio.onHold && audio.decoded.observation.installed, 'Hold lost the call or native decoded audio observer');
  const receipt = audio.heldOutput;
  assert.ok(!receipt?.windows.some(w => w.verdict === 'leak'), 'Held native output leaked audio');
  if (!audio.output.observation.installed || !audio.audioActive || !audio.audioEngineRunning) {
    const { audioEngineStoppedAtMs: stoppedAtMs, startup: { lastAudioDeactivatedAtMs: deactivatedAtMs } } = audio;
    const lastCallbackAtMs = audio.output.lastCallbackAtMs;
    assert.ok(audio.audioActive === false && audio.audioEngineRunning === false && audio.audioOutputAvailable === false &&
      typeof stoppedAtMs === 'number' && Number.isFinite(stoppedAtMs) &&
      stoppedAtMs >= beforeHoldAtMs && stoppedAtMs <= observedAtMs &&
      typeof deactivatedAtMs === 'number' && deactivatedAtMs >= holdAtMs && deactivatedAtMs <= observedAtMs &&
      typeof lastCallbackAtMs === 'number' && Number.isFinite(lastCallbackAtMs) && lastCallbackAtMs <= stoppedAtMs,
    'Hold lost the native output observer without a verified engine stop');
    const drainEndMs = audio.heldOutputStartAtMs;
    assert.ok(typeof drainEndMs === 'number' && drainEndMs >= holdAtMs && drainEndMs <= observedAtMs,
      'Missing native hold drain');
    const startMs = Math.max(drainEndMs, stoppedAtMs, deactivatedAtMs);
    if (observedAtMs - startMs < 1000) return;
    let last = startMs;
    for (const tick of [...audio.monitorTicksMs.filter(tick => tick >= startMs), observedAtMs]) {
      assert.ok(tick >= last && tick - last <= 250, 'Unobserved held engine stop');
      last = tick;
    }
    return { kind: 'engineStopped' as const, stoppedAtMs, deactivatedAtMs };
  }
  if (!receipt) return;
  if (receipt.activeWindow) return;
  const last = receipt.windows.at(-1);
  assert.ok(last?.verdict === 'silent' && last.startSeconds * 1000 >= holdAtMs &&
    last.endSeconds * 1000 <= observedAtMs && last.endSeconds - last.startSeconds >= 1 &&
    last.coveredSeconds >= 0.96 && last.gaps.length === 0, 'Held output lacks a complete native silence window');
  return { kind: 'pcmSilence' as const, receipt };
}

export function readAudioRoute(audio: JourneyAudio, video: boolean) {
  assert.equal(audio.audioMode, video ? 'video' : 'voice');
  assert.ok(Array.isArray(audio.outputPorts) && audio.outputPorts.length > 0, 'No observed output route');
  return audio.outputPorts;
}

export async function assertLocalAudioDeparture(harness: IsolatedHarness, armedAtMs: number, phaseIds: readonly string[]) {
  const { receiver, lifecycle } = await harness.observation();
  const after = lifecycle.afterDisconnect;
  assert.ok(receiver.connected && lifecycle.droppedEvents === 0 && after?.identity === 'example' &&
    after.startedAtMs >= armedAtMs && after.overflowSamples === 0, 'Incomplete far-end audio departure');
  for (const kind of ['trackUnpublished', 'participantDisconnected'] as const) {
    assert.ok(lifecycle.events.some(e => e.kind === kind && e.identity === 'example' && e.atMs >= armedAtMs),
      `Missing far-end audio ${kind}`);
  }
  assert.ok(lifecycle.observedAtMs - after.startedAtMs >= 1000, 'Far-end audio departure window is incomplete');
  assert.ok(!lifecycle.events.some(e => e.atMs > after.startedAtMs && e.identity === 'example' &&
    (e.kind === 'trackPublished' || e.kind === 'participantConnected')), 'Audio republished after the call ended');
  const pcm = Float32Array.from(after.channels[0]!);
  for (const id of phaseIds) assert.equal(detectMarker(pcm, after.sampleRate, createMarker(id)), null, 'Audio marker after departure');
  return lifecycle;
}
