import { NativeModule, requireNativeModule } from 'expo';

export type ConversationId = string & {
  readonly __conversationId: unique symbol;
};
export type Conversation =
  | Readonly<{ id: ConversationId; status: 'ringing'; caller: string }>
  | Readonly<{ id: ConversationId; status: 'active'; connectedAt: number }>;
export type Snapshot = Readonly<{
  version: number;
  conversations: readonly Conversation[];
}>;
export type ChangeEvent = Readonly<{ snapshot: Snapshot; version: number }>;
export type ThreadSample = Readonly<{
  phase: string;
  threadID: string;
  threadName: string;
  queueLabel: string;
  isMainThread: boolean;
  isOnJavaScriptThread: boolean;
  supportsAsyncScheduling: boolean;
}>;
export type SDKReply = Readonly<{
  sequence: number;
  threads: readonly ThreadSample[];
}>;
type Events = {
  change: (event: ChangeEvent) => void;
  background: (event: ThreadSample) => void;
};

declare class Expo2SpikeModule extends NativeModule<Events> {
  readonly snapshot: Snapshot;
  resetHazard(): void;
  hazardCount(scheduled: boolean): number;
  hazardIncrement(scheduled: boolean): Promise<ThreadSample>;
  publish(version: number): void;
  configureFixture(count: number): void;
  threadSample(phase: string): ThreadSample;
  defaultProbe(): Promise<readonly ThreadSample[]>;
  sdkProbe(): Promise<SDKReply>;
  emitFromBackground(): void;
  drainChanges(): Promise<void>;
  writeResults(json: string): Promise<void>;
}

export default requireNativeModule<Expo2SpikeModule>('Expo2Spike');
