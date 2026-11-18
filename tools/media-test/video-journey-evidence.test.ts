import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessJourneyVideo, assertRemoteProducer, remoteUplinkCoverage, type VideoSnapshot } from './video-journey-evidence.ts';
import { VideoObservation, type VideoSourceReceipt } from './video-observation.ts';
import type { NativeVideoEvent } from './native-video-evidence.ts';
import type { NativeVideoPlane } from './native-synthetic-video.ts';
import { videoLuma, type VideoMarker } from './video-marker.ts';
import { heldOutputReceipt, type JourneyAudio } from './video-journey-audio.ts';

test('a held call without an output tap requires observed SDK deactivation, engine stop and no output callbacks', () => {
  const stage = { sampleRate: 48_000, retainedSamples: 0, transportCount: 0, transportStable: false,
    observation: { installed: true, frameSeconds: 0 }, droppedCallbacks: 0, lastCallbackAtMs: 1050 };
  const audio: JourneyAudio = {
    decoded: stage, output: { ...stage, observation: { installed: false, frameSeconds: 0 } },
    audioActive: false, audioEngineRunning: false, audioOutputAvailable: false, audioEngineStoppedAtMs: 1100,
    startup: { lastAudioDeactivatedAtMs: 1120 }, heldOutputStartAtMs: 1300, onHold: true, audioMode: 'video', outputPorts: [],
    droppedMonitorTicks: 0, monitorTicksMs: [1400, 1600, 1800, 2000, 2200],
  };
  assert.equal(heldOutputReceipt(audio, 950, 1000, 2299), undefined);
  assert.deepEqual(heldOutputReceipt(audio, 950, 1000, 2300),
    { kind: 'engineStopped', stoppedAtMs: 1100, deactivatedAtMs: 1120 });
  assert.throws(() => heldOutputReceipt({ ...audio, audioEngineRunning: true }, 950, 1000, 2300), /verified engine stop/);
  assert.throws(() => heldOutputReceipt({ ...audio, startup: {} }, 950, 1000, 2300), /verified engine stop/);
  assert.throws(() => heldOutputReceipt({ ...audio, monitorTicksMs: [] }, 950, 1000, 2300), /Unobserved/);
  assert.throws(() => heldOutputReceipt({ ...audio,
    output: { ...audio.output, lastCallbackAtMs: 1200 } }, 950, 1000, 2300), /verified engine stop/);
});

const fixture = '01234567-89ab-cdef-0123-456789abcdef';
const nativeClock = '01234567-89ab-cdef-0123-456789abcdaa';
const hostClock = '01234567-89ab-cdef-0123-456789abcdbb';

function setup() {
  let now = 11005;
  const observer = new VideoObservation({ fixture, direction: 0, epoch: 1, participant: 'example', publication: 'up' },
    () => now, hostClock);
  const enabled: NativeVideoEvent = { sequence: 2, kind: 'changed', hasVideo: true, connected: true, source: 'server', atMs: 1000 };
  const ended: NativeVideoEvent = { sequence: 3, kind: 'ended', hasVideo: true, connected: false, source: null, atMs: 3400 };
  const mark = (direction: 0 | 1, counter: number, sourceTimeUs: number): VideoMarker => ({ fixture, direction, epoch: 1, counter, sourceTimeUs });
  const up = Array.from({ length: 23 }, (_, i) => mark(0, i, (1010 + i * 100) * 1000));
  const down = Array.from({ length: 23 }, (_, i) => mark(1, i, (11030 + i * 100) * 1000));
  const y: NativeVideoPlane = { width: 160, height: 120, stride: 160, byteCount: 19200, complete: true, minimum: 16, maximum: 235, sample: [128] };
  for (const marker of up) {
    now = marker.sourceTimeUs / 1000 + 10030;
    observer.tick();
    const pixels = new Uint8Array(160 * 120 * 3 / 2).fill(128);
    pixels.set(videoLuma(marker));
    observer.receive(pixels, 160, 120, BigInt(marker.sourceTimeUs));
  }
  now = 13410;
  observer.tick();
  observer.record('unpublished');
  for (now = 13500; now <= 14400; now += 100) observer.tick();
  const source: VideoSourceReceipt = { participant: 'example', publication: 'up', clockID: nativeClock,
    generated: up, stoppedAtUs: 3401000, finalCounter: 22, finalEpoch: 1, pacingTaskJoined: true,
    skippedTicks: 0, rejectedSubmissions: 0, postStopCaptureRejects: 1 };
  const remoteSource: VideoSourceReceipt = { ...source, participant: 'far-end', publication: 'down',
    clockID: hostClock, generated: down, stoppedAtUs: 13380000 };
  const snapshot = (observedAtMs: number): VideoSnapshot => ({
    reply: { observedAtMs, clockId: nativeClock, phaseId: 'live', phaseAtMs: 100, sessionId: fixture,
      evidence: {} },
    bracket: { nativeMs: observedAtMs, clockID: nativeClock, hostClockID: hostClock,
      sentMs: observedAtMs + 9998, receivedMs: observedAtMs + 10002 },
    sdk: { clockId: nativeClock, observedAtMs, events: [enabled, ended], hasVideo: true, connected: false, onHold: null },
    media: { clockID: nativeClock, fixture, observedAtMs, publication: null, publicationMuted: null, roomConnected: false,
      remotePublications: [],
      epochs: [{ epoch: 1, afterCounter: 0, anchorAtUs: 1010000, publication: 'up', source }],
      receivers: [{ publication: 'down', observedAtUs: 4400000, queueHighWaterMark: 1,
        arrivals: down.map(marker => ({ atUs: marker.sourceTimeUs - 9960000, marker, y, u: null, v: null,
          bufferType: 'i420', classification: 'source', mediaTimestampNs: null, rtpTimestamp: null })),
        lifecycle: [{ kind: 'receiverAttached', atUs: 1010000 }, ...Array.from({ length: 33 },
          (_, i) => ({ kind: 'receiverHeartbeat' as const, atUs: (1100 + i * 100) * 1000 }))] }],
      actions: [{ kind: 'remoteUnpublished', publication: 'down', atMs: 3390 }, { kind: 'roomDisconnected', publication: null, atMs: 3420 }],
    },
  });
  return { snapshot: snapshot(4400), source, remoteSource, observer, enabled: { event: enabled, sample: snapshot(1020) },
    ended: { event: ended, sample: snapshot(3410), actionAtMs: 13380, operation: 'stop' as const } };
}

test('duplex terminal assessment retains clock uncertainty and requires decoded coverage in both directions', () => {
  const f = setup(), uplink = f.observer.receipt();
  const result = assessJourneyVideo(f.snapshot, f.enabled, 1, f.remoteSource, uplink, f.ended);
  assert.equal(result.up?.offPassed, true, JSON.stringify(result.up));
  assert.equal(result.down.offPassed, true, JSON.stringify(result.down));
  assert.deepEqual(result.up.windows, [10, 10]);
  assert.ok(result.down.firstMs! > 0);
  assert.throws(() => assessJourneyVideo(f.snapshot, f.enabled, 1, { ...f.remoteSource, clockID: nativeClock }, uplink, f.ended), /Foreign journey clock/);
  const cut = { ...uplink, events: [...uplink.events, { kind: 'failed' as const, atMs: 14100 }] };
  assert.equal(assessJourneyVideo(f.snapshot, f.enabled, 1, f.remoteSource, cut, f.ended).up?.offPassed, false);
});

test('a post-end receive-only image cannot qualify if content is ambiguous', () => {
  const f = setup(), receiver = f.snapshot.media.receivers[0]!;
  const ambiguous = { ...receiver.arrivals[0]!, marker: null, classification: 'ambiguous' as const, atUs: 3600000 };
  const state = { ...f.snapshot, media: { ...f.snapshot.media,
    receivers: [{ ...receiver, arrivals: [...receiver.arrivals, ambiguous] }] } };
  const result = assessJourneyVideo(state, f.enabled, 1, f.remoteSource, undefined, f.ended);
  assert.equal(result.down.offPassed, false);
  assert.equal(result.down.corrupt, 1);
});

test('remote leave still requires native receiver coverage and the actual final app producer', () => {
  const f = setup(), terminal = assessJourneyVideo(f.snapshot, f.enabled, 1, f.remoteSource, undefined, f.ended);
  assert.equal(terminal.down.offPassed, true);
  assert.equal(terminal.up, undefined);
  assert.deepEqual(remoteUplinkCoverage, { verdict: 'unexercised', reason: 'single far-end peer' });
  assert.equal(assertRemoteProducer(f.snapshot, 1, 'up', f.ended.event).source, f.source);
  assert.throws(() => assertRemoteProducer(f.snapshot, 1, 'other', f.ended.event), /producer boundary/);
  f.source.stoppedAtUs = 3399999;
  assert.throws(() => assertRemoteProducer(f.snapshot, 1, 'up', f.ended.event), /producer boundary/);
  f.source.stoppedAtUs = 3401000;
  f.source.pacingTaskJoined = false;
  assert.throws(() => assertRemoteProducer(f.snapshot, 1, 'up', f.ended.event), /producer boundary/);
});
