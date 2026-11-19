import * as calls from '@relayphone/ios-voip-sdk';
import { File, Paths } from 'expo-file-system';
import { useEffect, useRef } from 'react';
import { Linking, Platform } from 'react-native';
import { driveAndroidJourney } from './android';
import { driveJourney, type JourneyEvents } from './drive';

/** An explicit deep link runs the example's headless integration checks. */
export function Journeys() {
  const events = useRef<JourneyEvents>({ actions: [], outcomes: [], elsewhere: [] });
  const started = useRef(false);
  const conversations = calls.useConversations();
  calls.useConversationEvent('actionPerformed', event => {
    const { conversationId: id, action, origin } = event;
    events.current.actions.push({ id, kind: action.kind, origin });
    if (Platform.OS === 'android' && id.startsWith('fcm-test-')) {
      console.info(`VoIPPushExample ${id} ${action.kind} ${origin}`);
    }
  });
  useEffect(() => {
    if (Platform.OS !== 'android') return;
    for (const call of conversations) {
      if (call.id.startsWith('fcm-test-')) console.info(`VoIPPushExample ${call.id} ${call.status}`);
    }
  }, [conversations]);
  calls.useConversationEvent('answeredElsewhere', event => events.current.elsewhere.push(event));
  calls.useConversationEvent('incomingConversationOutcome', event => {
    const preview = event.outcome.status === 'previewed' ? event.outcome.reason : undefined;
    events.current.outcomes.push({ id: event.serverCallId, eventID: event.eventId, status: event.outcome.status,
      ...(preview && { previewReason: preview.type }),
      ...(preview?.type === 'filtered' && { filterCause: preview.cause }) });
  });
  useEffect(() => {
    const open = (url: string | null) => {
      if (!url || started.current) return;
      const parsed = new URL(url);
      if (parsed.protocol !== 'conversations-example:' || parsed.hostname !== 'journey') return;
      const runID = parsed.searchParams.get('runID');
      if (!runID || !/^[a-zA-Z0-9-]+$/.test(runID)) return;
      started.current = true;
      if (Platform.OS === 'android') {
        void driveAndroidJourney(runID, events.current).then(
          () => console.info(`VoIPJourney ${runID} passed`),
          error => console.error(`VoIPJourney ${runID} failed: ${String(error)}`),
        );
        return;
      }
      const output = new File(Paths.document, 'javascript-journeys.json');
      void driveJourney(runID, calls, events.current, result => output.write(JSON.stringify(result)))
        .catch(error => console.error('JavaScript journey failed', error));
    };
    const listener = Linking.addEventListener('url', event => open(event.url));
    void Linking.getInitialURL().then(open);
    new File(Paths.document, 'javascript-journeys-ready.json').write('{"ready":true}');
    if (Platform.OS === 'android') console.info('VoIPPushExample ready');
    return () => listener.remove();
  }, []);
  return null;
}
