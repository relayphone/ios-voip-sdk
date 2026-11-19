import * as calls from '@relayphone/ios-voip-sdk';
import type { JourneyEvents } from './drive';

export async function driveAndroidJourney(runID: string, events: JourneyEvents) {
  const requireStatus = async (id: string, status: string) => {
    const deadline = Date.now() + 5_000;
    do {
      const call = (await calls.getConversations()).find(call => call.id === id);
      if (call?.status === status) return call;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw new Error(`${id} never reached ${status}`);
  };
  const incoming = await calls.reportIncomingConversation({
    eventId: `${runID}-invite`, serverCallId: `${runID}-incoming`, hasVideo: false,
    caller: { handleType: 'generic', value: 'caller', displayName: 'Caller' },
  });
  if (incoming.status !== 'reported') throw new Error(`Incoming call was ${incoming.status}`);
  await requireStatus(incoming.id, 'ringing');
  const duplicate = await calls.reportIncomingConversation({
    eventId: `${runID}-invite`, serverCallId: `${runID}-retry`, hasVideo: false,
    caller: { handleType: 'generic', value: 'caller', displayName: 'Caller' },
  });
  if (duplicate.status !== 'reported' || duplicate.id !== incoming.id) {
    throw new Error('Duplicate invitation lost the original call identity');
  }
  await calls.joinConversation(incoming.id);
  await requireStatus(incoming.id, 'connecting');
  await calls.endConversation(incoming.id);
  await calls.endConversation(incoming.id);
  await requireStatus(incoming.id, 'ended');

  for (const kind of ['answer', 'end']) {
    const actions = events.actions.filter(action => action.id === incoming.id && action.kind === kind);
    if (actions.length !== 1 || actions[0]?.origin !== 'app') {
      throw new Error(`Expected one app ${kind} event`);
    }
  }

  const placed: string[] = [];
  calls.setConversationHandler({
    async start(call, context) {
      if (call.direction !== 'outgoing' || !call.capabilities.hold || context.origin !== 'app') {
        throw new Error('Unexpected outgoing placement request');
      }
      placed.push(call.id);
      await calls.reportConversation(call.id, { type: 'connecting' });
    },
  });
  try {
    const local = await start(`${runID}-outgoing`);
    const connected = await requireStatus(local, 'connected');
    await calls.setHeld(local, true);
    const held = await requireStatus(local, 'held');
    await calls.setHeld(local, false);
    const resumed = await requireStatus(local, 'connected');
    if (held.connectedAt !== connected.connectedAt || resumed.connectedAt !== connected.connectedAt) {
      throw new Error('Hold changed the connection time');
    }
    await calls.endConversation(local);
    const locallyEnded = await requireStatus(local, 'ended');
    if (locallyEnded.ended?.reason !== 'local') throw new Error('Expected a local end');

    const remote = await start(`${runID}-outgoing-remote`);
    if (!await calls.receiveCallEnded({
      serverCallId: remote, eventId: `${runID}-remote-end`, reason: 'remoteEnded',
    })) throw new Error('Remote end was not applied');
    const remotelyEnded = await requireStatus(remote, 'ended');
    if (remotelyEnded.ended?.reason !== 'remoteEnded') throw new Error('Expected a remote end');

    requireActions(local, ['start', 'hold', 'hold', 'end']);
    requireActions(remote, ['start']);
    if (placed.join() !== [local, remote].join()) throw new Error('Expected one placement per outgoing call');
  } finally {
    calls.setConversationHandler({ start() {} });
  }

  async function start(id: string) {
    const outgoing = await calls.startConversation({ id, to: { id: 'callee', displayName: 'Callee' }, video: false });
    if (outgoing !== id) throw new Error('Outgoing identity changed');
    await requireStatus(outgoing, 'connecting');
    await calls.reportConversation(outgoing, { type: 'connected' });
    await requireStatus(outgoing, 'connected');
    return outgoing;
  }

  function requireActions(id: string, kinds: readonly string[]) {
    const actions = events.actions.filter(action => action.id === id);
    if (actions.map(action => action.kind).join() !== kinds.join() || actions.some(action => action.origin !== 'app')) {
      throw new Error(`Unexpected action receipts for ${id}`);
    }
  }
}
