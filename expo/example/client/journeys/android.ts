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
  await calls.reportConversation(incoming.id, { type: 'connected' });
  await requireStatus(incoming.id, 'connected');
  await verifyAudio(incoming.id);
  await calls.endConversation(incoming.id);
  await calls.endConversation(incoming.id);
  await requireStatus(incoming.id, 'ended');

  for (const kind of ['answer', 'end', 'tones']) {
    const actions = events.actions.filter(action => action.id === incoming.id && action.kind === kind);
    if (actions.length !== 1 || actions[0]?.origin !== 'app') {
      throw new Error(`Expected one app ${kind} event`);
    }
  }
  const mutes = events.actions.filter(action => action.id === incoming.id && action.kind === 'mute');
  if (mutes.length !== 2 || mutes.some(action => action.origin !== 'app')) {
    throw new Error('Expected an app receipt for both mute changes');
  }
}

async function verifyAudio(id: calls.ConversationId) {
  const initial = await requireRoutes(routes => routes.some(route => route.type === 'builtInReceiver') &&
    routes.some(route => route.type === 'builtInSpeaker'), 'Missing earpiece or speaker endpoint');
  const receiver = initial.routes.find(route => route.type === 'builtInReceiver');
  const speaker = initial.routes.find(route => route.type === 'builtInSpeaker');
  if (!receiver || !speaker) throw new Error('Missing earpiece or speaker endpoint');
  await calls.selectAudioRoute(receiver.id);
  const earpiece = await requireRoute(receiver.id);
  await calls.selectAudioRoute(speaker.id);
  const speakerphone = await requireRoute(speaker.id);
  if (speakerphone.revision <= earpiece.revision) throw new Error('Speaker selection did not advance the route revision');
  await calls.selectAudioRoute(receiver.id);
  const restored = await requireRoute(receiver.id);
  if (restored.revision <= speakerphone.revision) throw new Error('Earpiece selection did not advance the route revision');

  for (const muted of [true, false]) {
    await calls.setMuted(id, muted);
    const call = (await calls.getConversations()).find(item => item.id === id);
    if (call?.isMuted !== muted) throw new Error('Mute completed before the updated state was readable');
  }
  await calls.playTones(id, '12*#');
}

function requireRoute(id: string) {
  return requireRoutes((_, current) => current?.id === id, 'Telecom did not confirm the selected route');
}

async function requireRoutes(
  matches: (routes: readonly calls.AudioRoute[], current: calls.AudioRoute | null) => boolean,
  error: string,
) {
  const deadline = Date.now() + 5_000;
  do {
    const state = await calls.getAudioRoutes();
    if (matches(state.routes, state.current)) return state;
    await new Promise(resolve => setTimeout(resolve, 50));
  } while (Date.now() < deadline);
  throw new Error(error);
}
