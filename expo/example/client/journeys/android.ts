import * as calls from '@relayphone/ios-voip-sdk';
import type { JourneyEvents } from './drive';

export async function driveAndroidJourney(runID: string, events: JourneyEvents) {
  const requireStatus = async (id: string, status: string) => {
    const deadline = Date.now() + 5_000;
    do {
      const call = (await calls.getConversations()).find(call => call.id === id);
      if (call?.status === status) return;
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
}
