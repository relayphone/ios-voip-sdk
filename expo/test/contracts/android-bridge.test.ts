import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { bindAndroid, type AndroidBridge, type AndroidBridgeEvents } from '../../src/conversations/android.ts';
import type { PushTokenSnapshot } from '../../src/conversations/transport.ts';
import type { JSONValue } from '../../src/conversations/types.ts';
import incomingCall from '../../../spec/fixtures/valid/incoming.json' with { type: 'json' };

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
