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
type Events = { change: (event: ChangeEvent) => void };

declare class Expo2SpikeModule extends NativeModule<Events> {
  readonly snapshot: Snapshot;
  publish(version: number): void;
  drainChanges(): Promise<void>;
  writeResults(json: string): Promise<void>;
}

export default requireNativeModule<Expo2SpikeModule>('Expo2Spike');
