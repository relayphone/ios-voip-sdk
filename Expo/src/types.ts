export type JSONValue =
  null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

/** Rejection codes projected from native startup, action and reporting errors.
 * Unknown system failures retain the generic conversation code and message.
 */
export type ConversationErrorCode =
  | 'invalid_arguments'
  | 'unknown_conversation'
  | 'unsupported'
  | 'at_capacity'
  | 'conversation'
  | 'duplicate_sdk_linkage';

export interface ConversationCommandError extends Error {
  readonly code: ConversationErrorCode;
}

/** Narrow a caught native rejection without assuming every thrown value is ours. */
export function isConversationCommandError(
  value: unknown,
): value is ConversationCommandError {
  if (!(value instanceof Error) || !('code' in value)) return false;
  return (
    value.code === 'invalid_arguments' ||
    value.code === 'unknown_conversation' ||
    value.code === 'unsupported' ||
    value.code === 'at_capacity' ||
    value.code === 'duplicate_sdk_linkage' ||
    value.code === 'conversation'
  );
}

export interface Participant {
  id: string;
  displayName?: string;
  avatarUrl?: string;
  phoneNumber?: string;
  email?: string;
}

/** Exact host-supplied identity reported to iOS. Phone values require an international + country code. */
export interface Caller {
  handleType: 'phone' | 'email' | 'generic';
  /** Phone inputs normalize formatting to E.164; email/generic values are not reinterpreted. */
  value: string;
  displayName: string;
  /** Opaque identifier in the host contact store, not an Apple Contacts identifier. */
  hostContactID?: string;
}

export interface IncomingCallPayload {
  eventId: string;
  serverCallId: string;
  caller: Caller;
  hasVideo: boolean;
  startedAt?: string;
  metadata?: { [key: string]: JSONValue };
}

/** A backend/host ownership signal; local hangs up through endConversation instead. */
export interface CallEndedPayload {
  eventId: string;
  serverCallId: string;
  reason: Exclude<EndedReason, 'local'>;
}

export type ConversationStatus =
  | 'ringing'
  | 'dialing'
  | 'connecting'
  | 'connected'
  | 'held'
  | 'ending'
  | 'ended';

export type EndedReason =
  | 'local'
  | 'remoteEnded'
  | 'failed'
  | 'unanswered'
  | 'answeredElsewhere'
  | 'declinedElsewhere';

export type ActionOrigin = 'system' | 'app';
export type ConversationActionKind =
  'join' | 'start' | 'end' | 'hold' | 'mute' | 'tones';

export interface PendingAction {
  id: string;
  kind: ConversationActionKind;
  /** Native deadline: earlier of advertised timeout and delivery-based cap, minus 3 seconds for start/join audio fulfillment, otherwise 1.5 seconds. */
  deadline: string;
  origin: ActionOrigin;
  held?: boolean;
  muted?: boolean;
  digits?: string;
}

export interface Conversation {
  id: string;
  direction: 'incoming' | 'outgoing';
  status: ConversationStatus;
  members: Participant[];
  capabilities: {
    hold: boolean;
    merge: boolean;
    tones: boolean;
    video: boolean;
  };
  isMuted: boolean;
  isVideo: boolean;
  connectedAt?: string;
  ended?: { at: string; reason: EndedReason };
  payload?: IncomingCallPayload;
  pending?: PendingAction;
}

export interface ActionContext {
  /** Native deadline: earlier of advertised timeout and delivery-based cap, minus 3 seconds for start/join audio fulfillment, otherwise 1.5 seconds. */
  deadline: string;
  signal: AbortSignal;
  origin: ActionOrigin;
}

type ActionHandler<Context extends ActionContext = ActionContext> = (
  conversation: Conversation,
  context: Context,
) => void | Promise<void>;

export interface ConversationHandler {
  join: ActionHandler;
  start: ActionHandler;
  end: ActionHandler;
  hold?: ActionHandler<ActionContext & { held: boolean }>;
  mute?: ActionHandler<ActionContext & { muted: boolean }>;
  tones?: ActionHandler<ActionContext & { digits: string }>;
}

export interface StartConversationOptions {
  to: Participant;
  video: boolean;
  metadata?: { [key: string]: JSONValue };
}

export type ConversationReport =
  | { type: 'connecting' }
  | { type: 'connected' }
  | { type: 'updated'; members?: Participant[]; video?: boolean }
  | { type: 'ended'; reason: EndedReason };

export interface PushToken {
  /** This iOS module supplies apns-voip; fcm preserves the shared RFC type. */
  type: 'apns-voip' | 'fcm';
  value: string;
}

export interface AudioRoute {
  readonly id: string;
  readonly name: string;
  /** AVAudioSession's raw port type value on iOS. */
  readonly type: string;
}

export interface AudioRoutes {
  readonly routes: readonly AudioRoute[];
  readonly current: AudioRoute | null;
}

/** M2 supplies watchdog signals; M3 supplies dial requests. */
export interface ConversationEventMap {
  audioActivated: { conversationId?: string };
  audioDeactivated: { conversationId?: string };
  audioActivationMissing: { conversationId: string };
  audioActivationFailed: { conversationId: string };
  pushTokenUpdated: PushToken | null;
  dialRequest: { handle: string; video: boolean };
  answeredElsewhere: {
    conversationId: string;
    serverCallId: string;
    eventId: string;
  };
  providerReset: Record<string, never>;
  providerOwnershipLost: Record<string, never>;
}
