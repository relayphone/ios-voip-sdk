import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PeerReconnect } from './peer-reconnect.ts';

test('timeout retains incomplete evidence, excludes late events and permanently rejects retries', async () => {
  const request = Promise.withResolvers<void>(), budget = Promise.withResolvers<void>();
  let reconnecting = () => {}, reconnected = () => {}, subscribed = false, requests = 0;
  const control = new PeerReconnect({
    available: () => true, publications: () => ['track'],
    request: () => { requests++; return request.promise; },
    subscribe: (start, end) => { reconnecting = start; reconnected = end; subscribed = true;
      return () => { subscribed = false; }; },
  }, { domain: 'peerMonotonic', id: 'test-clock' }, operation => Promise.race([operation(), budget.promise]));
  const run = control.run();
  await assert.rejects(control.run(), /cannot reconnect/);
  reconnecting();
  const failed = assert.rejects(run, /expired/);
  budget.reject(Error('expired')); await failed;
  const evidence = control.evidence();
  assert.ok(evidence?.reconnectingAtMs !== undefined);
  assert.equal(evidence.reconnectedAtMs, undefined);
  assert.equal(subscribed, false);
  request.resolve(); reconnected(); reconnecting();
  await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(control.evidence(), evidence, 'uncancelled FFI completion cannot mutate the retired receipt');
  await assert.rejects(control.run(), /cannot reconnect/);
  assert.equal(requests, 1);
});

test('a rejected protocol request retires control and keeps the original error', async () => {
  let start = () => {}, end = () => {};
  const control = new PeerReconnect({
    available: () => true, publications: () => ['track'], request: async () => { throw Error('protocol failed'); },
    subscribe: (a, b) => { start = a; end = b; return () => {}; },
  }, { domain: 'peerMonotonic', id: 'clock' });
  await assert.rejects(control.run(), /protocol failed/);
  const evidence = control.evidence(); start(); end();
  assert.deepEqual(control.evidence(), evidence);
  await assert.rejects(control.run(), /cannot reconnect/);
});

test('successful attempts retain independent snapshots and require both real event callbacks', async () => {
  let start = () => {}, end = () => {}, tracks = ['before'];
  const control = new PeerReconnect({
    available: () => true, publications: () => tracks,
    request: async () => { start(); tracks = ['after']; end(); },
    subscribe: (a, b) => { start = a; end = b; return () => {}; },
  }, { domain: 'peerMonotonic', id: 'clock' });
  await control.run();
  const first = control.evidence()!;
  assert.deepEqual(first.publicationSidsBefore, ['before']);
  assert.deepEqual(first.publicationSidsAfter, ['after']);
  assert.ok(first.reconnectingAtMs! >= first.requestedAtMs && first.reconnectedAtMs! >= first.reconnectingAtMs!);
  tracks.push('new'); await control.run();
  assert.notEqual(control.evidence()?.id, first.id);
  assert.deepEqual(first.publicationSidsAfter, ['after']);
});
