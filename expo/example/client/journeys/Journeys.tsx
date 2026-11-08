import * as calls from '@relayphone/ios-voip-sdk';
import { File, Paths } from 'expo-file-system';
import { useEffect, useRef } from 'react';
import { Linking } from 'react-native';
import { driveJourney, type JourneyEvents } from './drive';

/** An explicit deep link runs the example's headless integration checks. */
export function Journeys() {
  const events = useRef<JourneyEvents>({ actions: [], outcomes: [], elsewhere: [] });
  const started = useRef(false);
  calls.useConversationEvent('actionPerformed', event => events.current.actions.push({
    id: event.conversationId, kind: event.action.kind, origin: event.origin,
  }));
  calls.useConversationEvent('answeredElsewhere', event => events.current.elsewhere.push(event));
  calls.useConversationEvent('incomingConversationOutcome', event => {
    const preview = event.outcome.status === 'previewed' ? event.outcome.reason : undefined;
    events.current.outcomes.push({ id: event.serverCallId, eventID: event.eventId, status: event.outcome.status,
      previewReason: preview?.type, filterCause: preview?.type === 'filtered' ? preview.cause : undefined });
  });
  useEffect(() => {
    const open = (url: string | null) => {
      if (!url || started.current) return;
      const parsed = new URL(url);
      if (parsed.protocol !== 'conversations-example:' || parsed.hostname !== 'journey') return;
      const runID = parsed.searchParams.get('runID');
      if (!runID || !/^[a-zA-Z0-9-]+$/.test(runID)) return;
      started.current = true;
      const output = new File(Paths.document, 'javascript-journeys.json');
      void driveJourney(runID, calls, events.current, result => output.write(JSON.stringify(result)))
        .catch(error => console.error('JavaScript journey failed', error));
    };
    const listener = Linking.addEventListener('url', event => open(event.url));
    void Linking.getInitialURL().then(open);
    new File(Paths.document, 'javascript-journeys-ready.json').write('{"ready":true}');
    return () => listener.remove();
  }, []);
  return null;
}
