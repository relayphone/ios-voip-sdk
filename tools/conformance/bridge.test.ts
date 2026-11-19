import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { isList, isRecord } from '../json-fields.ts';
import { callID, type Action, type CallError } from '../../expo/src/calls/model.ts';
import { createCallsStore, type CallsTransport, type Observation } from '../../expo/src/calls/store.ts';
import { incomingOutcome, performed } from '../../expo/src/calls/receipts.ts';
import { canonical, validateBridge } from './schema.ts';
import { decodeModelV1 } from './v1.ts';

const fixtures = new URL('../../spec/bridge/fixtures/', import.meta.url);
type Validity = 'valid' | 'invalid';

function messages(name: string, validity: Validity = 'valid') {
  const decoded: unknown = JSON.parse(readFileSync(new URL(`${validity}/${name}`, fixtures), 'utf8'));
  assert.ok(isList(decoded) && decoded.length > 0, 'A fixture must contain at least one message');
  return decoded;
}

for (const validity of ['valid', 'invalid'] as const) {
  const names = readdirSync(new URL(`${validity}/`, fixtures)).filter(name => name.endsWith('.json')).sort();
  for (const name of names) test(`bridge fixture ${validity}/${name}`, () => {
    for (const message of messages(name, validity)) {
      if (validity === 'invalid') assert.throws(() => validateBridge(message));
      else {
        validateBridge(message);
        assert.deepEqual(JSON.parse(canonical(message)), message);
      }
    }
  });
}

function fakeObservationTransport(initial: unknown, beforeHydration: readonly unknown[] = []) {
  validateBridge(initial, 'snapshot');
  let latest = initial;
  let receive: Parameters<CallsTransport['attach']>[0] | undefined;
  let reads = 0;
  return {
    attach(listener) {
      assert.equal(receive, undefined, 'one native subscription per store');
      receive = listener;
      const snapshot = latest;
      for (const frame of beforeHydration) this.send(frame);
      return {
        snapshot,
        unsubscribe: () => { receive = undefined; },
      };
    },
    snapshot() { reads++; return latest; },
    replace(snapshot: unknown) {
      validateBridge(snapshot, 'snapshot');
      latest = snapshot;
    },
    send(frame: unknown) {
      validateBridge(frame, 'frame');
      assert.ok(receive, 'listener is attached');
      receive(frame);
    },
    get reads() { return reads; },
    get attached() { return receive !== undefined; },
  } satisfies CallsTransport & {
    replace(snapshot: unknown): void;
    send(frame: unknown): void;
    readonly reads: number;
    readonly attached: boolean;
  };
}

test('attachment replay and cleanup frames preserve ordered terminal ownership', async () => {
  const [initial, replayed, cleanup, completed, pruned, removed] = messages('observations.json');
  const native = fakeObservationTransport(initial, [replayed, cleanup]);
  const store = createCallsStore(native, { terminalLimit: 1 });
  const idList = () => store.snapshot().calls.map(call => call.id);
  const received: Observation[] = [];
  store.subscribe(event => received.push(event));
  const at = store.snapshot().cursor;
  assert.equal(at.sequence, 2, 'a live callback before hydration advances the store');
  assert.deepEqual(idList(), ['oldest', 'younger'], 'cleanup outcome does not itself evict a call');
  assert.equal(native.reads, 0);

  native.send(cleanup);
  native.send(completed);
  assert.deepEqual(idList(), ['younger']);
  native.send(completed);
  native.send(pruned);
  assert.deepEqual(idList(), ['younger'], 'native removal of an already pruned call is harmless');
  native.send(removed);
  assert.deepEqual(idList(), []);

  assert.deepEqual(received.slice(1), [completed, pruned, removed]);
  const resumed = store.observe({ after: { ...at, sequence: at.sequence - 1 } })[Symbol.asyncIterator]();
  for (const expected of [cleanup, completed, pruned, removed]) {
    assert.deepEqual((await resumed.next()).value, expected);
  }
  store.close();
  store.close();
  assert.equal(native.attached, false);
  assert.equal((await resumed.next()).done, true);
});

test('the store resyncs to native snapshots for both a sequence gap and an epoch change', async () => {
  const [initial, contiguous, gapSnapshot, gapFrame, newSnapshot, newFrame] = messages('recovery.json');
  const native = fakeObservationTransport(initial);
  const store = createCallsStore(native);
  const received: Observation[] = [];
  const detach = store.subscribe(event => received.push(event));
  const start = store.snapshot().cursor;
  native.send(contiguous);
  assert.equal(store.snapshot().calls[0]?.lifecycle.kind, 'ringing');
  native.replace(gapSnapshot);
  native.send(gapFrame);
  assert.equal(store.snapshot().calls[0]?.lifecycle.kind, 'connected');
  assert.equal(store.snapshot().cursor.sequence, 3);
  native.replace(newSnapshot);
  native.send(newFrame);
  native.send(gapFrame);
  assert.equal(store.snapshot().cursor.epoch, 'recovery-b');
  assert.deepEqual(store.snapshot().calls.map(call => call.id), ['call-b']);
  assert.deepEqual(received.map(event => event.kind), ['snapshot', 'record', 'resyncRequired', 'resyncRequired']);
  assert.deepEqual(received[1], contiguous);
  assert.equal(native.reads, 3, 'old replay is checked against the authoritative current epoch');

  const resumed = store.observe({ after: start })[Symbol.asyncIterator]();
  const resync = (await resumed.next()).value;
  assert.ok(resync?.kind === 'resyncRequired');
  assert.equal(resync.snapshot, store.snapshot());
  detach();
  store.close();
});

const success = <Value>(value: Value) => ({ ok: true, value } as const);
const failure = (error: CallError) => ({ ok: false, error } as const);
const unavailable = failure({ kind: 'bridgeUnavailable' });

function versionReply(offer: unknown) {
  validateBridge(offer);
  assert.ok(isRecord(offer) && 'kind' in offer && offer.kind === 'negotiate');
  assert.ok('versions' in offer && isList(offer.versions));
  const { versions } = offer;
  if (new Set(versions).size !== versions.length) throw new TypeError('Offered versions must be distinct');
  const highest = Math.max(...versions.filter(version => version === 1));
  return { kind: 'negotiated', result: highest === 1 ? success({ version: highest }) : unavailable };
}

test('negotiation chooses a common version without depending on offer order', () => {
  const transcript = messages('negotiation.json');
  for (let index = 0; index < transcript.length; index += 2) {
    const reply = versionReply(transcript[index]);
    validateBridge(reply);
    assert.deepEqual(reply, transcript[index + 1]);
  }
  assert.throws(() => versionReply({ kind: 'negotiate', versions: [1, 1] }), TypeError);
});

type CallCommand =
  | { operation: 'start'; input: { id: string; parties: readonly unknown[] } }
  | { operation: 'perform'; input: { id: string; action: Action } }
  | { operation: 'bindRemote'; input: { id: string; remoteID: string } }
  | { operation: 'receive'; input: { kind: string; eventID: string; target: { kind: 'call' | 'remote'; id: string }; reason?: unknown } }
  | { operation: 'reportIncoming'; input: { callID: string; eventID: string } }
  | { operation: 'permissions.read' | 'permissions.request'; input: { kind: 'microphone' | 'camera' } }
  | { operation: 'push.registration' | 'push.health' };

function fakeCommandTransport() {
  const calls = new Map<string, { alias?: string; ended?: unknown }>();
  const events = new Set<string>();
  const invitations = new Map<string, { kind: 'admitted'; callID: string }>();
  let sequence = 0;
  let negotiated = false;
  const advance = () => ({ epoch: 'commands-a', sequence: ++sequence });
  const unknown = (id: string) => failure({ kind: 'unknownCall', callID: callID(id) });
  const pushRecord = (name: 'pushHealth' | 'pushRegistration') => {
    const fixture = new URL(`../../spec/v1/fixtures/valid/${name}.json`, import.meta.url);
    const decoded = decodeModelV1(JSON.parse(readFileSync(fixture, 'utf8')));
    assert.equal(decoded.kind, name);
    return decoded.value;
  };
  function execute(command: CallCommand) {
    switch (command.operation) {
      case 'start':
        calls.set(command.input.id, {});
        return success({ kind: 'performed', cursor: advance(), receipt: {
          actionID: 'start-a', origin: 'app', action: {
            kind: 'start', callID: command.input.id, line: { id: 'personal', accountID: 'account-a', label: 'Personal' },
            party: command.input.parties[0],
          },
        } });
      case 'bindRemote': {
        const call = calls.get(command.input.id);
        if (!call) return unknown(command.input.id);
        if (call.alias !== command.input.remoteID) advance();
        call.alias = command.input.remoteID;
        return success(null);
      }
      case 'receive': {
        const { eventID, target } = command.input;
        if (events.has(eventID)) return success({ kind: 'duplicate' });
        events.add(eventID);
        const call = target.kind === 'call'
          ? calls.get(target.id) : [...calls.values()].find(call => call.alias === target.id);
        if (call) {
          const cursor = advance();
          if (command.input.kind === 'ended') call.ended ??= {
            kind: 'end', cursor, outcome: { kind: 'alreadyEnded', reason: command.input.reason },
          };
        }
        return success({ kind: call ? 'applied' : 'buffered' });
      }
      case 'perform': {
        const { id, action } = command.input;
        const call = calls.get(id);
        if (!call) return unknown(id);
        if (action.kind === 'tones') return failure({ kind: 'unsupported', feature: 'tones' });
        assert.equal(action.kind, 'end');
        call.ended ??= {
          kind: 'end', cursor: advance(),
          outcome: { kind: 'ended', receipt: { callID: id, actionID: 'end-a', reason: { kind: 'localEnded' } } },
        };
        return success(call.ended);
      }
      case 'reportIncoming': {
        const { callID, eventID } = command.input;
        const original = invitations.get(eventID);
        if (original) return success({ kind: 'duplicate', original });
        const decision = { kind: 'admitted', callID } as const;
        invitations.set(eventID, decision);
        calls.set(callID, {});
        advance();
        return success(decision);
      }
      case 'permissions.read':
      case 'permissions.request':
        return success({ kind: command.input.kind === 'microphone' ? 'granted' : 'denied' });
      case 'push.registration': return success(pushRecord('pushRegistration'));
      case 'push.health': return success(pushRecord('pushHealth'));
    }
  }
  return {
    negotiate(offer: unknown) {
      const reply = versionReply(offer);
      negotiated = reply.result.ok;
      return reply;
    },
    command(value: unknown) {
      validateBridge(value, 'command');
      assert.ok(isRecord(value) && 'operation' in value);
      assert.ok(value.operation !== 'placement.attach' && value.operation !== 'placement.settle');
      // SAFETY: The bridge command schema validated the input for each non-placement operation.
      const command = value as CallCommand;
      return { kind: 'reply', operation: command.operation, result: negotiated ? execute(command) : unavailable };
    },
  };
}

test('commands and typed replies conform after negotiation', () => {
  const native = fakeCommandTransport();
  const transcript = messages('commands.json');
  assert.deepEqual(native.command(transcript[0]).result, unavailable);
  assert.ok(native.negotiate(messages('negotiation.json')[0]).result.ok);
  for (let index = 0; index < transcript.length; index += 2) {
    const reply = native.command(transcript[index]);
    validateBridge(reply, 'reply');
    assert.deepEqual(reply, transcript[index + 1]);
    if (reply.result.ok && reply.operation === 'start') assert.deepEqual(performed(reply.result.value), reply.result.value);
    if (reply.result.ok && reply.operation === 'reportIncoming') {
      assert.deepEqual(incomingOutcome(reply.result.value), reply.result.value);
    }
  }
  const absent = { kind: 'command', operation: 'perform', input: { id: 'different-call', action: { kind: 'end' } } };
  assert.deepEqual(native.command(absent).result, failure({ kind: 'unknownCall', callID: callID('different-call') }));
});

test('the store delivers and replays the original performed receipts in sequence', async () => {
  const native = fakeObservationTransport({ cursor: { epoch: 'actions-a', sequence: 0 }, calls: [] });
  const store = createCallsStore(native);
  const at = store.snapshot().cursor;
  const actionFrames = messages('actions.json');
  const received: Observation[] = [];
  store.subscribe(frame => received.push(frame));
  for (const frame of actionFrames) {
    native.send(frame);
    native.send(frame);
  }
  assert.equal(received[0]?.kind, 'snapshot');
  assert.deepEqual(received.slice(1), actionFrames);
  const reader = store.observe({ after: at })[Symbol.asyncIterator]();
  for (const frame of actionFrames) assert.deepEqual((await reader.next()).value, frame);
  store.close();
});

test('the incoming decoder preserves terminal and refusal decisions through duplicates', () => {
  for (const reply of messages('admissions.json')) {
    validateBridge(reply, 'reply');
    assert.ok(isRecord(reply) && 'result' in reply && isRecord(reply.result));
    const { result } = reply;
    assert.ok('ok' in result && result.ok === true && 'value' in result);
    assert.deepEqual(incomingOutcome(result.value), result.value);
  }
});

type PlacementCommand =
  | { operation: 'placement.attach'; input: { attached: boolean; generation: number } }
  | { operation: 'placement.settle'; input: { actionID: string; generation: number } };
type PlacementRequested = {
  kind: 'placementRequested'; generation: number; actionID: string;
  request: unknown; deadline: string; remainingMs: number;
};
type PlacementCancelled = {
  kind: 'placementCancelled'; generation: number; actionID: string;
  reason: 'replaced' | 'detached' | 'ended' | 'deadlineExceeded' | 'reset';
};
type PlacementEvent = PlacementRequested | PlacementCancelled;

function fakePlacementTransport(deliver: (event: PlacementEvent) => void) {
  const pending = new Map<string, { event: PlacementRequested; expiresAt: number }>();
  const utcBase = Date.parse('2026-11-18T12:00:00.000Z');
  let now = 0;
  let generation = 0;
  let attached = false;
  function cancel(event: PlacementRequested, reason: PlacementCancelled['reason']) {
    pending.delete(event.actionID);
    deliver({ kind: 'placementCancelled', generation: event.generation, actionID: event.actionID, reason });
  }
  return {
    command(value: unknown) {
      validateBridge(value, 'command');
      assert.ok(isRecord(value) && 'operation' in value);
      assert.ok(value.operation === 'placement.attach' || value.operation === 'placement.settle');
      // SAFETY: The bridge command schema validated the attach or settle input for this operation.
      const { operation, input } = value as PlacementCommand;
      if (operation === 'placement.attach') {
        if (input.generation > generation) {
          generation = input.generation;
          attached = input.attached;
          for (const { event } of pending.values()) cancel(event, attached ? 'replaced' : 'detached');
        }
        return { kind: 'reply', operation, result: success(null) };
      }
      const current = pending.get(input.actionID);
      const accepted = attached && current && generation === input.generation &&
        current.event.generation === input.generation && now < current.expiresAt;
      if (accepted) pending.delete(input.actionID);
      return { kind: 'reply', operation, result: success({ kind: accepted ? 'accepted' : 'stale' }) };
    },
    request({ actionID, request, remainingMs }: Pick<PlacementRequested, 'actionID' | 'request' | 'remainingMs'>) {
      assert.ok(attached);
      const expiresAt = now + remainingMs;
      const deadline = new Date(utcBase + expiresAt).toISOString();
      const event: PlacementRequested = { kind: 'placementRequested', generation, actionID, request, deadline, remainingMs };
      pending.set(actionID, { event, expiresAt });
      deliver(event);
    },
    advance(milliseconds: number) {
      now += milliseconds;
      for (const { event, expiresAt } of pending.values()) if (now >= expiresAt) cancel(event, 'deadlineExceeded');
    },
  };
}

test('placement replacement and monotonic expiry cancel once and fence late settlements', () => {
  const transcript = messages('placement.json');
  const received: PlacementEvent[] = [];
  const signals = new Map<string, AbortController>();
  const native = fakePlacementTransport(event => {
    validateBridge(event);
    received.push(event);
    if (event.kind === 'placementRequested') signals.set(event.actionID, new AbortController());
    else signals.get(event.actionID)?.abort(event.reason);
  });
  let lastBudget = 0;
  for (let index = 0; index < transcript.length; index++) {
    const message = transcript[index];
    validateBridge(message);
    assert.ok(isRecord(message) && 'kind' in message);
    assert.ok(message.kind === 'command' || message.kind === 'placementRequested' || message.kind === 'placementCancelled');
    // SAFETY: The bridge schema validated the complete message for these three kinds.
    const wire = message as { kind: 'command' } | PlacementEvent;
    switch (wire.kind) {
      case 'command': {
        const reply = native.command(message);
        validateBridge(reply, 'reply');
        assert.deepEqual(reply, transcript[++index]);
        break;
      }
      case 'placementRequested':
        lastBudget = wire.remainingMs;
        native.request(wire);
        assert.deepEqual(received.shift(), wire);
        break;
      case 'placementCancelled':
        if (wire.reason === 'deadlineExceeded') native.advance(lastBudget);
        assert.deepEqual(received.shift(), wire);
        break;
    }
  }
  assert.deepEqual(received, []);
  assert.equal(signals.get('place-a')?.signal.reason, 'replaced');
  assert.equal(signals.get('place-b')?.signal.aborted, false);
  assert.equal(signals.get('place-c')?.signal.reason, 'deadlineExceeded');
});
