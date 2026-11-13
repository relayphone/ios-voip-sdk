import type { NativeTransport } from "../conversations/transport";
// @ts-expect-error Transport details are internal.
import type { NativeTransport as PublicTransport } from "../index";
/* eslint-disable no-void -- Compile-only expressions exercise the public contract. */
import { receiveCallEnded } from "../api";
import type {
  ActionContext,
  Conversation,
  ConversationHandler,
  ConversationId,
  ConversationsApi,
  ConversationsSnapshot,
  IncomingConversationOutcome,
  PendingAction,
  IncomingCallPayload,
  Caller,
  CallEndedPayload,
  CallNotificationEvent,
  CallNotificationRoute,
  CallPreviewActivities,
  CallPreviewEvent,
  FocusFilterState,
  ConversationEventMap,
  ConversationEnd,
  EndedFailure,
  EndedFailureKind,
  EndedReason,
  IncomingFilterReason,
  JSONValue,
  PreviewReason,
} from "../conversations";

declare const api: ConversationsApi;
declare const conversation: Conversation;
declare const id: ConversationId;
declare const snapshot: ConversationsSnapshot;
declare const action: PendingAction;
declare const outcome: IncomingConversationOutcome;
void api.joinConversation(id);
// @ts-expect-error A server id is not a native ConversationId.
void api.joinConversation("server-call-id");
// @ts-expect-error Snapshots are immutable, including nested members.
conversation.members.push({ id: "someone" });
void api.reportIncomingConversation({
  eventId: "e",
  serverCallId: "s",
  caller: { handleType: "generic", value: "p", displayName: "Caller" },
  hasVideo: false,
  // @ts-expect-error Payload metadata is JSON, not arbitrary class instances.
  metadata: { date: new Date() },
});
// @ts-expect-error An ended report must include its reason.
void api.reportConversation(id, { type: "ended" });
// @ts-expect-error Applications cannot rewrite the native revision.
snapshot.revision = 7;

if (conversation.status === "connected") {
  const connectedAt: string = conversation.connectedAt;
  void connectedAt;
}
if (conversation.status === "reconnecting") {
  const connectedAt: string = conversation.connectedAt;
  void connectedAt;
  // @ts-expect-error Reconnecting timestamps are immutable.
  conversation.connectedAt = "replacement";
}
type Reconnecting = Extract<Conversation, { readonly status: "reconnecting" }>;
// @ts-expect-error Reconnecting requires the original connection timestamp.
const missingReconnectTime: Reconnecting = { ...conversation, status: "reconnecting", connectedAt: undefined };
void missingReconnectTime;
if (conversation.status === "ringing") {
  const incoming: "incoming" = conversation.direction;
  void incoming;
}
if (conversation.ended?.reason === "failed") {
  const failure: EndedFailure | undefined = conversation.ended.failure;
  if (failure?.kind === "filtered") {
    const cause: IncomingFilterReason = failure.cause;
    void cause;
  } else if (failure) {
    const kind: EndedFailureKind = failure.kind;
    void kind;
  }
} else if (conversation.ended) {
  // @ts-expect-error Only a failed conversation carries a native failure.
  void conversation.ended.failure;
}
// The end shape before failures were added still type-checks.
declare const reasonOnly: { readonly at: string; readonly reason: EndedReason };
const compatibleEnd: ConversationEnd = reasonOnly;
const endedReason: EndedReason | undefined = conversation.ended?.reason;
void compatibleEnd;
void endedReason;
const nativeFailure: ConversationEnd = {
  at: "2026-10-31T00:00:00.000Z",
  reason: "failed",
  failure: { kind: "audioActivationTimedOut" },
};
void nativeFailure;
// @ts-expect-error A filtered failure carries the filter's cause.
const filteredWithoutCause: EndedFailure = { kind: "filtered" };
void filteredWithoutCause;
// @ts-expect-error Failure kinds are the SDK's known cases.
const unknownFailure: EndedFailure = { kind: "somethingElse" };
void unknownFailure;
const remoteFailure: ConversationEnd = {
  at: "2026-10-31T00:00:00.000Z",
  reason: "remoteEnded",
  // @ts-expect-error A conversation that didn't fail has no failure.
  failure: { kind: "server" },
};
void remoteFailure;
const placementKind: "start" | "join" = action.kind;
void placementKind;
// @ts-expect-error Native action arguments never appear on a placement action.
void action.held;
if (conversation.status === "previewing") {
  const incoming: "incoming" = conversation.direction;
  const reason: PreviewReason = conversation.previewReason;
  if (reason.type === "filtered") {
    const cause: IncomingFilterReason = reason.cause;
    void cause;
  }
  void incoming;
}
if (outcome.status === "previewed") {
  // A call preview is a conversation, which the app can join.
  void api.joinConversation(outcome.id);
  const reason: PreviewReason = outcome.reason;
  void reason;
}
if (outcome.status === "notShown") {
  // @ts-expect-error A call that doesn't appear has no conversation id.
  void outcome.id;
}
if (outcome.status === "reported") {
  void api.endConversation(outcome.id);
} else if (outcome.status !== "previewed") {
  // @ts-expect-error Filtered/failed reports cannot manufacture a conversation id.
  void outcome.id;
}

const handler: ConversationHandler = {
  async join(_, context: ActionContext) {
    context.signal.throwIfAborted();
  },
  start() {},

};
api.setConversationHandler(handler);
api.setConversationHandler(null);
// @ts-expect-error Attaching a handler still requires the start placement callback.
api.setConversationHandler({ mute() {} });

declare const native: NativeTransport;
native.addListener("conversationsChanged", ({ revision, conversations }) => {
  const latest: ConversationsSnapshot = { revision, conversations };
  void latest;
});
// @ts-expect-error Versioned change events cannot omit the revision.
const invalidSnapshot: ConversationsSnapshot = { conversations: [] };
void invalidSnapshot;

const invitation: IncomingCallPayload = {
  eventId: "event",
  serverCallId: "call",
  caller: { handleType: "generic", value: "owner", displayName: "Owner" },
  hasVideo: false,
  media: {
    provider: "livekit",
    url: "wss://media.invalid",
    room: "room",
    identity: "owner-device",
    token: "test-fixture-not-a-token",
    expiresAt: 1798000000,
  },
};
void invitation;
// Match the SDK #150 public input shape, including mutability and optional host ID.
type Same<Left, Right> = (<T>() => T extends Left ? 1 : 2) extends <
  T
>() => T extends Right ? 1 : 2
  ? true
  : false;
const callerShape: Same<
  Caller,
  {
    handleType: "phone" | "email" | "generic";
    value: string;
    displayName: string;
    hostContactID?: string;
  }
> = true;
void callerShape;
const obsoleteCaller: Caller = {
  // @ts-expect-error Incoming callers no longer use the Participant id child.
  id: "legacy",
};
void obsoleteCaller;

// Match SDK #159's host/server end input and acceptance result.
const endedShape: Same<
  CallEndedPayload,
  {
    eventId: string;
    serverCallId: string;
    reason: Exclude<EndedReason, "local">;
  }
> = true;
const receiveEndedSignature: Same<
  typeof receiveCallEnded,
  (payload: CallEndedPayload) => Promise<boolean>
> = true;
void endedShape;
void receiveEndedSignature;
const ended: CallEndedPayload = {
  eventId: "end-event",
  serverCallId: "server-call",
  reason: "answeredElsewhere",
};
const accepted: Promise<boolean> = api.receiveCallEnded(ended);
void accepted;
const localEnd: CallEndedPayload = {
  eventId: "local-event",
  serverCallId: "server-call",
  // @ts-expect-error A local hangup uses endConversation, not a server signal.
  reason: "local",
};
void localEnd;
const answeredEvent: ConversationEventMap["answeredElsewhere"] = {
  conversationId: id,
  serverCallId: "server-call",
  eventId: "end-event",
};
void answeredEvent;
native.addListener("conversationEvent", (event) => {
  if (event.type === "answeredElsewhere") {
    const nativeID: ConversationId = event.payload.conversationId;
    const eventID: string = event.payload.eventId;
    const serverID: string = event.payload.serverCallId;
    void nativeID;
    void eventID;
    void serverID;
  }
});

declare const notificationEvent: CallNotificationEvent;
if (notificationEvent.type === "failed") {
  const error: "notAuthorized" | "intentRejected" | "postFailed" =
    notificationEvent.error;
  const caller: string = notificationEvent.caller.id;
  void error;
  void caller;
} else if (notificationEvent.type === "withdrawn") {
  // @ts-expect-error A withdrawn notification carries only its conversation.
  void notificationEvent.caller;
}
declare const route: CallNotificationRoute;
if (route.type === "callBack") {
  // A call back starts a new conversation with the caller.
  void api.startConversation({ id: "callback-id", to: route.caller, video: route.video });
  // @ts-expect-error A call back has no conversation to join.
  void route.conversationId;
} else {
  const joining: ConversationId = route.conversationId;
  void joining;
}
native.addListener("conversationEvent", (event) => {
  if (event.type === "callNotificationRoute") {
    const routed: CallNotificationRoute = event.payload;
    void routed;
  }
});

declare const previews: CallPreviewActivities;
if (previews.authorization.activitiesEnabled && previews.pushToStartToken) {
  const token: string = previews.pushToStartToken;
  void token;
}
for (const { conversationId, token } of previews.pushTokens) {
  const id: ConversationId = conversationId;
  const value: string = token;
  void id;
  void value;
}
// @ts-expect-error The servers' tokens are read-only.
previews.pushTokens.push({ conversationId: id, token: "00" });
declare const previewEvent: CallPreviewEvent;
if (previewEvent.type === "startFailed") {
  const error:
    | "activitiesDisabled"
    | "notInForeground"
    | "tooLarge"
    | "refused" = previewEvent.error;
  void error;
} else {
  // @ts-expect-error Only a failed start has an error.
  void previewEvent.error;
}
native.addListener(
  "callPreviewActivitiesChanged",
  ({ revision, activities }) => {
    const latest: number = revision;
    const current: CallPreviewActivities | null = activities;
    void latest;
    void current;
  }
);

declare const focus: FocusFilterState;
if (focus.state === "active") {
  const since: number = focus.since;
  const settings: JSONValue = focus.settings;
  void since;
  void settings;
} else if (focus.state === "inactive") {
  // @ts-expect-error An inactive filter asks for its defaults, so it carries no settings.
  void focus.settings;
} else {
  // @ts-expect-error An unknown state has no date.
  void focus.since;
}
native.addListener("focusFilterStateChanged", ({ revision, state }) => {
  const latest: number = revision;
  const current: FocusFilterState | null = state;
  void latest;
  void current;
});

if (conversation.media === "native") {
  // The app's native media joined the conversation; JavaScript leaves its media alone.
  const media: "native" = conversation.media;
  void media;
}

void api.startConversation({ id: "app-call-id", to: { id: "callee" }, video: false });
// @ts-expect-error The app must provide its call ID.
void api.startConversation({ to: { id: "callee" }, video: false });
// @ts-expect-error Native end actions are observed, never handled.
const nativeEndHandler: ConversationHandler = { start() {}, end() {} };
void nativeEndHandler;
// @ts-expect-error An iOS media adapter is webrtc or none.
const obsoleteMedia: import("../index").MediaAdapter = "livekit";
void obsoleteMedia;
// @ts-expect-error This native event does not exist.
type ObsoleteEvent = ConversationEventMap["providerOwnershipLost"];
// @ts-expect-error The module never emitted this event.
type ObsoleteAudioEvent = ConversationEventMap["audioActivationFailed"];
// @ts-expect-error The module never read this setting.
const obsoleteConfig: import("../index").ConversationConfiguration = { audioActivationTimeoutMs: 1000 };
void obsoleteConfig;
const joinFailure: ConversationEventMap["joinFailed"] = { conversationId: id, reason: { kind: "failed", failure: "notPlaced" } };
void joinFailure;

// @ts-expect-error The SDK does not update a call’s video capability after creation.
void api.reportConversation(id, { type: "updated", video: true });
