import assert from 'node:assert/strict';
import { createMarker, detectMarker } from '../../expo/src/testing/marker.ts';
import type { MediaMarker } from '../../expo/src/testing/types.ts';
import type { MediaHarness } from './harness.ts';
import type { PCMCapture } from './marker-evidence.ts';
import { measureMarkerAsync } from './measure-marker.ts';
import type { NativeJourneyReply } from './native-journey.ts';

type AudioStage = { pcm?: PCMCapture; sampleRate: number; retainedSamples: number; transportCount: number; transportStable: boolean;
  observation: { installed: boolean; frameSeconds: number };
  droppedCallbacks: number; lastCallbackAtMs?: number };
export type JourneyAudio = {
  decoded: AudioStage; output: AudioStage; audioActive: boolean; audioEngineRunning: boolean;
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

export function hasDuplexSamples(audio: JourneyAudio, harness: MediaHarness) {
  const host = harness.status();
  return audio.audioActive && host.connected && host.readerLive && host.trackAvailable &&
    host.receivedSamples >= 48_000 * 3 && [audio.decoded, audio.output].every(s =>
      s.observation.installed && s.observation.frameSeconds >= 3 &&
      s.retainedSamples >= s.sampleRate * 3 && s.transportCount >= 2);
}

export async function assertDuplexAudio(audio: JourneyAudio, harness: MediaHarness, markers: { up: MediaMarker; down: MediaMarker }) {
  assert.ok(audio.decoded.pcm && audio.output.pcm, 'Missing native PCM from the requested audio snapshot');
  const [up, decoded, output] = await Promise.all([
    measureMarkerAsync(harness.observation().capture, markers.up, 'host-poll'),
    measureMarkerAsync(audio.decoded.pcm, markers.down),
    measureMarkerAsync(audio.output.pcm, markers.down),
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

export function assertLocalAudioDeparture(harness: MediaHarness, armedAtMs: number, phaseIds: readonly string[]) {
  const { receiver, lifecycle } = harness.observation();
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
