import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { literal, object, text } from '../../src/calls/decode.ts';
import { bindAndroid, type AndroidBridge, type AndroidBridgeEvents } from '../../src/conversations/android.ts';
import { HandlerDispatcher } from '../../src/conversations/runtime.ts';
import type { PushTokenSnapshot } from '../../src/conversations/transport.ts';
import type { JSONValue } from '../../src/conversations/types.ts';
import incomingCall from '../../../spec/fixtures/valid/incoming.json' with { type: 'json' };

const progressReport = object({
  kind: literal('connecting', 'connected'), eventID: text(),
  target: object({ kind: literal('call'), id: text() }),
});

function bridgeHarness() {
  let snapshot = JSON.stringify({ cursor: { epoch: 'android-a', sequence: 0 }, calls: [] });
  const receivers = new EventEmitter();
  const native: AndroidBridge = {
    negotiate: () => JSON.stringify({ kind: 'negotiated', result: { ok: true, value: { version: 1 } } }),
    line: () => JSON.stringify({ id: 'personal', accountID: 'account-a', label: 'Personal' }),
    attach: () => snapshot,
    detach() {},
    snapshot: () => snapshot,
    async command() { throw new Error('Unexpected portable bridge command'); },
    async getPushToken() { return { revision: 0, token: null }; },
    addListener(name, receive) {
      receivers.on(name, receive);
      return { remove() { receivers.off(name, receive); } };
    },
  };
  return {
    native,
    emit<Name extends keyof AndroidBridgeEvents>(name: Name, value: AndroidBridgeEvents[Name]) {
      receivers.emit(name, value);
    },
    listening(name: keyof AndroidBridgeEvents) { return receivers.listenerCount(name) > 0; },
    setSnapshot(value: JSONValue) { snapshot = JSON.stringify(value); },
  };
}

test('Android command replies require the echoed operation and its expected value', async () => {
  const { native, emit } = bridgeHarness();
  const callID = 'incoming-a';
  let answer: JSONValue = null;
  let operation = 'perform';
  native.command = async request => {
    if (request.includes('"operation":"reportIncoming"')) {
      return JSON.stringify({ kind: 'reply', operation: 'reportIncoming', result: {
        ok: true, value: { kind: 'duplicate', original: { kind: 'admitted', callID } },
      } });
    }
    return JSON.stringify({ kind: 'reply', operation, result: { ok: true, value: answer } });
  };
  const calls = bindAndroid(native);
  const incoming = await calls.reportIncomingConversation({
    serverCallId: 'retry-a', eventId: 'invite-a', hasVideo: false,
    caller: { handleType: 'generic', value: 'alice', displayName: 'Alice' },
  });
  assert.equal(incoming.status, 'reported');
  assert.equal(incoming.id, callID);
  await assert.rejects(calls.joinConversation(incoming.id), TypeError);

  answer = {
    kind: 'performed', cursor: { epoch: 'android-a', sequence: 1 },
    receipt: { actionID: 'answer-a', origin: 'system', action: { kind: 'answer', callID } },
  };
  operation = 'start';
  await assert.rejects(calls.joinConversation(incoming.id), TypeError);
  operation = 'perform';
  await calls.joinConversation(incoming.id);

  const outcomes: string[] = [];
  calls.addListener('conversationEvent', event => {
    if (event.type === 'incomingConversationOutcome') outcomes.push(event.payload.eventId);
  });
  emit('incomingPush', { json: JSON.stringify({
    eventId: 'push-a', serverCallId: callID, outcome: { kind: 'admitted', callID },
  }) });
  assert.deepEqual(outcomes, ['push-a']);
});

test('Android token reads and updates use the same dedicated shape as iOS', async () => {
  const { native, emit } = bridgeHarness();
  const ios = { revision: 1, token: { type: 'apns-voip', value: 'example-initial' } } satisfies PushTokenSnapshot;
  const initial = { ...ios, token: { ...ios.token, type: 'fcm' } } satisfies PushTokenSnapshot;
  const rotated = { revision: 2, token: { type: 'fcm', value: 'example-rotated' } } satisfies PushTokenSnapshot;
  const invalidated = { revision: 3, token: null };
  let current: PushTokenSnapshot = { revision: 0, token: null };
  native.getPushToken = async () => current;
  const calls = bindAndroid(native);
  assert.deepEqual(await calls.getPushToken(), current);
  const events: PushTokenSnapshot[] = [];
  calls.addListener('pushTokenUpdated', event => events.push(event));
  for (const value of [initial, rotated, invalidated]) {
    current = value;
    emit('pushTokenUpdated', value);
    assert.deepEqual(await calls.getPushToken(), value);
  }
  assert.deepEqual(events, [initial, rotated, invalidated]);
  assert.deepEqual(calls.snapshot, { revision: 0, conversations: [] });
});

test('Android exposes an incoming conversation only after system admission, as on iOS', async () => {
  const { native, emit, setSnapshot } = bridgeHarness();
  const reporting = { ...incomingCall.value, lifecycle: { kind: 'reporting' } };
  const cursor = (sequence: number) => ({ epoch: 'android-a', sequence });
  setSnapshot({ cursor: cursor(0), calls: [reporting] });
  const calls = bindAndroid(native);
  assert.deepEqual(calls.snapshot.conversations, []);
  const snapshots: string[][] = [];
  calls.addListener('conversationsChanged', value => snapshots.push(value.conversations.map(call => call.status)));
  emit('bridgeFrame', { json: JSON.stringify({
    cursor: cursor(1), kind: 'record', record: { ...incomingCall, value: { ...reporting, muted: true } },
  }) });
  assert.deepEqual(await calls.getConversations(), { revision: 0, conversations: [] });
  assert.deepEqual(snapshots, []);
  emit('bridgeFrame', { json: JSON.stringify({ cursor: cursor(2), kind: 'record', record: incomingCall }) });
  assert.deepEqual(snapshots, [['ringing']]);
});

test('Android starts through the placement handler, sends progress, and confirms hold with its origin', async () => {
  const callID = 'outgoing-a';
  const line = { id: 'personal', accountID: 'account-a', label: 'Personal' };
  const parties = [{ id: 'alice', handle: { kind: 'phone', e164: '+12025550100' }, displayName: 'Alice' }];
  const cursor = { epoch: 'android-a', sequence: 0 };
  const { native, emit, listening } = bridgeHarness();
  const attach = Promise.withResolvers<void>();
  const handlerSettled = Promise.withResolvers<void>();
  const operations: string[] = [];
  const progress: string[] = [];
  const receipts: string[] = [];
  let holdReceipt = true;
  const placement = {
    kind: 'placementRequested', generation: 1, actionID: 'place-a',
    deadline: new Date(Date.now() + 10_000).toISOString(), remainingMs: 10_000,
    request: { kind: 'start', origin: 'app', callID, line, parties },
  };
  const deliver = (name: 'bridgeFrame' | 'placementFrame', frame: JSONValue) => emit(name, { json: JSON.stringify(frame) });
  native.command = async source => {
    const { operation, input }: { operation: string; input: JSONValue } = JSON.parse(source);
    operations.push(operation);
    const reply = (value: JSONValue) => JSON.stringify({ kind: 'reply', operation, result: { ok: true, value } });
    switch (operation) {
      case 'placement.attach':
        assert.ok(listening('placementFrame'));
        assert.deepEqual(input, { attached: true, generation: 1 });
        await attach.promise;
        return reply(null);
      case 'start': {
        assert.deepEqual(input, { id: callID, lineID: line.id, video: false, parties });
        deliver('placementFrame', placement);
        deliver('placementFrame', placement);
        await handlerSettled.promise;
        deliver('placementFrame', placement);
        const receipt = { actionID: 'place-a', origin: 'app', action: { kind: 'start', callID, line, party: parties[0] ?? null } };
        const at = { ...cursor, sequence: 1 };
        deliver('bridgeFrame', { kind: 'actionPerformed', cursor: at, receipt });
        return reply({ kind: 'performed', cursor: at, receipt });
      }
      case 'receive': {
        const report = progressReport(input);
        assert.deepEqual(report.target, { kind: 'call', id: callID });
        progress.push(report.kind);
        return reply({ kind: 'applied' });
      }
      case 'placement.settle':
        assert.deepEqual(input, { actionID: 'place-a', generation: 1, result: { ok: true, value: { kind: 'placed' } } });
        handlerSettled.resolve();
        return reply({ kind: 'accepted' });
      case 'perform': {
        assert.deepEqual(input, { id: callID, action: { kind: 'hold', held: true } });
        const receipt = { actionID: 'hold-a', origin: 'app', action: { kind: 'hold', callID, held: holdReceipt } };
        return reply({ kind: 'performed', cursor, receipt });
      }
      default: throw new Error(`Unexpected command ${operation}`);
    }
  };
  const calls = bindAndroid(native);
  const dispatcher = new HandlerDispatcher(calls);
  calls.addListener('handlerAction', action => dispatcher.dispatch(action));
  calls.addListener('conversationEvent', event => {
    if (event.type === 'actionPerformed') receipts.push(`${event.payload.action.kind}:${event.payload.origin}`);
  });
  let handled = 0;
  dispatcher.set({
    async start(call, context) {
      handled += 1;
      assert.equal(call.id, callID);
      assert.equal(call.capabilities.hold, true);
      assert.equal(call.members[0]?.phoneNumber, '+12025550100');
      assert.equal(context.origin, 'app');
      await calls.reportConversation(call.id, { type: 'connecting' });
    },
  });
  const starting = calls.startConversation({ id: callID, video: false, to: {
    id: 'alice', displayName: 'Alice', phoneNumber: '+1 (202) 555-0100',
  } });
  assert.deepEqual(operations, ['placement.attach']);
  attach.resolve();
  const id = await starting;
  assert.equal(id, callID);
  assert.equal(handled, 1);
  await calls.reportConversation(id, { type: 'connected' });
  assert.deepEqual(progress, ['connecting', 'connected']);

  await calls.setHeld(id, true);
  holdReceipt = false;
  await assert.rejects(calls.setHeld(id, true), { code: 'conversation', message: 'Invalid Hold receipt' });
  deliver('bridgeFrame', {
    kind: 'actionPerformed', cursor: { ...cursor, sequence: 2 },
    receipt: { actionID: 'system-hold', origin: 'system', action: { kind: 'hold', callID, held: true } },
  });
  assert.deepEqual(receipts, ['start:app', 'hold:system']);
  await assert.rejects(calls.setMuted(id, true), { code: 'unsupported' });
});

test('Android maps typed start failures without changing the public call ID', async () => {
  const { native } = bridgeHarness();
  let error: JSONValue = { kind: 'placementFailed', cause: 'handlerFailed' };
  native.command = async () => JSON.stringify({ kind: 'reply', operation: 'start', result: { ok: false, error } });
  const calls = bindAndroid(native);
  const start = () => calls.startConversation({ id: 'outgoing-a', to: { id: 'alice' }, video: false });
  await assert.rejects(start, { code: 'handler_failed' });
  error = { kind: 'deadlineExceeded', stage: 'placement' };
  await assert.rejects(start, { code: 'deadline_exceeded' });
  error = { kind: 'refused', reason: { kind: 'notAllowed' } };
  await assert.rejects(start, { code: 'invalid_arguments' });
  error = { kind: 'systemFailed', cause: { kind: 'start', platform: 'android', code: 42 } };
  await assert.rejects(start, { code: 'conversation', nativeCode: 42 });
  await assert.rejects(calls.startConversation({ id: 'video-a', to: { id: 'alice' }, video: true }), { code: 'unsupported' });
});
