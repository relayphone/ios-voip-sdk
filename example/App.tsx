import {
  endConversation,
  joinConversation,
  reportConversation,
  reportIncomingConversation,
  setConversationHandler,
  setHeld,
  useConversationEvent,
  useConversations,
  usePushToken,
} from 'ios-voip-sdk';
import { bootstrap, type BootstrapInfo } from 'ios-voip-sdk/internal/bootstrap';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Button,
  PlatformColor,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import {
  exampleHandler,
  observeConversations,
  observeToken,
  runAcceptance,
  trace,
} from './acceptance';
import { journey } from './journey';
import {
  observeSystem,
  runSystemAcceptance,
  systemTrace,
} from './system-acceptance';

type Status =
  | { phase: 'loading' }
  | { phase: 'ready'; info: BootstrapInfo }
  | { phase: 'error'; message: string };

function StatusRow({ label, value }: { label: string; value: string }) {
  return (
    <View
      style={styles.row}
      accessible
      accessibilityLabel={`${label}: ${value}`}
    >
      <Text style={styles.label}>{label}</Text>
      <Text style={styles.value}>{value}</Text>
    </View>
  );
}

function CallingJourney() {
  const conversations = useConversations();
  const pushToken = usePushToken();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('Ready for an example call.');
  const automated =
    journey().acceptanceEnabled ||
    journey().m1Case !== '' ||
    journey().systemCase !== '';
  const conversation = conversations[0];

  useEffect(() => {
    if (!automated) {
      setConversationHandler(exampleHandler());
      return () => setConversationHandler(null);
    }
  }, [automated]);
  useEffect(() => {
    if (journey().m1Case !== '') observeConversations(conversations);
    if (journey().systemCase !== '') observeSystem(conversations);
  }, [conversations]);
  useEffect(() => {
    if (journey().m1Case !== '') observeToken(pushToken);
  }, [pushToken]);
  const observeEvent = (name: string) => {
    if (journey().m1Case !== '') void trace('m1.event', { name });
    if (journey().systemCase !== '') void systemTrace('system.event', { name });
  };
  useConversationEvent('audioActivated', () => observeEvent('audioActivated'));
  useConversationEvent('audioDeactivated', () =>
    observeEvent('audioDeactivated'),
  );
  useConversationEvent('providerReset', () => observeEvent('providerReset'));
  useConversationEvent('pushTokenUpdated', () =>
    observeEvent('pushTokenUpdated'),
  );

  const command = async (operation: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await operation();
      setMessage('Request accepted. State follows the system.');
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : 'The request failed.',
      );
    } finally {
      setBusy(false);
    }
  };
  const ring = () => {
    const unique = Date.now().toString();
    return reportIncomingConversation({
      eventId: 'sdk-example-event-' + unique,
      serverCallId: 'sdk-example-server-' + unique,
      caller: {
        handleType: 'phone',
        value: '+15555550142',
        displayName: 'SDK example',
        hostContactID: 'sdk-example-caller',
      },
      hasVideo: false,
    });
  };

  return (
    <>
      <Text accessibilityRole="header" style={styles.sectionTitle}>
        Calling journey
      </Text>
      <Text style={styles.secondary}>
        Commands, the handler and this state view use the SDK’s public API. This
        example accepts signaling requests locally; a real app supplies its own
        transport and media.
      </Text>
      <StatusRow
        label="Conversation"
        value={conversation?.status ?? 'No active call'}
      />
      <StatusRow
        label="Push token"
        value={pushToken === null ? 'Not registered' : 'Registered'}
      />
      <Text style={styles.body} accessibilityLiveRegion="polite">
        {message}
      </Text>
      <Button
        title="Ring incoming call"
        disabled={automated || busy || conversations.length !== 0}
        onPress={() => void command(ring)}
      />
      <Button
        title="Join call"
        disabled={automated || busy || conversation?.status !== 'ringing'}
        onPress={() =>
          conversation && void command(() => joinConversation(conversation.id))
        }
      />
      <Button
        title="Report connected"
        disabled={
          automated ||
          busy ||
          conversation?.pending !== undefined ||
          !['connecting', 'dialing'].includes(conversation?.status ?? '')
        }
        onPress={() =>
          conversation &&
          void command(() =>
            reportConversation(conversation.id, { type: 'connected' }),
          )
        }
      />
      <Button
        title={conversation?.status === 'held' ? 'Resume call' : 'Hold call'}
        disabled={
          automated ||
          busy ||
          !conversation ||
          !['connected', 'held'].includes(conversation.status)
        }
        onPress={() =>
          conversation &&
          void command(() =>
            setHeld(conversation.id, conversation.status !== 'held'),
          )
        }
      />
      <Button
        title="End call"
        disabled={automated || busy || !conversation}
        onPress={() =>
          conversation && void command(() => endConversation(conversation.id))
        }
      />
    </>
  );
}

export default function App() {
  const [status, setStatus] = useState<Status>({ phase: 'loading' });
  const [acceptanceMessage, setAcceptanceMessage] = useState('');
  const acceptanceStarted = useRef(false);

  const checkBootstrap = useCallback(async () => {
    setStatus({ phase: 'loading' });
    try {
      const info = await bootstrap();
      if (
        !acceptanceStarted.current &&
        (journey().acceptanceEnabled ||
          journey().m1Case !== '' ||
          journey().systemCase !== '')
      ) {
        acceptanceStarted.current = true;
        setAcceptanceMessage('Running simulator acceptance…');
        if (journey().acceptanceEnabled) {
          setStatus({ phase: 'ready', info });
          await journey().acceptance();
        } else if (journey().systemCase !== '') {
          setStatus({ phase: 'ready', info });
          await runSystemAcceptance();
        } else {
          if (['cold-launch', 'unhandled-expiry'].includes(journey().m1Case)) {
            // No public SDK runtime/state hook has been created yet. Cold state
            // must exist before the panel subscribes or requests its snapshot.
            await journey().waitForColdStart();
          }
          await trace('m1.jsReady');
          await trace('m1.subscriptionsStarting');
          setStatus({ phase: 'ready', info });
          await runAcceptance();
        }
        setAcceptanceMessage('Simulator acceptance passed.');
      } else {
        setStatus({ phase: 'ready', info });
      }
    } catch (error) {
      try {
        if (journey().m1Case !== '' || journey().systemCase !== '')
          await journey().finish(false);
      } catch {
        // Preserve the screen's native-module loading error if no fixture exists.
      }
      setStatus({
        phase: 'error',
        message:
          error instanceof Error ? error.message : 'The native request failed.',
      });
    }
  }, []);
  useEffect(() => {
    void checkBootstrap();
  }, [checkBootstrap]);

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.safeArea}>
        <ScrollView contentContainerStyle={styles.content}>
          <Text accessibilityRole="header" style={styles.title}>
            VoIP SDK Example
          </Text>
          <Text style={styles.body}>
            Calls use the SDK’s sole conversation client and built-in simulator
            support.
          </Text>
          <View style={styles.status} accessibilityLiveRegion="polite">
            {status.phase === 'loading' && (
              <View style={styles.loading}>
                <ActivityIndicator accessibilityLabel="Checking native module" />
                <Text style={styles.body}>Checking native module…</Text>
              </View>
            )}
            {status.phase === 'ready' && (
              <>
                <StatusRow label="Native module" value="Loaded" />
                <StatusRow
                  label="Environment"
                  value={status.info.simulator ? 'iOS Simulator' : 'iOS device'}
                />
                <StatusRow
                  label="Simulator runtime"
                  value={
                    status.info.runtimeActive
                      ? 'Active'
                      : 'Using system behavior'
                  }
                />
              </>
            )}
            {status.phase === 'error' && (
              <>
                <Text accessibilityRole="header" style={styles.sectionTitle}>
                  Native request failed
                </Text>
                <Text selectable style={styles.body}>
                  {status.message}
                </Text>
                <Text style={styles.secondary}>
                  Build the example with its native iOS module, then check
                  again.
                </Text>
              </>
            )}
          </View>
          <View style={styles.button}>
            <Button
              title="Check again"
              onPress={() => void checkBootstrap()}
              disabled={status.phase === 'loading'}
            />
          </View>
          {acceptanceMessage !== '' && (
            <Text style={styles.body}>{acceptanceMessage}</Text>
          )}
          {status.phase === 'ready' && <CallingJourney />}
        </ScrollView>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: PlatformColor('systemBackgroundColor'),
  },
  content: {
    width: '100%',
    maxWidth: 600,
    alignSelf: 'center',
    padding: 24,
    gap: 16,
  },
  title: {
    color: PlatformColor('labelColor'),
    fontSize: 30,
    fontWeight: '700',
  },
  body: { color: PlatformColor('labelColor'), fontSize: 17, lineHeight: 25 },
  secondary: {
    color: PlatformColor('secondaryLabelColor'),
    fontSize: 17,
    lineHeight: 25,
  },
  status: { marginTop: 16, gap: 12 },
  loading: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: 16,
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: PlatformColor('separatorColor'),
  },
  label: { flex: 1, color: PlatformColor('labelColor'), fontSize: 17 },
  value: {
    flex: 1,
    color: PlatformColor('secondaryLabelColor'),
    fontSize: 17,
    textAlign: 'right',
  },
  button: { minHeight: 48, justifyContent: 'center' },
  sectionTitle: {
    marginTop: 16,
    color: PlatformColor('labelColor'),
    fontSize: 20,
    fontWeight: '600',
  },
});
