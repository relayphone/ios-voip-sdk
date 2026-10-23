import { StyleSheet, Text, View } from 'react-native';
import Expo2Spike from './modules/expo2-spike';

export default function App() {
  return (
    <View style={styles.container}>
      <Text accessibilityRole="header" style={styles.title}>
        Expo Modules 2.0 spike
      </Text>
      <Text testID="native-greeting">{Expo2Spike.hello()}</Text>
      <Text>Scaffold only. Bridge demonstrations follow in separate PRs.</Text>
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
