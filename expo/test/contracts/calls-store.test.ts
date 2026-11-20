import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { canonical } from '../../../tools/conformance/schema.ts';
import { callID, decodeWireRecord, dtmfDigit, e164, httpsURL, milliseconds } from '../../src/calls/model.ts';
import { createCallsStore, type CallsTransport, type Observation } from '../../src/calls/store.ts';

for (const root of ['spec/fixtures', 'spec/v1/fixtures']) {
  for (const validity of ['valid', 'invalid']) {
    const directory = new URL(`../../../${root}/${validity}/`, import.meta.url);
    for (const file of readdirSync(directory).filter(file => file.endsWith('.json')).sort()) {
      test(`${root}/${validity}/${file}`, () => {
        const value: unknown = JSON.parse(readFileSync(new URL(file, directory), 'utf8'));
        if (validity === 'valid') assert.equal(canonical(decodeWireRecord(value)), canonical(value));
        else assert.throws(() => decodeWireRecord(value), TypeError);
      });
    }
  }
}

test('constructors preserve opaque identities and validate domain scalars', () => {
  assert.equal(callID('café 相談 ☎️'), 'café 相談 ☎️');
  assert.equal(callID('😀'.repeat(256)), '😀'.repeat(256));
  for (const invalid of [' padded', 'padded\u00a0', 'c\u0085d', '😀'.repeat(257)]) {
    assert.throws(() => callID(invalid), TypeError);
  }
  assert.equal(e164('+12025550101'), '+12025550101');
  assert.throws(() => e164('+12025550101\n'), TypeError);
  assert.equal(milliseconds(50), 50);
  assert.throws(() => milliseconds(1.5), TypeError);
  assert.equal(dtmfDigit('#'), '#');
  assert.throws(() => dtmfDigit('a'), TypeError);
  assert.equal(httpsURL('https://example.test/claim'), 'https://example.test/claim');
  for (const invalid of ['http://example.test', 'https://u:p@example.test', 'https://exa\tmple.test']) {
    assert.throws(() => httpsURL(invalid), TypeError);
  }
});

const cursor = (sequence: number, epoch = 'native-a') => ({ epoch, sequence });
type FixtureLifecycle = { kind: 'ringing' }
  | { kind: 'ended'; reason: { kind: 'remoteEnded' }; endedAt: string };
const call = (id: string, lifecycle: FixtureLifecycle = { kind: 'ringing' }) => ({
  id, direction: 'incoming', lifecycle,
  line: { accountID: 'account-a', id: 'line-a', label: 'Personal' },
  parties: [{ id: 'alice', handle: { kind: 'opaque', value: 'sip:alice@example.test' }, displayName: 'Alice' }],
  held: false, muted: false, video: false,
  media: { owner: 'native', preparation: 'unprovided', audio: 'inactive', transport: 'disconnected' },
});
const terminal = (id: string) => call(id, {
  kind: 'ended', reason: { kind: 'remoteEnded' }, endedAt: '2026-01-01T00:00:00.000Z',
});
type FixtureCall = ReturnType<typeof call>;
const snapshot = (sequence: number, epoch?: string, calls: readonly FixtureCall[] = [], completed?: string[]) => {
  const current = { cursor: cursor(sequence, epoch), calls };
  return completed ? { ...current, completed } : current;
};
const callRecord = (value: FixtureCall) => ({ version: 0, kind: 'call', value } as const);
const error = { version: 0, kind: 'error', value: { kind: 'bridgeUnavailable' } } as const;
type FixtureRecord = ReturnType<typeof callRecord> | (Omit<typeof error, 'version'> & { version: number });
const frame = (sequence: number, record: FixtureRecord, epoch?: string) =>
  ({ kind: 'record', cursor: cursor(sequence, epoch), record } as const);
type FixtureFrame = ReturnType<typeof frame>
  | ({ cursor: ReturnType<typeof cursor>; callID: string } & (
      { kind: 'cleanup'; outcome: 'removed' } | { kind: 'terminalCompleted' | 'callRemoved' }
    ));
type Receive = Parameters<CallsTransport['attach']>[0];

class FakeNative implements CallsTransport {
  private receive: Receive | undefined;
  state = snapshot(0);
  beforeHydration: readonly FixtureFrame[] = [];
  reads = 0;
  attaches = 0;
  detaches = 0;
  attach(receive: Receive) {
    this.attaches++;
    this.receive = receive;
    this.beforeHydration.forEach(receive);
    return { snapshot: this.state, unsubscribe: () => { this.detaches++; this.receive = undefined; } };
  }
  snapshot() { this.reads++; return this.state; }
  send(frame: FixtureFrame) { this.receive?.(frame); }
}

test('attachment handles synchronous delivery, copies immutable state and journals only new sequences', async () => {
  const native = new FakeNative();
  const original = call('call-a');
  native.state = snapshot(1, undefined, [original]);
  native.beforeHydration = [frame(1, callRecord(original)), frame(2, error)];
  const store = createCallsStore(native);
  const initial = store.snapshot();
  assert.equal(initial.cursor.sequence, 2);
  assert.equal(initial.calls[0]?.video.confirmed, 'audio');
  original.line.label = 'Modified';
  assert.equal(initial.calls[0]?.line.label, 'Personal');
  assert.ok(Object.isFrozen(initial.calls[0]?.parties[0]?.handle));
  const received: number[] = [];
  const unsubscribe = store.subscribe(event => received.push(event.cursor.sequence));
  native.send(frame(2, error));
  native.send(frame(3, error));
  native.send(frame(3, error));
  assert.deepEqual(received, [2, 3]);
  assert.equal(store.snapshot().calls, initial.calls);
  const replay = store.observe({ after: initial.cursor })[Symbol.asyncIterator]();
  assert.equal((await replay.next()).value?.cursor.sequence, 3);
  unsubscribe();
  unsubscribe();
  const pending = replay.next();
  await replay.return?.();
  assert.equal((await pending).done, true);
  store.close();
  store.close();
  assert.equal(native.attaches, 1);
  assert.equal(native.detaches, 1);
});

test('subscriber reentrancy preserves one stream and subscriptions are independent', () => {
  const native = new FakeNative();
  const store = createCallsStore(native);
  const seen: number[] = [];
  store.subscribe(observation => { if (observation.cursor.sequence === 1) native.send(frame(2, error)); });
  const listener = (observation: Observation) => seen.push(observation.cursor.sequence);
  const first = store.subscribe(listener);
  const second = store.subscribe(listener);
  first();
  first();
  native.send(frame(1, error));
  assert.deepEqual(seen, [0, 0, 1, 2]);
  second();
  store.close();
});

test('a malformed reentrant frame does not discard a later valid frame', () => {
  const native = new FakeNative();
  const store = createCallsStore(native);
  const received: string[] = [];
  store.subscribe(observation => {
    received.push(observation.kind);
    if (observation.cursor.sequence === 1) {
      native.send(frame(2, { ...error, version: 2 }));
      native.state = snapshot(3, undefined, [call('recovered')]);
      native.send(frame(3, error));
    }
  });
  assert.throws(() => native.send(frame(1, error)), TypeError);
  assert.deepEqual(received, ['snapshot', 'record', 'resyncRequired']);
  assert.equal(store.snapshot().calls[0]?.id, 'recovered');
  store.close();
});

test('gaps and epoch replacement publish one authoritative resync and discard covered replay', async () => {
  const native = new FakeNative();
  const store = createCallsStore(native);
  const original = store.snapshot().cursor;
  const kinds: string[] = [];
  store.subscribe(event => kinds.push(event.kind));
  native.state = snapshot(4, undefined, [call('hydrated')]);
  native.send(frame(3, error));
  native.send(frame(4, error));
  assert.equal(store.snapshot().calls[0]?.id, 'hydrated');
  const stale = store.observe({ after: original })[Symbol.asyncIterator]();
  assert.equal((await stale.next()).value?.kind, 'resyncRequired');
  native.state = snapshot(1, 'native-b');
  native.send(frame(1, error, 'native-b'));
  native.send(frame(5, error));
  native.send(frame(2, error, 'native-b'));
  assert.deepEqual(kinds, ['snapshot', 'resyncRequired', 'resyncRequired', 'record']);
  assert.equal(store.snapshot().cursor.epoch, 'native-b');
  assert.deepEqual(store.snapshot().calls, []);
  assert.equal(native.reads, 3);
  store.close();
});

test('expired cursors and slow readers recover without unbounded queues', async () => {
  const native = new FakeNative();
  const store = createCallsStore(native, { replayLimit: 2 });
  const initial = store.snapshot().cursor;
  const slow = store.observe()[Symbol.asyncIterator]();
  for (const sequence of [1, 2, 3, 4]) native.send(frame(sequence, error));
  assert.equal((await slow.next()).value?.kind, 'snapshot');
  const resync = (await slow.next()).value;
  assert.equal(resync?.kind, 'resyncRequired');
  assert.equal(resync?.cursor.sequence, 3);
  assert.equal((await slow.next()).value?.cursor.sequence, 4);
  const expired = store.observe({ after: initial })[Symbol.asyncIterator]();
  assert.equal((await expired.next()).value?.kind, 'resyncRequired');
  const pending = slow.next();
  store.close();
  assert.equal((await pending).done, true);
});

test('reattachment prunes by terminal order and hydrates runtime capabilities', () => {
  const capability = { feature: 'tones', availability: { kind: 'available' } };
  const store = createCallsStore({
    attach: () => ({
      snapshot: {
        ...snapshot(2, undefined, [terminal('placed-second'), terminal('placed-first')], ['placed-first', 'placed-second']),
        records: [{ version: 1, kind: 'capability', value: capability }],
      },
      unsubscribe: () => {},
    }),
    snapshot: () => { throw new Error('Unexpected recovery'); },
  }, { terminalLimit: 1 });
  assert.deepEqual(store.snapshot().calls.map(call => call.id), ['placed-first']);
  assert.deepEqual(store.snapshot().capabilities, [capability]);
  store.close();
});

test('retention bounds completed terminals without displacing pending native work', async () => {
  const native = new FakeNative();
  native.state = snapshot(10, undefined, [terminal('pending'), terminal('completed')], ['completed']);
  const store = createCallsStore(native, { terminalLimit: 1 });
  const firstSnapshot = store.observe()[Symbol.asyncIterator]();
  const observation = (await firstSnapshot.next()).value;
  assert.ok(observation?.kind === 'snapshot');
  assert.deepEqual(observation.snapshot.calls.map(call => call.id), ['pending', 'completed']);
  native.send(frame(11, callRecord(terminal('new'))));
  native.send({ cursor: cursor(12), kind: 'cleanup', callID: 'new', outcome: 'removed' });
  assert.deepEqual(store.snapshot().calls.map(call => call.id), ['pending', 'completed', 'new']);
  native.send({ cursor: cursor(13), kind: 'terminalCompleted', callID: 'new' });
  assert.deepEqual(store.snapshot().calls.map(call => call.id), ['pending', 'new']);
  native.send({ cursor: cursor(14), kind: 'terminalCompleted', callID: 'pending' });
  assert.deepEqual(store.snapshot().calls.map(call => call.id), ['new']);
  native.send({ cursor: cursor(15), kind: 'callRemoved', callID: 'new' });
  assert.deepEqual(store.snapshot().calls, []);
  store.close();
});
