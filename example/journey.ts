import { requireNativeModule, type NativeModule } from 'expo';

type JourneyModule = NativeModule & {
  acceptanceEnabled: boolean;
  m1Case: '' | 'journey' | 'cold-launch' | 'unhandled-expiry';
  systemCase:
    | ''
    | 'answer-end'
    | 'decline'
    | 'hold-accept'
    | 'end-accept'
    | 'mute-echo'
    | 'provider-reset'
    | 'push-launch';
  runID: string;
  nextSystemCommand(): Promise<{
    id: string;
    operation: string;
    conversationID?: string;
  }>;
  acceptance(): Promise<void>;
  simulatePush(
    payloadJSON: string,
    mustReport: boolean,
    label: 'primary' | 'cold',
  ): Promise<string>;
  waitForColdStart(): Promise<{
    conversationID: string;
    actionID: string;
    deadline: string;
  }>;
  trace(event: string, fieldsJSON: string): Promise<void>;
  finish(success: boolean): Promise<void>;
};

// The native fixture lives only in this example, outside the SDK package.
export function journey(): JourneyModule {
  return requireNativeModule<JourneyModule>('VoIPExampleJourney');
}
