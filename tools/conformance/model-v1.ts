import type { CallError, Configuration, Expectation, Input, State, WireID } from './model.ts';
import type { PushEnvelope, PushHealth, PushInput, PushRegistration } from './push-v1.ts';

export type PresentationState = State | 'authorizing' | 'held' | 'missed';
export type BodyTap = { readonly kind: 'openApp' | 'openCall' }
  | { readonly kind: 'registered'; readonly targetID: WireID };
export type PresentationDescriptor = Readonly<{
  state: PresentationState; title: string; body: string; lineLabel: string; bodyTap: BodyTap;
  extraActions: readonly Readonly<{ id: WireID; title: string }>[];
}>;
export type NotificationSurface = 'incomingCallStyle' | 'ongoingCallStyle' | 'serviceFallback' | 'sdkNotification' | 'preview';
export type SystemButton = 'answer' | 'decline' | 'hangUp';
export type PostRefusal = 'permission' | 'ineligible' | 'systemRefused';
export type NotificationObservation = Readonly<{ callID: WireID; surface: NotificationSurface; generation: number }> & (
  | { readonly kind: 'posted'; readonly descriptor: PresentationDescriptor; readonly systemButtons: readonly SystemButton[] }
  | { readonly kind: 'refused'; readonly reason: PostRefusal }
  | { readonly kind: 'shed' | 'removed' }
);

export type MediaStage = 'unprovided' | 'prejoining' | 'prejoined' | 'promoting' | 'preparing' | 'prepared' | 'releasing' | 'released';
export type MediaState = Readonly<{
  callID: WireID;
  owner: 'native' | 'application';
  transport: 'unknown' | 'disconnected' | 'connecting' | 'connected' | 'reconnecting';
  activation: 'unknown' | 'inactive' | 'active';
  capture: 'closed' | 'open'; output: 'closed' | 'open';
  firstPackets: Readonly<{ sent: 'unknown' | 'observed'; received: 'unknown' | 'observed' }>;
}> & (
  | { readonly stage: 'unprovided' }
  | { readonly stage: Exclude<MediaStage, 'unprovided'>; readonly attemptID: WireID }
);
export type AudioEndpoint = Readonly<{ id: WireID; kind: 'earpiece' | 'speaker' | 'wired' | 'bluetooth' | 'other' }>;
export type AudioRoute = Readonly<{
  callID: WireID;
  intent: { readonly kind: 'automatic' } | { readonly kind: 'endpoint'; readonly endpointID: WireID };
  observed: { readonly kind: 'unknown' | 'unavailable' } | { readonly kind: 'active'; readonly endpoint: AudioEndpoint };
}>;

export const features = [
  'hold', 'video', 'tones', 'preview', 'merge', 'prejoin', 'nativeAnswerAuthority', 'audioRoutes', 'push',
  'customPresentation', 'fullScreenIncoming', 'systemVideoUpgrade', 'systemVideoDowngrade', 'focusFiltering',
  'liveActivities', 'systemDialIntent',
] as const;
export type Feature = typeof features[number];
export type Unavailability = 'notImplemented' | 'unsupportedPlatform' | 'requiresSystemVersion' | 'requiresTransactional'
  | 'requiresMediaProvider' | 'requiresPermission' | 'disabledByPolicy' | 'unqualified' | 'unknown';
export type Capability = Readonly<{
  feature: Feature; callID?: WireID;
  availability: { readonly kind: 'available' } | { readonly kind: 'unavailable'; readonly reason: Unavailability };
}>;
type Condition = { readonly requires: string } | { readonly unavailable: Unavailability };
type AndroidCondition = Condition & Readonly<{ backend?: 'legacy' | 'transactional'; minApi?: number; maxApi?: number }>;
export type CapabilityCatalog = Readonly<{ version: 1; features: readonly Readonly<{
  feature: Feature; ios: readonly Condition[]; android: readonly AndroidCondition[];
}>[] }>;

export type TimingStage = 'pushIntake' | 'decode' | 'admission' | 'notification' | 'uiResume' | 'claim' | 'reconciliation'
  | 'placement' | 'mediaPreparation' | 'prejoin' | 'promotion' | 'audioEligibility' | 'activation' | 'connection'
  | 'firstSentPacket' | 'firstReceivedPacket' | 'teardown' | 'jsDelivery';
export type TimingEvent = Readonly<{
  stage: TimingStage; clockID: WireID; elapsedMicros: number; sequence: number;
  correlation: Readonly<{ eventID?: WireID; callID?: WireID; actionID?: WireID; attemptID?: WireID }>;
}> & (
  | { readonly boundary: 'started'; readonly outcome: 'pending' }
  | { readonly boundary: 'finished'; readonly outcome: 'succeeded' | 'failed' | 'refused' | 'timedOut' | 'cancelled' | 'unknown' }
  | { readonly boundary: 'observed'; readonly outcome: 'observed' }
);

type RecordEnvelope<K, V> = Readonly<{ version: 1; kind: K; value: V }>;
export type ModelV1 = RecordEnvelope<'presentationDescriptor', PresentationDescriptor>
  | RecordEnvelope<'notificationObservation', NotificationObservation>
  | RecordEnvelope<'mediaState', MediaState> | RecordEnvelope<'audioRoute', AudioRoute>
  | RecordEnvelope<'pushEnvelope', PushEnvelope> | RecordEnvelope<'pushRegistration', PushRegistration>
  | RecordEnvelope<'pushHealth', PushHealth> | RecordEnvelope<'capability', Capability> | RecordEnvelope<'timing', TimingEvent>;
export type InputV1 = Input | PushInput
  | { readonly kind: 'presentation'; readonly callID: WireID; readonly descriptor: PresentationDescriptor }
  | { readonly kind: 'refuseNotificationPost'; readonly callID: WireID; readonly surface: NotificationSurface; readonly reason: PostRefusal }
  | { readonly kind: 'enablePrejoin'; readonly callID: WireID; readonly attemptID: WireID }
  | { readonly kind: 'mediaFeedback'; readonly callID: WireID; readonly attemptID: WireID;
      readonly signal: 'prejoined' | 'promoted' | 'activated' | 'firstReceivedPacket' | 'firstSentPacket' }
  | { readonly kind: 'toneTransport'; readonly available: boolean }
  | { readonly kind: 'deferSystemRemoval' | 'systemRemoved'; readonly callID: WireID };
export type ExpectationV1 = Expectation
  | { readonly kind: 'record'; readonly record: ModelV1 }
  | { readonly kind: 'actionError'; readonly callID: WireID; readonly error: CallError }
  | { readonly kind: 'cleanup'; readonly callID: WireID; readonly outcome: 'removed' | 'failed' }
  | { readonly kind: 'callAbsent'; readonly callID: WireID };
export type JourneyV1 = Readonly<{ version: 1; id: WireID; configuration: Configuration;
  steps: readonly ({ readonly kind: 'input'; readonly input: InputV1 } | { readonly kind: 'expect'; readonly expectation: ExpectationV1 })[] }>;
