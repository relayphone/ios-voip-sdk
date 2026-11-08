import type {
  ActionOrigin,
  AudioRoutes,
  CallPreviewActivities,
  FocusFilterState,
  Conversation,
  ConversationEventMap,
  ConversationsApi,
  ConversationsSnapshot,
  MediaAdapter,
  PushToken,
  Subscription,
} from "./types.ts";

/** Token revision timeline is independent of conversation state. @category Transport */
export interface PushTokenSnapshot {
  readonly revision: number;
  readonly token: PushToken | null;
}

/** Route revision timeline is independent of conversation state. @category Transport */
export interface AudioRoutesSnapshot extends AudioRoutes {
  readonly revision: number;
}

/**
 * Call preview revision timeline; `activities` is null on iOS without the `callPreviewActivities`
 * plugin option. @category Transport
 */
export interface CallPreviewActivitiesSnapshot {
  readonly revision: number;
  readonly activities: CallPreviewActivities | null;
}

/**
 * Focus filter revision timeline; `state` is null on iOS without the `focusFilter` plugin option.
 * @category Transport
 */
export interface FocusFilterStateSnapshot {
  readonly revision: number;
  readonly state: FocusFilterState | null;
}

/** Private native delivery; applications implement ConversationHandler instead. @category Transport */
export type HandlerAction = {
  readonly actionID: string;
  readonly generation: number;
  readonly conversation: Conversation;
  readonly deadline: string;
  readonly origin: ActionOrigin;
} & { readonly kind: "join" | "start" };

/** Discriminated native lifecycle event, excluding the revisioned token stream. @category Transport */
export type ConversationEvent = {
  [Name in Exclude<keyof ConversationEventMap, "pushTokenUpdated">]: {
    readonly type: Name;
    readonly payload: ConversationEventMap[Name];
  };
}[Exclude<keyof ConversationEventMap, "pushTokenUpdated">];

/** Native subscriptions attach before hydration or handler attachment. @category Transport */
export interface NativeEvents {
  readonly conversationsChanged: ConversationsSnapshot;
  readonly audioRoutesChanged: AudioRoutesSnapshot;
  readonly pushTokenUpdated: PushTokenSnapshot;
  readonly handlerAction: HandlerAction;
  readonly actionCancelled: {
    readonly actionID: string;
    readonly generation: number;
    readonly reason: string;
  };
  readonly conversationEvent: ConversationEvent;
  readonly callPreviewActivitiesChanged: CallPreviewActivitiesSnapshot;
  readonly focusFilterStateChanged: FocusFilterStateSnapshot;
}

/**
 * Internal native module transport. All state is copied immutable JSON.
 * Settlement is internal: generation plus action identity rejects replaced/late results.
 * @category Transport
 */
export interface NativeTransport
  extends Omit<
    ConversationsApi,
    "getConversations" | "setConversationHandler"
  > {
  /** O(1) cached native state; reading it performs no I/O or SDK work. */
  readonly snapshot: ConversationsSnapshot;
  readonly mediaAdapter: MediaAdapter;
  getConversations(): Promise<ConversationsSnapshot>;
  getAudioRoutes(): Promise<AudioRoutesSnapshot>;
  getPushToken(): Promise<PushTokenSnapshot>;
  /** iOS only. */
  getCallPreviewActivities?(): Promise<CallPreviewActivitiesSnapshot>;
  /** iOS only. */
  getFocusFilterState?(): Promise<FocusFilterStateSnapshot>;
  addListener<Name extends keyof NativeEvents>(
    name: Name,
    listener: (event: NativeEvents[Name]) => void
  ): Subscription;
  setHandlerAttached(attached: boolean, generation: number): void;
  settleAction(
    actionID: string,
    generation: number,
    success: boolean,
    error?: { readonly name: string; readonly message: string }
  ): void;
}
