import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { runDemonstrations } from './demonstrations';

export default function App() {
  const [status, setStatus] = useState('Running demonstrations…');
  useEffect(() => {
    void runDemonstrations()
      .then((results) => {
        setStatus(
          results.every((result) => result.pass)
            ? `Passed ${results.length} demonstrations`
            : JSON.stringify(results),
        );
      })
      .catch((error) => setStatus(String(error)));
  }, []);
  return (
    <View style={styles.container}>
      <Text accessibilityRole="header" style={styles.title}>
        Expo Modules 2.0 spike
      </Text>
      <Text testID="demo-status">{status}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    padding: 32,
    gap: 16,
    backgroundColor: '#fff',
  },
  title: { fontSize: 24, fontWeight: '600' },
});
