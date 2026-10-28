import { requireNativeModule, type NativeModule } from 'expo';

export interface MediaSnapshot {
  label: string;
  moduleID: string;
  deviceID: string;
  inputAvailable: boolean;
  outputAvailable: boolean;
  isEngineRunning: boolean;
  category: string;
  mode: string;
  activatedCount: number;
  deactivatedCount: number;
  missingCount: number;
  failedCount: number;
}

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
    | 'answered-elsewhere'
    | 'push-launch';
  m2Case: '' | 'livekit' | 'stale-audio';
  runID: string;
  dialRequestAcceptanceEnabled: boolean;
  deliverDialRequests(): Promise<void>;
  observedDialRequest(handle: string, video: boolean): Promise<void>;
  nextSystemCommand(): Promise<{
    id: string;
    operation: string;
    conversationID?: string;
    serverCallId?: string;
  }>;
  acceptance(): Promise<void>;
  /** Simulator-only, example-only public getters on the existing selected ADM. */
  mediaSnapshot(label: string): Promise<string>;
  /** Runner-bound fault readiness receipt, simulator-only. */
  awaitMediaControl(): Promise<void>;
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
