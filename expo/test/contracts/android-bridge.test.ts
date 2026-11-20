import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { bindAndroid, type AndroidBridge, type AndroidBridgeEvents } from '../../src/conversations/android.ts';
import type { AudioRoutesSnapshot, NativeEvents, PushTokenSnapshot } from '../../src/conversations/transport.ts';
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

test('Android audio routes use the iOS snapshot and selection shapes', async () => {
  const { native, emit } = bridgeHarness();
  const earpiece = { id: 'receiver', name: 'Earpiece', type: 'builtInReceiver' } as const;
  const speaker = { id: 'speaker', name: 'Speaker', type: 'builtInSpeaker' } as const;
  const bluetooth = { id: 'bluetooth', name: 'Headset', type: 'bluetooth' } as const;
  const initial = { revision: 1, routes: [earpiece, speaker], current: earpiece } satisfies AudioRoutesSnapshot;
  let current: AudioRoutesSnapshot = initial;
  let unsupported = false;
  native.command = async source => {
    const request = JSON.parse(source);
    const { operation } = request;
    let result;
    if (operation === 'audio.routes') result = { ok: true, value: current };
    else {
      assert.equal(operation, 'audio.select');
      if (unsupported) result = { ok: false, error: { kind: 'unsupported', feature: 'audioRoutes' } };
      else if (request.input.id === speaker.id) result = { ok: true, value: null };
      else result = { ok: false, error: { kind: 'systemFailed', cause: { platform: 'android', kind: 'audio' } } };
    }
    return JSON.stringify({ kind: 'reply', operation, result });
  };
  const calls = bindAndroid(native);
  const events: NativeEvents['audioRoutesChanged'][] = [];
  calls.addListener('audioRoutesChanged', value => events.push(value));
  assert.deepEqual(await calls.getAudioRoutes(), initial);
  assert.equal(await calls.selectAudioRoute(speaker.id), undefined);
  assert.deepEqual(await calls.getAudioRoutes(), initial);
  assert.deepEqual(events, []);
  const selected = { ...initial, revision: 2, current: speaker };
  current = { revision: 3, routes: [earpiece, speaker, bluetooth], current: bluetooth };
  for (const value of [initial, selected, selected, current, selected]) {
    emit('audioRoutesChanged', { json: JSON.stringify(value) });
  }
  assert.deepEqual(events, [initial, selected, current]);
  assert.deepEqual(await calls.getAudioRoutes(), current);
  await assert.rejects(calls.selectAudioRoute('removed'), {
    code: 'conversation', message: 'The audio route is unavailable or refused',
  });
  unsupported = true;
  await assert.rejects(calls.selectAudioRoute(speaker.id), { code: 'unsupported' });
});

test('Android mute and tones project the iOS action shapes after confirmed state', async () => {
  const { native, emit, setSnapshot } = bridgeHarness();
  const callID = incomingCall.value.id;
  const cursor = (sequence: number) => ({ epoch: 'android-a', sequence });
  let sequence = 0;
  setSnapshot({ cursor: cursor(sequence), calls: [incomingCall.value] });
  const frame = (value: { readonly [key: string]: JSONValue }) =>
    emit('bridgeFrame', { json: JSON.stringify({ ...value, cursor: cursor(++sequence) }) });
  const receipts: NativeEvents['conversationEvent'][] = [];
  native.command = async source => {
    const request = JSON.parse(source);
    assert.equal(request.operation, 'perform');
    assert.equal(request.input.id, callID);
    const action = request.input.action;
    if (action.kind === 'mute') {
      assert.equal(action.muted, true);
      frame({ kind: 'record', record: { ...incomingCall, value: { ...incomingCall.value, muted: true } } });
    } else {
      assert.deepEqual(action, { kind: 'tones', digits: ['1', '2', '*', '#', 'A', 'b'] });
    }
    const receipt = { actionID: `audio-${sequence}`, origin: 'app', action: { ...action, callID } };
    frame({ kind: 'actionPerformed', receipt });
    return JSON.stringify({
      kind: 'reply', operation: 'perform',
      result: { ok: true, value: { kind: 'performed', cursor: cursor(sequence), receipt } },
    });
  };
  const calls = bindAndroid(native);
  const id = calls.snapshot.conversations[0]!.id;
  calls.addListener('conversationEvent', value => receipts.push(value));
  assert.equal(await calls.setMuted(id, true), undefined);
  assert.equal(calls.snapshot.conversations[0]?.isMuted, true);
  await calls.setMuted(id, true);
  frame({ kind: 'record', record: incomingCall });
  frame({ kind: 'actionPerformed', receipt: {
    actionID: 'system-mute', origin: 'system', action: { kind: 'mute', muted: false, callID },
  } });
  assert.equal(calls.snapshot.conversations[0]?.isMuted, false);
  assert.equal(await calls.playTones(id, '12*#Ab'), undefined);
  await assert.rejects(calls.playTones(id, ''), { code: 'invalid_arguments' });
  await assert.rejects(calls.playTones(id, '1E'), { code: 'invalid_arguments' });
  assert.deepEqual(receipts, [
    { type: 'actionPerformed', payload: { conversationId: id, origin: 'app', action: { kind: 'mute', muted: true } } },
    { type: 'actionPerformed', payload: { conversationId: id, origin: 'system', action: { kind: 'mute', muted: false } } },
    { type: 'actionPerformed', payload: { conversationId: id, origin: 'app', action: { kind: 'tones', digits: '12*#Ab' } } },
  ]);
});
