import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PeerLifecycle } from './peer-lifecycle.ts';
import { createMarker, detectMarker, emissionSamples } from '../../expo/src/testing/marker.ts';

test('both real event kinds are required, in either order, after an audio publication', () => {
  for (const order of [['trackUnpublished', 'participantDisconnected'], ['participantDisconnected', 'trackUnpublished']] as const) {
    let now = 10;
    const observer = new PeerLifecycle(() => now++);
    observer.record('participantConnected', 'app');
    observer.record('trackPublished', 'app', 'audio');
    observer.receive(new Int16Array([1024]));
    observer.record(order[0], 'app', 'audio');
    assert.equal(observer.snapshot().afterDisconnect, null);
    observer.record(order[1], 'app', 'audio');
    const terminal = observer.snapshot().afterDisconnect!;
    assert.equal(terminal.identity, 'app');
    assert.equal(terminal.receivedSamplesAtStart, 1);
    assert.deepEqual(terminal.channels, [[]]);
    observer.receive(new Int16Array([2048]));
    assert.deepEqual(observer.snapshot().afterDisconnect!.channels, [[2048 / 32768]]);
    assert.deepEqual(terminal.channels, [[]]);
  }
});
test('disconnect alone, an unrelated participant, or one remaining audio track cannot qualify', () => {
  const observer = new PeerLifecycle();
  observer.record('trackPublished', 'app', 'a');
  observer.record('trackPublished', 'app', 'b');
  observer.record('participantDisconnected', 'other');
  observer.record('trackUnpublished', 'app', 'a');
  observer.record('participantDisconnected', 'app');
  assert.equal(observer.snapshot().afterDisconnect, null);
  observer.record('trackUnpublished', 'app', 'b');
  assert.ok(observer.snapshot().afterDisconnect);
});
test('late PCM and reconnects remain visible and bounded; snapshots are independent', () => {
  const observer = new PeerLifecycle();
  observer.record('trackPublished', 'app', 'a');
  observer.record('trackUnpublished', 'app', 'a');
  observer.record('participantDisconnected', 'app');
  const before = observer.snapshot();
  observer.record('participantConnected', 'app');
  observer.receive(new Int16Array(48_000 * 4).fill(100));
  const after = observer.snapshot();
  assert.equal(after.afterDisconnect!.channels[0]!.length, 48_000 * 3);
  assert.equal(after.afterDisconnect!.overflowSamples, 48_000);
  assert.equal(after.events.at(-1)!.kind, 'participantConnected');
  assert.equal(before.events.length, 3);
  assert.equal(before.afterDisconnect!.channels[0]!.length, 0);
  for (let i = 0; i < 300; i++) observer.record('participantConnected', 'app');
  assert.equal(observer.snapshot().events.length, 256);
  assert.equal(observer.snapshot().droppedEvents, 48);
  assert.notEqual(observer.snapshot().clock.id, new PeerLifecycle().snapshot().clock.id);
});
test('a marker arriving after departure remains detectable as a failing terminal control', () => {
  const observer = new PeerLifecycle();
  observer.record('trackPublished', 'app', 'audio');
  observer.record('trackUnpublished', 'app', 'audio');
  observer.record('participantDisconnected', 'app');
  const marker = createMarker('late-terminal-marker');
  observer.receive(Int16Array.from(emissionSamples(marker, 48_000, 48_960), sample => Math.round(sample * 32767)));
  assert.ok(detectMarker(Float32Array.from(observer.snapshot().afterDisconnect!.channels[0]!), 48_000, marker));
});
