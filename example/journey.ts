import { requireNativeModule, type NativeModule } from 'expo';

type JourneyModule = NativeModule & {
  acceptanceEnabled: boolean;
  ring(): Promise<string>;
  join(): Promise<void>;
  end(): Promise<void>;
  acceptance(): Promise<void>;
};

// The native fixture lives only in this example, outside the SDK package.
export function journey(): JourneyModule {
  return requireNativeModule<JourneyModule>('VoIPExampleJourney');
}
