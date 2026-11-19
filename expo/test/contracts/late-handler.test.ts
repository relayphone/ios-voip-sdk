import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HandlerDispatcher } from '../../src/conversations/runtime.ts';
import type { Conversation, ConversationId } from '../../src/conversations/types.ts';
import { CountingTransport, driveLateHandler, isLateHandlerConfiguration, type JourneyClock,
  type LateHandlerApi, type LateHandlerConfiguration, type LateHandlerResults, type LateHandlerScenario,
} from '../../example/client/journeys/late-handler.ts';

function fixture(scenario: LateHandlerScenario) {
  const config: LateHandlerConfiguration = { schemaVersion: 1, runID: 'fixture', scenario,
    handlerAttachDelayMS: scenario === 'before-deadline' ? 1000 : scenario === 'after-deadline' ? 28000 : 11000,
    connectDeadlineMS: 27000 };
  let now = 0;
  let status: Conversation['status'] | undefined = scenario === 'preview-placement' ? 'previewing' : 'connecting';
  let rejectJoin: ((error: unknown) => void) | undefined;
  const attachments: [boolean, number, number][] = [];
  const settlements: unknown[] = [];
  const dispatcher = new HandlerDispatcher({
    setHandlerAttached: (attached, generation) => attachments.push([attached, generation, now]),
    settleAction: (...args) => settlements.push(args),
  });
  const id = 'fixture-call' as ConversationId;
  const call = (): Conversation => ({ id, status, direction: 'incoming', members: [], isMuted: false, isVideo: false,
    capabilities: { hold: true, merge: true, tones: true, video: false },
    ...(status === 'previewing' ? { previewReason: { type: 'policy' } } : {}),
    ...(status === 'connected' ? { connectedAt: new Date().toISOString() } : {}),
  }) as Conversation;
  const api: LateHandlerApi = {
    getConversations: async () => status ? [call()] : [],
    setConversationHandler: value => {
      dispatcher.set(value);
      // Exercise the real dispatcher too: an expired native action must not reach this handler.
      if (value) dispatcher.dispatch({ generation: 1, actionID: 'expired', kind: 'join', origin: 'system',
        deadline: '2000-01-01T00:00:00Z', conversation: call() });
    },
    reportConversation: async () => { status = 'connected'; },
    joinConversation: async () => {
      status = 'connecting';
      return new Promise<void>((_, reject) => { rejectJoin = reject; });
    },
  };
  const clock: JourneyClock = { nowMS: () => now, sleepMS: async delay => {
    now += delay;
    if (scenario === 'preview-placement' && now >= 9000) {
      status = 'previewing'; rejectJoin?.({ code: 'deadline_exceeded' });
    } else if (now >= 27000 && status === 'connecting') { status = undefined; }
  } };
  const media = new CountingTransport();
  const results: LateHandlerResults[] = [];
  return { config, api, clock, media, attachments, settlements, results,
    save: (result: LateHandlerResults) => results.push(structuredClone(result)),
    setStatus: (next: typeof status) => { status = next; } };
}
for (const scenario of ['before-deadline', 'after-deadline', 'preview-placement'] as const) {
  test(`ordinary handler attachment and fake transport: ${scenario}`, async () => {
    const f = fixture(scenario);
    await driveLateHandler(f.config, f.api, f.save, f.clock, f.media);
    assert.deepEqual(f.attachments, [[true, 1, f.config.handlerAttachDelayMS], [false, 2, f.config.handlerAttachDelayMS]]);
    assert.deepEqual(f.settlements, [], 'Expired native actions never settle');
    const result = f.results.at(-1)!;
    assert.equal(result.stage, 'complete');
    assert.equal(result.handlerInvocations, 0);
    assert.equal(result.starts, scenario === 'before-deadline' ? 1 : 0);
    assert.equal(result.packetsSent, 0); assert.equal(result.packetsReceived, 0);
    assert.equal(result.joinError, scenario === 'preview-placement' ? 'deadline_exceeded' : undefined);
  });
}
test('a call that never expires fails within the observation bound without attaching', async () => {
  const f = fixture('after-deadline');
  const sleep = f.clock.sleepMS;
  f.clock.sleepMS = async delay => { await sleep(delay); f.setStatus('connecting'); };
  await assert.rejects(driveLateHandler(f.config, f.api, f.save, f.clock, f.media), /observation timed out/);
  assert.equal(f.results.at(-1)!.stage, 'failed');
  assert.equal(f.media.starts, 0);
  assert.equal(f.attachments.at(-1)![0], false);
  assert.equal(f.attachments.filter(([attached]) => attached).length, 0);
  assert.equal(f.clock.nowMS(), 120000);
});
for (const callbackAtMS of [28000, 28125, 29500]) {
  test(`late attachment waits for the actual native failure callback at ${callbackAtMS}ms`, async () => {
    const f = fixture('after-deadline');
    const sleep = f.clock.sleepMS;
    f.clock.sleepMS = async delay => {
      await sleep(delay);
      f.setStatus(f.clock.nowMS() >= callbackAtMS ? undefined : 'connecting');
    };
    await driveLateHandler(f.config, f.api, f.save, f.clock, f.media);
    assert.equal(f.results.at(-1)!.stage, 'complete');
    assert.ok(f.attachments[0]![2] >= callbackAtMS);
    assert.equal(f.media.starts, 0);
    assert.equal(f.results.at(-1)!.handlerInvocations, 0);
  });
}
test('failed fake transport connection is terminal and detaches the handler', async () => {
  const f = fixture('before-deadline');
  f.media.start = async () => { throw new Error('Fixture transport failed'); };
  await assert.rejects(driveLateHandler(f.config, f.api, f.save, f.clock, f.media), /transport failed/);
  assert.equal(f.results.at(-1)!.stage, 'failed');
  assert.equal(f.attachments.at(-1)![0], false);
});
test('missing initial state fails within the injected clock bound without attaching', async () => {
  const f = fixture('before-deadline'); f.setStatus(undefined);
  await assert.rejects(driveLateHandler(f.config, f.api, f.save, f.clock, f.media), /observation timed out/);
  assert.equal(f.attachments.filter(([attached]) => attached).length, 0);
  assert.equal(f.media.starts, 0);
});
for (const bad of [null, {}, { handlerAttachDelayMS: -1 }, { handlerAttachDelayMS: NaN },
  { handlerAttachDelayMS: 0.5 }, { handlerAttachDelayMS: 60001 }, { scenario: 'unknown' },
  { connectDeadlineMS: 30000 }, { schemaVersion: 2 }, { runID: '../stale' }]) {
  test(`malformed fixture config fails closed: ${JSON.stringify(bad)}`, () => {
    const config = fixture('before-deadline').config;
    assert.equal(isLateHandlerConfiguration(bad === null || Object.keys(bad).length === 0 ? bad : { ...config, ...bad }), false);
  });
}

test('an early clock wake cannot attach the handler ahead of its due time', async () => {
  const f = fixture('before-deadline');
  const sleep = f.clock.sleepMS;
  let calls = 0;
  f.clock.sleepMS = async delay => { calls++; await sleep(calls === 1 ? delay - 1 : delay); };
  await driveLateHandler(f.config, f.api, f.save, f.clock, f.media);
  assert.equal(calls, 2);
  assert.equal(f.attachments[0]![2], 1000);
});

test('a preview Join failing for another reason is not a placement-timeout pass', async () => {
  const f = fixture('preview-placement');
  f.api.joinConversation = async () => { throw { code: 'handler_failed' }; };
  await assert.rejects(driveLateHandler(f.config, f.api, f.save, f.clock, f.media), /Expired preview Join/);
  assert.equal(f.results.at(-1)!.stage, 'failed');
});
