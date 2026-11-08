import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Conversation, ConversationHandler, ConversationId } from '../../src/conversations/types.ts';
import { driveJourney, type JourneyApi, type JourneyEvents } from '../../example/client/journeys/drive.ts';
import { journeyIDs, type JourneyResults } from '../../example/client/journeys/results.ts';

function fixture() {
  const ids = journeyIDs('fixture');
  const events: JourneyEvents = { actions: [], outcomes: [], elsewhere: [] };
  let call: Conversation | undefined;
  let handler: ConversationHandler | null = null;
  const commands: string[] = [];
  function show(id: string, status: 'ringing' | 'connected' | 'held' | 'previewing', direction: 'incoming' | 'outgoing' = 'incoming') {
    // The fake native boundary preserves the application's ID, as the real module does.
    const base = { id: id as ConversationId, direction, members: [{ id }], isMuted: false, isVideo: false,
      capabilities: { hold: true, merge: true, tones: true, video: true } };
    switch (status) {
      case 'ringing': call = { ...base, status, direction: 'incoming' }; break;
      case 'previewing': call = { ...base, status, direction: 'incoming', previewReason: { type: 'filtered', cause: 'doNotDisturb' } }; break;
      case 'connected': call = { ...base, status, connectedAt: '2026-11-08T00:00:00Z' }; break;
      case 'held': call = { ...base, status }; break;
    }
  }
  const api: JourneyApi = {
    getConversations: async () => call ? [call] : [],
    setConversationHandler: value => { handler = value; },
    joinConversation: async id => {
      commands.push(`join:${id}`);
      const kind = call?.status === 'previewing' ? 'join' : 'answer';
      if (kind === 'join') await handler?.join?.(call!, { origin: 'app', deadline: '', signal: new AbortController().signal });
      events.actions.push({ id, kind, origin: 'app' });
      show(id, 'connected');
    },
    setHeld: async id => { commands.push(`hold:${id}`); events.actions.push({ id, kind: 'hold', origin: 'app' }); show(id, 'held'); },
    endConversation: async id => { commands.push(`end:${id}`); events.actions.push({ id, kind: 'end', origin: 'app' }); call = undefined; },
    startConversation: async options => {
      show(options.id, 'connected', 'outgoing');
      assert.ok(handler);
      await handler.start(call!, { origin: 'app', deadline: '', signal: new AbortController().signal });
      events.actions.push({ id: options.id, kind: 'start', origin: 'app' });
      return call!.id;
    },
    reportConversation: async id => { show(id, 'connected', call?.direction); },
  };
  const saved: JourneyResults[] = [];
  const save = (result: JourneyResults) => {
    saved.push(structuredClone(result));
    if (result.stage === 'incoming') {
      show(ids.incoming, 'ringing');
      events.outcomes.push({ id: ids.incoming, eventID: `${ids.incoming}-push`, status: 'reported' });
    }
    if (result.stage === 'preview' || result.stage === 'filtered') {
      const id = ids[result.stage];
      show(id, 'previewing');
      events.outcomes.push({ id, eventID: `${id}-push`, status: 'previewed', previewReason: 'filtered', filterCause: 'doNotDisturb' });
    }
    if (result.stage === 'elsewhere') {
      show(ids.elsewhere, 'ringing');
      events.outcomes.push({ id: ids.elsewhere, eventID: `${ids.elsewhere}-push`, status: 'reported' });
    }
    if (result.stage === 'server-event') {
      call = { ...call!, status: 'previewing', direction: 'incoming', previewReason: { type: 'answeredElsewhere' } };
      events.elsewhere.push({ conversationId: ids.elsewhere, serverCallId: ids.elsewhere, eventId: `${ids.elsewhere}-answered` });
    }
  };
  return { api, events, commands, saved, save, ids };
}

test('JavaScript drives all five journeys and consults only the start and preview-join handlers', async () => {
  const f = fixture();
  await driveJourney('fixture', f.api, f.events, f.save);
  const result = f.saved.at(-1)!;
  assert.equal(result.stage, 'passed');
  assert.deepEqual(result.completed, ['incoming', 'outgoing', 'preview', 'elsewhere', 'filtered']);
  assert.deepEqual(result.handlers, [
    { kind: 'start', id: f.ids.outgoing, origin: 'app' }, { kind: 'join', id: f.ids.preview, origin: 'app' },
  ]);
  assert.ok(f.commands.includes(`hold:${f.ids.incoming}`));
  assert.deepEqual(result.snapshots.map(s => s.step), [
    'incoming:ringing', 'incoming:connected', 'incoming:held', 'outgoing:connected',
    'preview:previewing', 'preview:connected', 'elsewhere:ringing', 'elsewhere:previewing', 'filtered:previewing',
  ]);
});

test('a rejected JavaScript command fails the journey once and records the failure', async () => {
  const f = fixture(); let attempts = 0;
  f.api.setHeld = async () => { attempts++; throw new Error('Hold refused'); };
  await assert.rejects(driveJourney('fixture', f.api, f.events, f.save), /Hold refused/);
  assert.equal(attempts, 1);
  assert.equal(f.saved.at(-1)!.stage, 'failed');
  assert.match(f.saved.at(-1)!.failure!, /Hold refused/);
});

test('missing snapshots fail at a bounded deadline without starting another journey', async () => {
  const f = fixture(); let now = 0;
  f.api.getConversations = async () => [];
  await assert.rejects(driveJourney('fixture', f.api, f.events, f.save,
    { now: () => now, pause: async () => { now += 10_000; } }), /incoming:ringing/);
  assert.equal(f.saved.at(-1)!.stage, 'failed');
  assert.deepEqual(f.saved.at(-1)!.completed, []);
  assert.deepEqual(f.commands, []);
});

test('completion waits for native events delivered after command promises resolve', async () => {
  const f = fixture(); let pauses = 0;
  await driveJourney('fixture', f.api, f.events, result => {
    f.save(result);
    if (result.stage === 'filtered') f.events.actions.splice(f.events.actions.findIndex(event => event.id === f.ids.preview && event.kind === 'end'), 1);
    if (result.stage === 'passed') assert.ok(f.events.actions.some(event => event.id === f.ids.preview && event.kind === 'end'));
  }, { now: () => pauses, pause: async () => {
    pauses++;
    f.events.actions.push({ id: f.ids.preview, kind: 'end', origin: 'app' });
  } });
  assert.equal(pauses, 1);
});
