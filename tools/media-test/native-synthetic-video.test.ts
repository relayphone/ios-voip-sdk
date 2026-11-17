import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import type { NativeJourneyReply } from './native-journey.ts';
import { bindNativeVideoReceiver, bindNativeVideoSource, readNativeSyntheticVideo, sampleNativeVideoClock } from './native-synthetic-video.ts';
import { hostVideoBoundary, type VideoReceipt, type VideoSourceReceipt } from './video-observation.ts';
import { inspectVideoImage, videoLuma, type VideoMarker } from './video-marker.ts';

function nativeImage(marker?: VideoMarker, blank = false) {
  const width = blank ? 8 : 160, height = blank ? 8 : 120;
  const data = new Uint8Array(width * height * 3 / 2).fill(128);
  if (marker) data.set(videoLuma(marker));
  const image = inspectVideoImage(data, width, height);
  const plane = (p: typeof image.y) => ({ ...p, stride: p.width, byteCount: p.width * p.height,
    sample: Buffer.from(p.sample).toString('base64') });
  return { marker: image.marker ?? null, provenance: { classification: image.kind, bufferType: 'i420', mediaTimestampNs: -42, rtpTimestamp: 43,
    y: plane(image.y), u: plane(image.u), v: plane(image.v) } };
}
function fixture() {
  const fixtureID = randomUUID(), clockID = randomUUID(), hostClockID = randomUUID();
  const generated = [0, 1, 2].map(counter => ({ fixture: fixtureID, direction: 0 as const, epoch: 1, counter, sourceTimeUs: (counter + 1) * 100_000 }));
  const reverse: VideoMarker = { fixture: fixtureID, direction: 1, epoch: 1, counter: 5, sourceTimeUs: 1_000_000_000_000 };
  const source = { fixture: fixtureID.toUpperCase(), direction: 0, epoch: 1, clockID: clockID.toUpperCase(), generated,
    skippedTicks: 0, rejectedSubmissions: 0, nextCounter: 3, finalCounter: 2 as number | null,
    finalEpoch: 1 as number | null, stoppedAtUs: 310_000 as number | null, pacingTaskJoined: true, postStopCaptureRejects: 1 };
  const observation = { clockID, observedAtUs: 350_000, overflow: false, queueHighWaterMark: 1,
    arrivals: [{ atUs: 200_000, ...nativeImage(reverse) }, { atUs: 210_000, ...nativeImage(reverse) },
      { atUs: 220_000, ...nativeImage(undefined, true) }, { atUs: 230_000, ...nativeImage() }],
    lifecycle: [{kind: 'receiverAttached', atUs: 190_000}, {kind: 'receiverHeartbeat', atUs: 340_000}] };
  const syntheticVideo = { clockID, observedAtMs: 350, overflow: false, failure: null as unknown,
    publicationSID: null as string | null, publicationMuted: null as boolean | null, roomConnected: false,
    epochs: [{ epoch: 1, anchor: {clockID, atUs: 150_000, afterCounter: 0}, publicationSID: 'native-video' as string | null, source }],
    actions: [{ kind: 'published', atMs: 160, publicationSID: 'native-video' }, {kind: 'stopped', atMs: 320, publicationSID: 'native-video'}],
    remotePublications: ['reverse-video'], receivers: [{publicationSID: 'reverse-video', observation}] };
  const reply: NativeJourneyReply = { sessionId: randomUUID(), clockId: clockID, phaseId: 'live', phaseAtMs: 10,
    observedAtMs: 360, evidence: {syntheticVideo} };
  const uplink: VideoReceipt = {clockID: hostClockID, scope: {fixture: fixtureID, direction: 0, epoch: 1, participant: 'native-app', publication: 'native-video'},
    startedAtMs: 0, observedAtMs: 1000, arrivals: [], ticks: [], events: [], overflow: false};
  const downlink: VideoSourceReceipt = { participant: 'far-end', publication: 'reverse-video', clockID: hostClockID,
    generated: [reverse], pacingTaskJoined: false, postStopCaptureRejects: 0, skippedTicks: 0, rejectedSubmissions: 0 };
  return { fixtureID, clockID, hostClockID, source, observation, syntheticVideo, reply, uplink, downlink };
}

test('native source ledgers bind only to the actual independent subscription and preserve the seed fence', () => {
  const f = fixture(), native = readNativeSyntheticVideo(f.reply, f.fixtureID.toUpperCase());
  const source = bindNativeVideoSource(native, 1, f.uplink, 'native-app');
  assert.deepEqual(source.generated, f.source.generated);
  assert.equal(source.finalCounter, 2); assert.equal(source.stoppedAtUs, 310_000);
  assert.equal(native.epochs[0]!.afterCounter, 0); assert.equal(native.epochs[0]!.anchorAtUs, 150_000);
  f.source.generated[0]!.counter = 99;
  assert.equal(source.generated[0]!.counter, 0); assert.equal(native.epochs[0]!.source.generated[0]!.counter, 0);
  assert.ok(Object.isFrozen(native.epochs[0]!.source.generated));
  for (const scope of [{ participant: 'wrong' }, { publication: 'wrong' }, { fixture: randomUUID() }, { epoch: 2 }, { direction: 1 as const }])
    assert.throws(() => bindNativeVideoSource(native, 1, {...f.uplink, scope: {...f.uplink.scope, ...scope}}, 'native-app'));
  assert.throws(() => bindNativeVideoSource(native, 2, f.uplink, 'native-app'));
  assert.throws(() => readNativeSyntheticVideo(f.reply, randomUUID()));
});

test('decoded native receiver retains real marker, duplicate, content-free and ambiguous callbacks on its own clock', () => {
  const f = fixture(), native = readNativeSyntheticVideo(f.reply, f.fixtureID);
  const receiver = bindNativeVideoReceiver(native, f.downlink);
  assert.deepEqual(receiver.arrivals.map(a => a.classification), ['source', 'source', 'contentFree', 'ambiguous']);
  assert.deepEqual(receiver.arrivals.map(a => a.atUs), [200_000, 210_000, 220_000, 230_000]);
  // The remote source clock has a different origin; marker time is not compared with native arrival time.
  assert.equal(receiver.arrivals[0]!.marker!.sourceTimeUs, 1_000_000_000_000);
  assert.equal(receiver.lifecycle.length, 2);
  assert.equal(receiver.arrivals[0]!.mediaTimestampNs, -42); assert.equal(receiver.arrivals[0]!.rtpTimestamp, 43);
  f.observation.arrivals[0]!.atUs = 999;
  assert.equal(receiver.arrivals[0]!.atUs, 200_000);
  assert.throws(() => bindNativeVideoReceiver(native, {...f.downlink, participant: 'other'}));
  assert.throws(() => bindNativeVideoReceiver(native, {...f.downlink, publication: 'other'}));
  assert.throws(() => bindNativeVideoReceiver(native, {...f.downlink, generated: []}));
  assert.throws(() => bindNativeVideoReceiver(native, {...f.downlink, generated: [{...f.downlink.generated[0]!, counter: 6}]}));
});

test('unpublished held-source epochs preserve absence and cannot bind to a claimed publication', () => {
  const f = fixture(); f.syntheticVideo.epochs[0]!.publicationSID = null;
  const native = readNativeSyntheticVideo(f.reply, f.fixtureID);
  assert.equal(native.epochs[0]!.publication, null);
  assert.throws(() => bindNativeVideoSource(native, 1, f.uplink, 'native-app'));
});

test('invalid native identity, source order, final boundaries, overflow and lifecycle controls fail closed', () => {
  const controls: ((f: ReturnType<typeof fixture>) => void)[] = [
    f => { f.syntheticVideo.clockID = randomUUID(); }, f => { f.syntheticVideo.observedAtMs = 400; },
    f => { f.syntheticVideo.overflow = true; }, f => { f.syntheticVideo.publicationSID = 'invented'; f.syntheticVideo.publicationMuted = false; },
    f => { f.source.clockID = randomUUID(); }, f => { f.source.generated[1]!.counter = 0; },
    f => { f.source.generated[1]!.sourceTimeUs = 400_000; }, f => { f.source.finalCounter = 1; },
    f => { f.source.finalEpoch = 2; }, f => { f.source.stoppedAtUs = 200_000; },
    f => { f.source.nextCounter = 2; }, f => { f.syntheticVideo.epochs[0]!.anchor.afterCounter = 3; },
    f => { f.syntheticVideo.epochs[0]!.anchor.atUs = 99_999; },
    f => { f.syntheticVideo.epochs[0]!.anchor.atUs = 250_000; },
    f => { f.syntheticVideo.actions[1]!.atMs = 100; }, f => { f.syntheticVideo.actions[1]!.kind = 'receiverReplaced'; },
    f => { f.observation.clockID = randomUUID(); }, f => { f.observation.overflow = true; },
    f => { f.observation.arrivals[1]!.atUs = 190_000; }, f => { f.observation.observedAtUs = 400_000; },
    f => { f.observation.lifecycle[1]!.atUs = 180_000; }, f => { f.observation.lifecycle[1]!.kind = 'invented'; },
    f => { f.syntheticVideo.receivers.push(f.syntheticVideo.receivers[0]!); },
    f => { f.observation.arrivals = Array.from({length: 4097}, () => f.observation.arrivals[0]!); },
  ];
  for (const mutate of controls) { const f = fixture(); mutate(f); assert.throws(() => readNativeSyntheticVideo(f.reply, f.fixtureID)); }
});

test('content-free evidence requires full uniform planes and non-source geometry; partial pixels remain ambiguous', () => {
  const controls: ((f: ReturnType<typeof fixture>) => void)[] = [
    f => { f.observation.arrivals[2]!.provenance.y.maximum = 135; },
    f => { f.observation.arrivals[2]!.provenance.u.complete = false; },
    f => { f.observation.arrivals[3]!.provenance.classification = 'contentFree'; },
    f => { f.observation.arrivals[0]!.marker = null; },
    f => { f.observation.arrivals[2]!.provenance.classification = 'source'; f.observation.arrivals[2]!.marker = f.downlink.generated[0]!; },
    f => { f.observation.arrivals[0]!.provenance.mediaTimestampNs = Number.MAX_SAFE_INTEGER + 1; },
    f => { f.observation.arrivals[0]!.provenance.y.sample = 'not-base64'; },
    f => { const y = f.observation.arrivals[0]!.provenance.y; y.minimum = 128; y.maximum = 128; y.sample = Buffer.alloc(16, 128).toString('base64'); },
  ];
  for (const mutate of controls) { const f = fixture(); mutate(f); assert.throws(() => readNativeSyntheticVideo(f.reply, f.fixtureID)); }
  const f = fixture(); f.observation.arrivals[3]!.provenance.y.complete = false;
  f.observation.arrivals[3]!.provenance.y.minimum = null; f.observation.arrivals[3]!.provenance.y.maximum = null;
  assert.equal(readNativeSyntheticVideo(f.reply, f.fixtureID).receivers[0]!.arrivals[3]!.classification, 'ambiguous');
});

test('native source failures expose only sanitized codes', () => {
  const f = fixture(); f.syntheticVideo.failure = {operation: 'video', category: 'livekit', code: 42, message: 'private-secret'};
  assert.throws(() => readNativeSyntheticVideo(f.reply, f.fixtureID), error => error instanceof Error &&
    error.message.includes('video/livekit/42') && !error.message.includes('private-secret'));
});

test('snapshot sampling uses actual send/receive and original native time, preserving uncertainty', async () => {
  const f = fixture(), signal = new AbortController().signal, budget = {signal, deadlineMs: 1000};
  let now = 100;
  const mailbox = { request: async (action: {operation: 'snapshot'}, forwarded: typeof budget) => {
    assert.deepEqual(action, {operation: 'snapshot'}); assert.equal(forwarded, budget); now = 120; return f.reply;
  } };
  const {reply, bracket} = await sampleNativeVideoClock(mailbox, budget, f.hostClockID, () => now);
  assert.equal(reply, f.reply); assert.equal(bracket.nativeMs, 360);
  assert.deepEqual(hostVideoBoundary(350, bracket), {earliest: 90, latest: 110});
  assert.equal(bracket.receivedMs - bracket.sentMs, 20);
});

test('snapshot sampling never renews deadlines or accepts aborted, backwards or expired observations', async () => {
  const f = fixture(), signal = new AbortController().signal;
  let calls = 0;
  const mailbox = {request: async () => {calls++; return f.reply;}};
  await assert.rejects(sampleNativeVideoClock(mailbox, {signal, deadlineMs: 1}, f.hostClockID, () => 2));
  assert.equal(calls, 0);
  let ticks = [10, 5];
  await assert.rejects(sampleNativeVideoClock(mailbox, {signal, deadlineMs: 100}, f.hostClockID, () => ticks.shift()!));
  ticks = [10, 101];
  await assert.rejects(sampleNativeVideoClock(mailbox, {signal, deadlineMs: 100}, f.hostClockID, () => ticks.shift()!));
  const aborted = new AbortController(); aborted.abort();
  await assert.rejects(sampleNativeVideoClock(mailbox, {signal: aborted.signal, deadlineMs: 100}, f.hostClockID, () => 10));
});


test('live and audio-only receipts stay distinct from terminal evidence, including equal-timestamp counter fences', () => {
  const f = fixture();
  f.source.stoppedAtUs = null; f.source.finalCounter = null; f.source.finalEpoch = null;
  f.source.pacingTaskJoined = false; f.source.postStopCaptureRejects = 0;
  f.syntheticVideo.publicationSID = 'native-video'; f.syntheticVideo.publicationMuted = false;
  f.source.generated[1]!.sourceTimeUs = 150_000;
  const native = readNativeSyntheticVideo(f.reply, f.fixtureID);
  assert.equal(native.epochs[0]!.source.stoppedAtUs, undefined);
  assert.equal(native.epochs[0]!.source.pacingTaskJoined, false);
  assert.equal(native.epochs[0]!.afterCounter, 0);
  f.syntheticVideo.epochs = []; f.syntheticVideo.publicationSID = null; f.syntheticVideo.publicationMuted = null;
  f.syntheticVideo.receivers = []; f.syntheticVideo.actions = []; f.syntheticVideo.remotePublications = [];
  assert.equal(readNativeSyntheticVideo(f.reply, f.fixtureID).epochs.length, 0);
});
