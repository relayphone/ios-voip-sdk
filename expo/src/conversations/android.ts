import { integer, literal, nonempty, object, timestamp, union, type Decoder } from "../calls/decode.ts";
import { createCallsStore } from "../calls/store.ts";
import { callID, eventID, type Call, type CallError, type CallingLine, type EndReason } from "../calls/model.ts";
import { bridgeError, ended, incomingOutcome, performed, type IncomingOutcome } from "../calls/receipts.ts";
import { actionID, line as callingLine, party as callingParty } from "../calls/wire-v0.ts";
import type { NativeEvents, NativeTransport } from "./transport.ts";
import type {
  Conversation, ConversationEnd, ConversationErrorCode, ConversationId, IncomingCallPayload, IncomingConversationOutcome,
  EndedReason, JSONValue, MediaKind, Participant, Subscription,
} from "./types.ts";

type Handle = Call["parties"][number]["handle"];
type EventValue = NativeEvents[keyof NativeEvents];
type RemoteEventInput =
  | { kind: "connecting" | "connected" }
  | { kind: "ended"; reason: ReturnType<typeof remoteReason> }
  | { kind: "partiesChanged"; parties: readonly ReturnType<typeof party>[] };
type CommandInput =
  | { id: ConversationId; action: { kind: "answer" | "end" } | { kind: "hold"; held: boolean } }
  | { id: ConversationId; lineID: string; parties: readonly ReturnType<typeof party>[]; video: boolean }
  | { attached: boolean; generation: number }
  | { actionID: string; generation: number; result: PlacementSettlement }
  | { kind: MediaKind }
  | (RemoteEventInput & { target: { kind: "call"; id: string }; eventID: string })
  | { callID: string; eventID: string; line: CallingLine; party: ReturnType<typeof callerParty> };
type PlacementSettlement =
  | { ok: true; value: { kind: "placed" } }
  | { ok: false; error: { kind: "placementFailed"; cause: "handlerFailed" } };

const negotiated = object({
  kind: literal("negotiated"),
  result: object({ ok: literal(true), value: object({ version: literal(1) }) }),
});
const permissionStatus = object({ kind: literal("granted", "denied", "restricted", "notDetermined") });
const received = object({ kind: literal("applied", "buffered", "duplicate") });
const refused = object({ ok: literal(false), error: bridgeError });
const settled = object({ kind: literal("accepted", "stale") });
const voidReply: Decoder<null> = value => {
  if (value !== null) throw new TypeError("Invalid placement attachment reply");
  return null;
};
const placementIdentity = { generation: integer(1), actionID };
const placementFrame = union(
  object({
    kind: literal("placementRequested"), ...placementIdentity, deadline: timestamp, remainingMs: integer(1),
    request: object({
      kind: literal("start"), origin: literal("app", "system"), callID, line: callingLine, parties: nonempty(callingParty),
    }),
  }),
  object({
    kind: literal("placementCancelled"), ...placementIdentity,
    reason: literal("replaced", "detached", "ended", "deadlineExceeded", "reset"),
  }),
);
const capabilities = { hold: true, merge: false, tones: false, video: false };

export interface AndroidBridgeEvents {
  bridgeFrame: { json: string };
  placementFrame: { json: string };
  incomingPush: { json: string };
  pushTokenUpdated: NativeEvents["pushTokenUpdated"];
}

export interface AndroidBridge {
  negotiate(offer: string): string;
  line(): string;
  attach(): string;
  detach(): void;
  snapshot(): string;
  command(request: string): Promise<string>;
  getPushToken(): Promise<NativeEvents["pushTokenUpdated"]>;
  addListener<Name extends keyof AndroidBridgeEvents>(name: Name, receive: (event: AndroidBridgeEvents[Name]) => void): Subscription;
}

export function bindAndroid(native: AndroidBridge) {
  try {
    negotiated(JSON.parse(native.negotiate(JSON.stringify({ kind: "negotiate", versions: [1] }))));
  } catch {
    throw failure("conversation", "The calling bridge is unavailable");
  }
  const lineValue: JSONValue = JSON.parse(native.line());
  const line = lineValue === null ? null : callingLine(lineValue);
  function configuredLine() {
    if (!line) throw failure("invalid_arguments", "Configure an Android calling line");
    return line;
  }
  const listeners = new Map<keyof NativeEvents, Set<(value: EventValue) => void>>();
  const emit = <Name extends keyof NativeEvents>(name: Name, value: NativeEvents[Name]) => {
    listeners.get(name)?.forEach(deliver => deliver(value));
  };
  const store = createCallsStore({
    attach(receive) {
      const subscription = native.addListener("bridgeFrame", ({ json }) => receive(JSON.parse(json)));
      try {
        const snapshot: unknown = JSON.parse(native.attach());
        let attached = true;
        return { snapshot, unsubscribe() {
          if (!attached) return;
          attached = false;
          subscription.remove();
          native.detach();
        } };
      } catch (error) {
        subscription.remove();
        throw error;
      }
    },
    snapshot: () => JSON.parse(native.snapshot()),
  });

  async function command<Value>(operation: string, decode: Decoder<Value>, input?: CommandInput) {
    const reply = object({
      kind: literal("reply"),
      operation: literal(operation),
      result: union(object({ ok: literal(true), value: raw => ({ decoded: decode(raw) }) }), refused),
    })(JSON.parse(await native.command(JSON.stringify({ kind: "command", operation, input }))));
    const outgoingControl = operation === "start" || input !== undefined && "action" in input && input.action.kind === "hold";
    if (!reply.result.ok) throw commandError(reply.result.error, outgoingControl);
    return reply.result.value.decoded;
  }

  let revision = 0;
  const visibleCalls = () => store.snapshot().calls.filter(call => call.lifecycle.kind !== "reporting");
  let latest = visibleCalls();
  let current = snapshot(latest, revision);
  store.subscribe(observation => {
    const next = visibleCalls();
    if (next.length !== latest.length || next.some((call, index) => call !== latest[index])) {
      latest = next;
      current = snapshot(next, ++revision);
      emit("conversationsChanged", current);
    }
    if (observation.kind === "actionPerformed") {
      const { origin, action } = observation.receipt;
      const { callID, ...details } = action;
      const performed = details.kind === "start" ? { kind: "start" } as const : details;
      if (performed.kind === "start" || performed.kind === "answer" || performed.kind === "end" || performed.kind === "hold")
        emit("conversationEvent", { type: "actionPerformed", payload: { conversationId: conversationID(callID), origin, action: performed } });
    }
  });
  let generation = 0;
  let registration = Promise.resolve<Error | null>(null);
  const delivered = new Map<string, number>();
  native.addListener("placementFrame", ({ json }) => {
    const frame = placementFrame(JSON.parse(json));
    if (frame.generation !== generation) return;
    const { actionID } = frame;
    if (frame.kind === "placementCancelled") {
      emit("actionCancelled", { actionID, generation, reason: frame.reason });
      return;
    }
    const now = Date.now();
    const deadline = Math.min(Date.parse(frame.deadline), now + frame.remainingMs);
    for (const [id, expiry] of delivered) {
      if (expiry <= now) delivered.delete(id);
    }
    if (deadline <= now || delivered.has(actionID)) return;
    delivered.set(actionID, deadline);
    const { origin, kind, callID, parties } = frame.request;
    emit("handlerAction", {
      actionID, generation, origin, kind, deadline: new Date(deadline).toISOString(),
      conversation: {
        id: conversationID(callID), direction: "outgoing", status: "dialing", members: members(parties),
        isVideo: false, isMuted: false, capabilities,
      },
    });
  });
  async function perform(id: ConversationId, kind: "answer" | "end") {
    const request = { id, action: { kind } };
    if (kind === "end") {
      await command("perform", ended, request);
      return;
    }
    const { action } = (await command("perform", performed, request)).receipt;
    if (action.kind !== "answer" || action.callID !== callID(id))
      throw failure("conversation", "Invalid Answer receipt");
  }
  const unsupported = (feature: string) => { throw failure("unsupported", `${feature} is unavailable on Android`); };
  async function permission(kind: MediaKind, request: boolean) {
    const status = (await command(`permissions.${request ? "request" : "read"}`, permissionStatus, { kind })).kind;
    return {
      status: status === "notDetermined" ? "undetermined" : status === "restricted" ? "denied" : status,
      granted: status === "granted", canAskAgain: status !== "restricted", expires: "never",
    } as const;
  }
  const permissions = async () => ({ microphone: await permission("microphone", false), camera: await permission("camera", false) });
  const receive = (id: string, event: RemoteEventInput, eventID = newID()) =>
    command("receive", received, { target: { kind: "call", id }, eventID, ...event });
  function presentOutcome(eventId: string, serverCallId: string, outcome: IncomingOutcome) {
    const decision = outcome.kind === "duplicate" ? outcome.original : outcome;
    const id = conversationID(decision.callID);
    let projected: IncomingConversationOutcome;
    switch (decision.kind) {
      case "admitted": projected = { status: "reported", id }; break;
      case "capacity": projected = { status: "atCapacity" }; break;
      case "filtered": projected = { status: "filtered", reason: decision.cause === "unknown" ? "other" : decision.cause }; break;
      case "previewed": projected = { status: "previewed", id, reason: decision.reason.kind === "filtered"
        ? { type: "filtered", cause: decision.reason.cause === "unknown" ? "other" : decision.reason.cause }
        : { type: decision.reason.kind } }; break;
      case "refused": {
        const { code, message, nativeCode } = commandError(decision.error);
        projected = { status: "failed", error: { code, message, ...(nativeCode !== undefined && { nativeCode }) } };
        break;
      }
      default: projected = { status: "notShown" };
    }
    emit("conversationEvent", { type: "incomingConversationOutcome", payload: {
      eventId, serverCallId, outcome: projected,
    } });
    return projected;
  }
  const pushOutcome = object({ eventId: eventID, serverCallId: callID, outcome: incomingOutcome });
  native.addListener("incomingPush", ({ json }) => {
    const { eventId, serverCallId, outcome } = pushOutcome(JSON.parse(json));
    presentOutcome(eventId, serverCallId, outcome);
  });
  native.addListener("pushTokenUpdated", value => emit("pushTokenUpdated", value));
  const transport: NativeTransport = {
    get snapshot() { return current; },
    mediaAdapter: "none",
    addListener(name, listener) {
      const subscribers = listeners.get(name) ?? new Set();
      listeners.set(name, subscribers);
      const subscription = (event: EventValue) => {
        // SAFETY: emit only routes the typed value for this event name to these subscribers.
        listener(event as NativeEvents[typeof name]);
      };
      subscribers.add(subscription);
      return { remove: () => { subscribers.delete(subscription); } };
    },
    getConversations: async () => current,
    getAudioRoutes: async () => ({ revision: 0, routes: [], current: null }),
    getPushToken: () => native.getPushToken(),
    setHandlerAttached(attached, nextGeneration) {
      generation = nextGeneration;
      delivered.clear();
      registration = command("placement.attach", voidReply, { attached, generation })
        .catch(() => failure("conversation", "Could not register the call placement handler"));
    },
    settleAction(actionID, generation, success) {
      const result: PlacementSettlement = success
        ? { ok: true, value: { kind: "placed" } }
        : { ok: false, error: { kind: "placementFailed", cause: "handlerFailed" } };
      void command("placement.settle", settled, { actionID, generation, result }).catch(() => {});
    },
    async startConversation(options) {
      if (options.video) return unsupported("Video");
      const lineID = configuredLine().id;
      const to = party(options.to);
      let id: ConversationId;
      try {
        id = conversationID(options.id);
        callingParty(to);
      } catch {
        throw failure("invalid_arguments", "Invalid outgoing call arguments");
      }
      const error = await registration;
      if (error) throw error;
      const { action } = (await command("start", performed, { id, lineID, parties: [to], video: false })).receipt;
      if (action.kind !== "start" || action.callID !== callID(id)) throw failure("conversation", "Invalid Start receipt");
      return id;
    },
    joinConversation: id => perform(id, "answer"),
    endConversation: id => perform(id, "end"),
    async setHeld(id, held) {
      const status = current.conversations.find(call => call.id === id)?.status;
      if (held && status === "held" || !held && (status === "connected" || status === "reconnecting")) return;
      const { action } = (await command("perform", performed, { id, action: { kind: "hold", held } })).receipt;
      if (action.kind !== "hold" || action.callID !== callID(id) || action.held !== held)
        throw failure("conversation", "Invalid Hold receipt");
    },
    setMuted: async () => unsupported("Mute"),
    setConversationVideo: async () => unsupported("Video"),
    playTones: async () => unsupported("Tones"),
    mergeConversations: async () => unsupported("Call merge"),
    selectAudioRoute: async () => unsupported("Audio route selection"),
    async reportIncomingConversation(payload) {
      if (payload.hasVideo) return unsupported("Video");
      if (payload.media) return unsupported("Native media pre-warm");
      const outcome = await command("reportIncoming", incomingOutcome, {
        callID: payload.serverCallId, eventID: payload.eventId, line: configuredLine(), party: callerParty(payload.caller),
      });
      return presentOutcome(payload.eventId, payload.serverCallId, outcome);
    },
    async reportConversation(id, report) {
      switch (report.type) {
        case "connecting": case "connected":
          await receive(id, { kind: report.type });
          break;
        case "ended":
          if (report.reason === "local") await perform(id, "end");
          else await receive(id, { kind: "ended", reason: remoteReason(report.reason) });
          break;
        case "updated":
          if (report.video !== undefined) return unsupported("Video");
          if (report.members) await receive(id, { kind: "partiesChanged", parties: report.members.map(party) });
          break;
      }
    },
    async receiveCallEnded(payload) {
      const result = await receive(payload.serverCallId, { kind: "ended", reason: remoteReason(payload.reason) }, payload.eventId);
      if (result.kind === "applied" && payload.reason === "answeredElsewhere") {
        emit("conversationEvent", { type: "answeredElsewhere", payload: {
          conversationId: conversationID(payload.serverCallId), serverCallId: payload.serverCallId, eventId: payload.eventId,
        } });
      }
      return result.kind === "applied";
    },
    getMediaPermissions: permissions,
    async requestMediaPermissions(kinds) {
      for (const kind of kinds) await permission(kind, true);
      return permissions();
    },
    async conversationMediaReadiness(id) {
      if (!current.conversations.some(call => call.id === id)) throw failure("unknown_conversation", "Unknown conversation");
      return { required: ["microphone"], missing: (await permission("microphone", false)).granted ? [] : ["microphone"] };
    },
  };
  return transport;
}

function conversationID(value: string) {
  // SAFETY: Both public ID types carry the same canonical call identifier after validation.
  return callID(value) as ReturnType<typeof callID> & ConversationId;
}

function failure(code: ConversationErrorCode, message: string, nativeCode?: number) {
  const error: Error & { code: ConversationErrorCode; nativeCode?: number } = Object.assign(new Error(message), { code });
  if (nativeCode !== undefined) error.nativeCode = nativeCode;
  return error;
}
function commandError(error: CallError, outgoingControl = false) {
  switch (error.kind) {
    case "unknownCall": return failure("unknown_conversation", "Unknown conversation");
    case "unsupported": return failure("unsupported", `${error.feature} is unavailable on Android`);
    case "permissionRequired": return failure("not_foreground", "Open the app to request permission");
    case "deadlineExceeded": return failure("deadline_exceeded", "The call action expired");
    case "placementFailed": return failure("handler_failed", "Conversation handler failed");
    case "invalidConfiguration": return failure("invalid_arguments", "Invalid call configuration");
    case "invalidTransition": return outgoingControl
      ? failure("invalid_arguments", "The conversation's status doesn't allow this action")
      : failure("conversation", "The call action failed");
    case "refused": return outgoingControl && error.reason.kind === "notAllowed"
      ? failure("invalid_arguments", "The participation limit doesn't allow this action")
      : failure("refused", "The call action was refused");
    case "systemFailed": return failure("conversation", "Android Telecom could not complete the call action", error.cause.code);
    default: return failure("conversation", "The call action failed");
  }
}
function newID() { return `expo-${Date.now()}-${Math.random().toString(36).slice(2)}`; }
function party(member: Participant) {
  const handle = member.phoneNumber ? { kind: "phone", e164: phone(member.phoneNumber) }
    : member.email ? { kind: "email", address: member.email } : { kind: "opaque", value: member.id };
  return { id: member.id, handle, displayName: member.displayName ?? member.id };
}
function phone(value: string) { return value.replace(/[ ().-]/gu, ""); }
function callerParty(caller: IncomingCallPayload["caller"]) {
  const value = caller.handleType === "phone" ? phone(caller.value) : caller.value;
  return { id: caller.hostContactID ?? value, displayName: caller.displayName, handle:
    caller.handleType === "phone" ? { kind: "phone", e164: value }
      : caller.handleType === "email" ? { kind: "email", address: caller.value } : { kind: "opaque", value: caller.value } };
}
function participant(handle: Handle) {
  const member: Partial<Participant> = handle.kind === "phone" ? { phoneNumber: handle.e164 }
    : handle.kind === "email" ? { email: handle.address } : {};
  return member;
}
function members(parties: Call["parties"]) {
  return parties.map(({ id, handle, displayName }) => ({ ...participant(handle), id, displayName }));
}
function remoteReason(kind: Exclude<EndedReason, "local">) {
  return kind === "failed" ? { kind, error: { kind: "serverFailed" } } : { kind };
}
function end(at: string, reason: EndReason) {
  switch (reason.kind) {
    case "localDeclined": case "localEnded": return { at, reason: "local" } satisfies ConversationEnd;
    case "filtered": return { at, reason: "failed", failure: { kind: "filtered",
      cause: reason.cause === "unknown" ? "other" : reason.cause } } satisfies ConversationEnd;
    case "failed": {
      const error = reason.error;
      if (error.kind === "placementFailed" || error.kind === "deadlineExceeded" && error.stage === "placement")
        return { at, reason: "failed", failure: { kind: "notPlaced" } } satisfies ConversationEnd;
      if (error.kind === "systemFailed" && error.cause.kind === "start")
        return { at, reason: "failed", failure: { kind: "refused" } } satisfies ConversationEnd;
      return { at, reason: "failed", ...(error.kind === "serverFailed" && { failure: { kind: "server" } }) } satisfies ConversationEnd;
    }
    default: return { at, reason: reason.kind } satisfies ConversationEnd;
  }
}
function snapshot(calls: readonly Call[], revision: number) {
  const conversations = calls.map<Conversation>(call => {
    const base = {
      id: conversationID(call.id),
      members: members(call.parties),
      capabilities,
      isVideo: call.video.confirmed === "video", isMuted: call.muted, direction: call.direction,
      ...(call.media.owner === "native" && call.media.stage === "prepared" && { media: "native" as const }),
    };
    const lifecycle = call.lifecycle;
    if (call.held && lifecycle.kind !== "ending" && lifecycle.kind !== "ended") {
      if ("connectedAt" in lifecycle) return { ...base, status: "held", connectedAt: lifecycle.connectedAt };
      return { ...base, status: "held" };
    }
    switch (lifecycle.kind) {
      case "ringing": return { ...base, direction: "incoming", status: "ringing" };
      case "placing": case "dialing": return { ...base, direction: "outgoing", status: "dialing" };
      case "connected": case "reconnecting": return { ...base, status: lifecycle.kind, connectedAt: lifecycle.connectedAt };
      case "ended": return { ...base, status: "ended", ended: end(lifecycle.endedAt, lifecycle.reason) };
      case "ending": return { ...base, status: "ending" };
      default: return { ...base, status: "connecting" };
    }
  });
  return { revision, conversations };
}
