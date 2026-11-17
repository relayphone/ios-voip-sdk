import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import type { NativeJourneyReply } from './native-journey.ts';
import { readNativeVideoEvidence, nativeJourneyFailure, NativeJourneyFailure } from './native-video-evidence.ts';

function fixture() {
  const clockId = randomUUID();
  const video = { clockID: clockId.toUpperCase(), observedAtMs: 350, hasVideo: null as boolean | null,
    onHold: null as boolean | null, connected: false, overflow: false,
    events: [
      { sequence: 1, kind: 'readySnapshot', hasVideo: true, connected: true, source: null as string | null, atMs: 100 },
      { sequence: 2, kind: 'changed', hasVideo: false, connected: true, source: 'server', atMs: 200 },
      { sequence: 3, kind: 'ended', hasVideo: false, connected: false, source: null, atMs: 300 },
    ] };
  const reply: NativeJourneyReply = { clockId, sessionId: randomUUID(), observedAtMs: 360,
    phaseId: 'phase', phaseAtMs: 50, evidence: { video } };
  return { video, reply };
}

test('native video retains original event times and source after the SDK removes the ended call', () => {
  const f = fixture(), evidence = readNativeVideoEvidence(f.reply);
  assert.equal(evidence.clockId, f.reply.clockId);
  assert.equal(evidence.hasVideo, null); assert.equal(evidence.connected, false);
  assert.equal(evidence.events[0]!.kind, 'readySnapshot'); assert.equal(evidence.events[0]!.source, null);
  assert.deepEqual(evidence.events.map(e => e.atMs), [100, 200, 300]);
  assert.equal(evidence.events[1]!.source, 'server');
  f.video.events[1]!.atMs = 900;
  assert.equal(evidence.events[1]!.atMs, 200);
  assert.ok(Object.isFrozen(evidence.events)); assert.ok(Object.isFrozen(evidence.events[1]));
});

test('acknowledgement, current state and same-value commands do not invent a video event', () => {
  const f = fixture();
  f.video.events = []; f.video.hasVideo = true; f.video.onHold = false; f.video.connected = true;
  assert.deepEqual(readNativeVideoEvidence(f.reply).events, []);
  assert.throws(() => readNativeVideoEvidence({ ...f.reply, evidence: { commandId: randomUUID() } }), /native video/);
});

test('missing, foreign, unordered, overflowing and ambiguous native evidence fails closed', () => {
  const mutations: ((f: ReturnType<typeof fixture>) => void)[] = [
    f => { f.video.clockID = randomUUID(); },
    f => { f.video.observedAtMs = 400; },
    f => { f.video.observedAtMs = 20; },
    f => { f.video.observedAtMs = NaN; },
    f => { f.video.overflow = true; },
    f => { f.video.events[1]!.sequence = 1; },
    f => { f.video.events[1]!.atMs = 80; },
    f => { f.video.events[1]!.atMs = 400; },
    f => { f.video.events[1]!.source = null; },
    f => { f.video.events[0]!.source = 'app'; },
    f => { f.video.events[0]!.kind = 'acknowledged'; },
    f => { f.video.connected = true; },
    f => { f.video.onHold = false; },
    f => { f.video.events = Array.from({ length: 257 }, () => f.video.events[0]!); },
  ];
  for (const mutate of mutations) {
    const f = fixture(); mutate(f);
    assert.throws(() => readNativeVideoEvidence(f.reply), /native video/);
  }
});

test('host failure errors include only allowlisted operation/category and numeric code', () => {
  const error = nativeJourneyFailure({ operation: 'prepare', category: 'livekit', code: 101,
    message: 'fixture-token-secret', domain: 'fixture-token-secret' }, 'attempt');
  assert.ok(error instanceof NativeJourneyFailure);
  assert.equal(error.operation, 'prepare'); assert.equal(error.category, 'livekit'); assert.equal(error.code, 101);
  assert.match(error.message, /reported failure: prepare\/livekit\/101/);
  assert.ok(!error.stack!.includes('fixture-token-secret'));
  for (const invalid of [
    { operation: 'fixture-token-secret', category: 'url', code: 1 },
    { operation: 'prepare', category: 'fixture-token-secret', code: 1 },
    { operation: 'video', category: 'other', code: Infinity },
  ]) assert.throws(() => nativeJourneyFailure(invalid, 'command'), /Invalid native failure code/);
  assert.match(nativeJourneyFailure(undefined, 'command').message, /command rejected/);
});
