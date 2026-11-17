import { registerRootComponent } from 'expo';
import { File, Paths } from 'expo-file-system';
import * as calls from '@relayphone/ios-voip-sdk';
import { driveLateHandler, lateHandlerConfiguration } from './late-handler';

// This entry is selected only by the bundled integration build. Normal example startup is unchanged.
const input = new File(Paths.document, 'late-handler-config.json');
if (input.exists) {
  registerRootComponent(() => null);
  const output = new File(Paths.document, 'late-handler-results.json');
  const config = lateHandlerConfiguration(JSON.parse(input.textSync()));
  void driveLateHandler(config, calls, result => output.write(JSON.stringify(result)))
    .catch(error => console.error('Late-handler journey failed', error));
} else {
  // Loading the ordinary example would attach its top-level handler before the configured delay.
  registerRootComponent(require('../App').default);
}
