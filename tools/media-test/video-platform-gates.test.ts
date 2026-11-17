import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessVideo, measureVideo, videoGates, VideoObservation,
  type VideoGateInput, type VideoGateLimits, type VideoMeasurementOptions, type VideoSourceReceipt } from './video-observation.ts';
import { videoLuma, type VideoMarker } from './video-marker.ts';

// These are artificial control limits, not Android calibration candidates.
const android: VideoGateLimits = Object.freeze({ firstMs: 200, gapMs: 200, minimumFPS: 10, drainMs: 200, terminalCoverageMs: 500 });
function sample() {
  let now = 0;
  const scope = { fixture: '01234567-89ab-cdef-0123-456789abcdef', direction: 0 as const, epoch: 1, participant: 'app', publication: 'video' };
  const observer = new VideoObservation(scope, () => now);
  const source: VideoSourceReceipt = { participant: 'app', publication: 'video', clockID: 'native', generated: [],
    pacingTaskJoined: true, postStopCaptureRejects: 1, skippedTicks: 0, rejectedSubmissions: 0 };
  for (let counter = 0; counter < 25; counter++) {
    now = counter * 100; observer.tick();
    const marker: VideoMarker = { ...scope, counter, sourceTimeUs: now * 1000 };
    source.generated.push(marker);
    const bytes = new Uint8Array(160 * 120 * 3 / 2).fill(128); bytes.set(videoLuma(marker));
    observer.receive(bytes, 160, 120, BigInt(marker.sourceTimeUs));
  }
  now = 2500; observer.tick(); observer.record('unpublished');
  source.stoppedAtUs = 2500000; source.finalCounter = 24; source.finalEpoch = 1;
  for (now = 2600; now <= 3400; now += 100) observer.tick();
  now = 3400;
  const receipt = observer.receipt();
  const options: VideoMeasurementOptions = { participant: 'app', publication: 'video', nativeAnchorMs: 0, afterCounter: 0,
    nativeBoundaryMs: 2500, bracket: { clockID: 'native', hostClockID: receipt.clockID, nativeMs: 0, sentMs: 0, receivedMs: 0 },
    terminal: { clockID: 'native', hostClockID: receipt.clockID, nativeMs: 2500, sentMs: 2500, receivedMs: 2500 } };
  const assess = (gates: VideoGateLimits = android) => assessVideo(receipt, source, { ...options, platform: 'android', gates });
  return { source, receipt, options, assess };
}

test('explicit Android limits are isolated from the unchanged iOS defaults', () => {
  const f = sample(), original = structuredClone(videoGates);
  const ios = assessVideo(f.receipt, f.source, f.options);
  assert.equal(ios.offPassed, true);
  assert.deepEqual(assessVideo(f.receipt, f.source, { ...f.options, platform: 'ios' }), ios);
  assert.equal(f.assess().offPassed, true);
  assert.equal(f.assess({ ...android, firstMs: 50 }).onPassed, false);
  assert.equal(f.assess({ ...android, gapMs: 50 }).onPassed, false);
  f.receipt.arrivals = f.receipt.arrivals.filter((_, i) => i % 2 === 0);
  assert.equal(f.assess().onPassed, false);
  assert.equal(assessVideo(f.receipt, f.source, f.options).onPassed, true);
  assert.deepEqual(videoGates, original);
  assert.ok(Object.isFrozen(videoGates));
});

test('Android drain and terminal coverage are independent explicit gates', () => {
  const f = sample();
  f.receipt.arrivals.push({ ...f.receipt.arrivals[20]!, atMs: 2600 });
  const raw = measureVideo(f.receipt, f.source, f.options);
  assert.equal(raw.identifiedPostBoundaryArrivals, 1); assert.equal(raw.identifiedDrainMs, 100.001);
  assert.equal(raw.terminalObservedMs, 900);
  assert.equal(f.assess({ ...android, drainMs: 80 }).onPassed, true);
  assert.equal(f.assess({ ...android, drainMs: 80 }).offPassed, false);
  assert.equal(f.assess({ ...android, terminalCoverageMs: 1200 }).offPassed, false);
  assert.equal(f.assess().offPassed, true);
  assert.equal(assessVideo(f.receipt, f.source, f.options).offPassed, true);
  f.receipt.observedAtMs = 3800; f.receipt.ticks.push(3500, 3600, 3700, 3800);
  assert.equal(f.assess({ ...android, terminalCoverageMs: 1200 }).offPassed, true);
  f.options.terminal!.receivedMs += 200;
  assert.equal(f.assess({ ...android, terminalCoverageMs: 1200 }).offPassed, false);
});

test('raw calibration needs no platform limits and cannot claim a gate verdict', () => {
  const f = sample(), raw = measureVideo(f.receipt, f.source, f.options);
  assert.equal(raw.firstMs, 100.001); assert.equal(raw.gapMs, 100.001);
  assert.deepEqual(raw.windows, [10, 10]);
  assert.equal(raw.sourceStopLagMs, 0); assert.equal(raw.identifiedDrainMs, null);
  assert.equal(raw.identifiedPostBoundaryArrivals, 0);
  assert.equal(raw.integrity, true); assert.equal(raw.producer, true);
  assert.equal('onPassed' in raw, false); assert.equal('offPassed' in raw, false);
  f.receipt.arrivals = [];
  const empty = measureVideo(f.receipt, f.source, f.options);
  assert.equal(empty.firstMs, null); assert.deepEqual(empty.windows, []);
  assert.equal('onPassed' in empty, false);
});

test('Android requires a complete, safe gate input and cannot silently borrow iOS limits', () => {
  const f = sample();
  const invalid: unknown[] = [{ platform: 'android' }, { platform: 'android', gates: null },
    { platform: 'other', gates: android }];
  for (const key of Object.keys(android)) {
    const missing = { ...android } as Record<string, unknown>; delete missing[key];
    invalid.push({ platform: 'android', gates: missing });
    for (const value of [NaN, Infinity, -1, 0, '100']) invalid.push({ platform: 'android', gates: { ...android, [key]: value } });
  }
  for (const gates of [{ ...android, minimumFPS: 11 }, { ...android, minimumFPS: .5 },
    { ...android, terminalCoverageMs: 100 }, { ...android, windowMs: 2000 }, { ...android, width: 320 }]) invalid.push({ platform: 'android', gates });
  for (const input of invalid) assert.throws(() => assessVideo(f.receipt, f.source,
    { ...f.options, ...input as VideoGateInput }), /video gate/);
});

test('explicit platform gates cannot relax privacy, identity, observer health or the original fence', () => {
  const permissive = { firstMs: 10000, gapMs: 10000, minimumFPS: 1, drainMs: 2000, terminalCoverageMs: 2500 };
  for (const kind of ['corrupt', 'foreign', 'postBoundary', 'overflow', 'health', 'lifecycle', 'producer', 'replay'] as const) {
    const f = sample();
    f.receipt.observedAtMs = 5100;
    for (let t = 3500; t <= 5100; t += 100) f.receipt.ticks.push(t);
    assert.equal(f.assess(permissive).offPassed, true, `baseline for ${kind}`);
    if (kind === 'corrupt') f.receipt.arrivals[2]!.image = { ...f.receipt.arrivals[2]!.image, kind: 'ambiguous', marker: undefined };
    if (kind === 'foreign') f.source.publication = 'foreign';
    if (kind === 'postBoundary') {
      const arrival = structuredClone(f.receipt.arrivals[2]!); arrival.atMs = 2700;
      arrival.image.marker!.sourceTimeUs = 2600000; f.source.generated.push(arrival.image.marker!);
      f.source.finalCounter = arrival.image.marker!.counter; f.receipt.arrivals.push(arrival);
    }
    if (kind === 'overflow') f.receipt.overflow = true;
    if (kind === 'health') f.receipt.ticks = [1000, 2000, 3000];
    if (kind === 'lifecycle') f.receipt.events = f.receipt.events.filter(e => e.kind !== 'unpublished');
    if (kind === 'producer') f.source.pacingTaskJoined = false;
    if (kind === 'replay') f.receipt.arrivals = f.receipt.arrivals.map(row => ({ ...row, image: f.receipt.arrivals[0]!.image }));
    if (kind === 'foreign') assert.throws(() => f.assess(permissive), /subscription mismatch/);
    else assert.equal(f.assess(permissive).offPassed, false, kind);
  }
  const f = sample();
  assert.throws(() => assessVideo(f.receipt, f.source, { ...f.options, platform: 'android', gates: android, afterCounter: -1 }), /counter fence/);
  assert.throws(() => assessVideo(f.receipt, f.source, { ...f.options, platform: 'android', gates: android, afterCounter: undefined as unknown as number }), /counter fence/);
  f.receipt.arrivals = f.receipt.arrivals.slice(0, 1);
  assert.equal(f.assess({ ...android, minimumFPS: 1 }).firstMs, null);
});
