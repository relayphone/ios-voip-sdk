import { bootstrap, type BootstrapInfo } from 'ios-voip-sdk/internal/bootstrap';
import { useCallback, useEffect, useState } from 'react';
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
import { journey } from './journey';

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

export default function App() {
  const [status, setStatus] = useState<Status>({ phase: 'loading' });
  const [call, setCall] = useState<'idle' | 'busy' | 'ringing' | 'joined'>(
    'idle',
  );
  const [callMessage, setCallMessage] = useState('Ready for an example call.');

  const checkBootstrap = useCallback(async () => {
    setStatus({ phase: 'loading' });
    try {
      const info = await bootstrap();
      setStatus({ phase: 'ready', info });
      if (journey().acceptanceEnabled) {
        setCall('busy');
        setCallMessage('Running incoming call acceptance…');
        await journey().acceptance();
        setCall('idle');
        setCallMessage('Incoming ringing, joining and ending passed.');
      }
    } catch (error) {
      setStatus({
        phase: 'error',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, []);

  const callCommand = async (command: 'ring' | 'join' | 'end') => {
    const previous = call;
    setCall('busy');
    try {
      await journey()[command]();
      setCall(
        command === 'ring' ? 'ringing' : command === 'join' ? 'joined' : 'idle',
      );
      setCallMessage(
        command === 'ring'
          ? 'Incoming call ringing.'
          : command === 'join'
            ? 'Call joined.'
            : 'Call ended.',
      );
    } catch (error) {
      setCall(previous);
      setCallMessage(error instanceof Error ? error.message : String(error));
    }
  };

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
            Check that the Expo app can activate the SDK’s native simulator
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
                  Native module unavailable
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

          <Text accessibilityRole="header" style={styles.sectionTitle}>
            Calling journey
          </Text>
          <Text style={styles.secondary}>
            Report an example incoming call, join it, then end it. The example
            supplies a small native handler; media and signaling arrive in later
            milestones.
          </Text>
          <Text style={styles.body} accessibilityLiveRegion="polite">
            {callMessage}
          </Text>
          <Button
            title="Ring incoming call"
            disabled={status.phase !== 'ready' || call !== 'idle'}
            onPress={() => void callCommand('ring')}
          />
          <Button
            title="Join call"
            disabled={call !== 'ringing'}
            onPress={() => void callCommand('join')}
          />
          <Button
            title="End call"
            disabled={call !== 'ringing' && call !== 'joined'}
            onPress={() => void callCommand('end')}
          />
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
