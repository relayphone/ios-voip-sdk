import assert from 'node:assert/strict';
import test from 'node:test';
import { bindAndroid, type AndroidBridge } from '../../src/conversations/android.ts';
import type { JSONValue } from '../../src/conversations/types.ts';

test('Android command replies require the echoed operation and its expected value', async () => {
  const snapshot = JSON.stringify({ cursor: { epoch: 'android-a', sequence: 0 }, calls: [] });
  const callID = 'incoming-a';
  let answer: JSONValue = null;
  let operation = 'perform';
  const native: AndroidBridge = {
    negotiate: () => JSON.stringify({ kind: 'negotiated', result: { ok: true, value: { version: 1 } } }),
    line: () => JSON.stringify({ id: 'personal', accountID: 'account-a', label: 'Personal' }),
    attach: () => snapshot,
    detach() {},
    snapshot: () => snapshot,
    async command(request) {
      if (request.includes('"operation":"reportIncoming"')) {
        return JSON.stringify({ kind: 'reply', operation: 'reportIncoming', result: {
          ok: true, value: { kind: 'duplicate', original: { kind: 'admitted', callID } },
        } });
      }
      return JSON.stringify({ kind: 'reply', operation, result: { ok: true, value: answer } });
    },
    addListener: () => ({ remove() {} }),
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
});
