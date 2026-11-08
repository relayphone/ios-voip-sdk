import type { Conversation, ConversationId, ConversationsApi } from '@relayphone/ios-voip-sdk';
import { journeyIDs, type JourneyResults, type JourneyStage } from './results.ts';

export type JourneyApi = Pick<ConversationsApi, 'getConversations' | 'setConversationHandler' | 'joinConversation'
  | 'endConversation' | 'setHeld' | 'startConversation' | 'reportConversation'>;
export type JourneyEvents = Pick<JourneyResults, 'actions' | 'outcomes' | 'elsewhere'>;

export async function driveJourney(runID: string, api: JourneyApi, events: JourneyEvents,
  save: (result: JourneyResults) => void,
  timing = { now: () => Date.now(), pause: () => new Promise<void>(resolve => setTimeout(resolve, 100)) },
): Promise<void> {
  const ids = journeyIDs(runID);
  const result: JourneyResults = { schemaVersion: 1, runID, stage: 'incoming', snapshots: [], handlers: [],
    ...events, completed: [] };
  const stage = (value: JourneyStage) => { result.stage = value; save(result); };
  async function until<T>(label: string, read: () => Promise<T | undefined>): Promise<T> {
    const deadline = timing.now() + 30_000;
    while (timing.now() < deadline) {
      const value = await read();
      if (value !== undefined) return value;
      await timing.pause();
    }
    throw new Error(`Timed out waiting for ${label}`);
  }
  async function snapshot(step: string, id: string, status: Conversation['status']): Promise<ConversationId> {
    const call = await until(step, async () => (await api.getConversations())
      .find(call => call.id === id && call.status === status));
    const preview = call.status === 'previewing' ? call.previewReason : undefined;
    result.snapshots.push({ step, id: call.id, status: call.status, direction: call.direction,
      previewReason: preview?.type, filterCause: preview?.type === 'filtered' ? preview.cause : undefined });
    return call.id;
  }
  async function end(name: keyof typeof ids, id: ConversationId) {
    await api.endConversation(id);
    await until(`${name} removed`, async () => (await api.getConversations()).every(call => call.id !== id) ? true : undefined);
    result.completed.push(name);
  }
  api.setConversationHandler({
    start(call, context) { result.handlers.push({ kind: 'start', id: call.id, origin: context.origin }); },
    join(call, context) { result.handlers.push({ kind: 'join', id: call.id, origin: context.origin }); },
  });
  try {
    stage('incoming');
    const incoming = await snapshot('incoming:ringing', ids.incoming, 'ringing');
    await api.joinConversation(incoming);
    await api.reportConversation(incoming, { type: 'connected' });
    await snapshot('incoming:connected', incoming, 'connected');
    await api.setHeld(incoming, true);
    await snapshot('incoming:held', incoming, 'held');
    await end('incoming', incoming);

    const outgoing = await api.startConversation({ id: ids.outgoing, to: { id: ids.outgoing }, video: false });
    if (outgoing !== ids.outgoing) throw new Error('Outgoing identity changed');
    await api.reportConversation(outgoing, { type: 'connected' });
    await snapshot('outgoing:connected', outgoing, 'connected');
    await end('outgoing', outgoing);

    // The host filters an incoming push to supply a real preview under the SDK's default policy.
    stage('preview');
    const preview = await snapshot('preview:previewing', ids.preview, 'previewing');
    await api.joinConversation(preview);
    await api.reportConversation(preview, { type: 'connected' });
    await snapshot('preview:connected', preview, 'connected');
    await end('preview', preview);

    stage('elsewhere');
    const elsewhere = await snapshot('elsewhere:ringing', ids.elsewhere, 'ringing');
    stage('server-event');
    await snapshot('elsewhere:previewing', elsewhere, 'previewing');
    await until('answeredElsewhere event', async () => events.elsewhere
      .find(event => event.conversationId === elsewhere && event.eventId === `${elsewhere}-answered`));
    await end('elsewhere', elsewhere);

    stage('filtered');
    const filtered = await snapshot('filtered:previewing', ids.filtered, 'previewing');
    await until('filtered push outcome', async () => events.outcomes.find(event => event.id === filtered));
    await end('filtered', filtered);
    await until('native event delivery', async () => {
      const actions = ['incoming:answer', 'incoming:hold', 'incoming:end', 'outgoing:start', 'outgoing:end', 'preview:join', 'preview:end'];
      return actions.every(action => { const [name, kind] = action.split(':');
        return events.actions.some(event => event.id === `${runID}-${name}` && event.kind === kind);
      }) && [ids.incoming, ids.preview, ids.elsewhere, ids.filtered].every(id => events.outcomes.some(event => event.id === id)) ? true : undefined;
    });
    stage('passed');
  } catch (error) {
    result.failure = String(error);
    stage('failed');
    throw error;
  } finally { api.setConversationHandler(null); }
}
