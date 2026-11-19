import { literal, object, union, type Decoder } from "../calls/decode.ts";
import { createCallsStore, type CallsSnapshot } from "../calls/store.ts";
import { callID, type Call, type CallError, type CallingLine, type EndReason } from "../calls/model.ts";
import { bridgeError, ended, incomingOutcome, performed } from "../calls/receipts.ts";
import { line as callingLine } from "../calls/wire-v0.ts";
import type { NativeEvents, NativeTransport } from "./transport.ts";
import type {
  Conversation, ConversationEnd, ConversationErrorCode, ConversationId, IncomingCallPayload, IncomingConversationOutcome,
  EndedReason, JSONValue, MediaKind, Participant, Subscription,
} from "./types.ts";

type Handle = Call["parties"][number]["handle"];
type EventValue = NativeEvents[keyof NativeEvents];
type RemoteEventInput =
  | { kind: "ended"; reason: ReturnType<typeof remoteReason> }
  | { kind: "partiesChanged"; parties: readonly ReturnType<typeof party>[] };
type CommandInput =
  | { id: ConversationId; action: { kind: "answer" | "end" } }
  | { kind: MediaKind }
  | (RemoteEventInput & { target: { kind: "call"; id: string }; eventID: string })
  | { callID: string; eventID: string; line: CallingLine; party: ReturnType<typeof callerParty> };

const negotiated = object({
  kind: literal("negotiated"),
  result: object({ ok: literal(true), value: object({ version: literal(1) }) }),
});
const permissionStatus = object({ kind: literal("granted", "denied", "restricted", "notDetermined") });
const received = object({ kind: literal("applied", "buffered", "duplicate") });
const unknownRegistration = object({ kind: literal("unknown") });
const refused = object({ ok: literal(false), error: bridgeError });

export interface AndroidBridge {
  negotiate(offer: string): string;
  line(): string;
  attach(): string;
  detach(): void;
  snapshot(): string;
  command(request: string): Promise<string>;
  addListener(name: "bridgeFrame", receive: (event: { json: string }) => void): Subscription;
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
    if (!reply.result.ok) throw commandError(reply.result.error);
    return reply.result.value.decoded;
  }

  let revision = 0;
  let latest = store.snapshot();
  let current = snapshot(latest, revision);
  store.subscribe(observation => {
    const next = store.snapshot();
    if (next.calls !== latest.calls) {
      latest = next;
      current = snapshot(next, ++revision);
      emit("conversationsChanged", current);
    }
    if (observation.kind === "actionPerformed") {
      const { origin, action } = observation.receipt;
      if (action.kind === "answer" || action.kind === "end" || action.kind === "hold") {
        const { callID, ...performed } = action;
        emit("conversationEvent", { type: "actionPerformed", payload: {
          conversationId: conversationID(callID), origin, action: performed,
        } });
      }
    }
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
    getPushToken: async () => { await command("push.registration", unknownRegistration); return { revision: 0, token: null }; },
    setHandlerAttached(attached) { if (attached) unsupported("Call placement"); },
    settleAction() { unsupported("Call placement"); },
    startConversation: async () => unsupported("Outgoing calls"),
    joinConversation: id => perform(id, "answer"),
    endConversation: id => perform(id, "end"),
    setHeld: async () => unsupported("Hold"),
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
        eventId: payload.eventId, serverCallId: payload.serverCallId, outcome: projected,
      } });
      return projected;
    },
    async reportConversation(id, report) {
      switch (report.type) {
        case "connected": return unsupported("Connected reports");
        case "ended":
          if (report.reason === "local") await perform(id, "end");
          else await receive(id, { kind: "ended", reason: remoteReason(report.reason) });
          break;
        case "updated":
          if (report.video !== undefined) return unsupported("Video");
          if (report.members) await receive(id, { kind: "partiesChanged", parties: report.members.map(party) });
          break;
        case "connecting": return unsupported("Explicit connecting reports");
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
function commandError(error: CallError) {
  switch (error.kind) {
    case "unknownCall": return failure("unknown_conversation", "Unknown conversation");
    case "unsupported": return failure("unsupported", `${error.feature} is unavailable on Android`);
    case "permissionRequired": return failure("not_foreground", "Open the app to request permission");
    case "deadlineExceeded": return failure("deadline_exceeded", "The call action expired");
    case "placementFailed": return failure("handler_failed", "Conversation handler failed");
    case "refused": return failure("refused", "The call action was refused");
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
function remoteReason(kind: Exclude<EndedReason, "local">) {
  return kind === "failed" ? { kind, error: { kind: "serverFailed" } } : { kind };
}
function end(at: string, reason: EndReason) {
  switch (reason.kind) {
    case "localDeclined": case "localEnded": return { at, reason: "local" } satisfies ConversationEnd;
    case "filtered": return { at, reason: "failed", failure: { kind: "filtered",
      cause: reason.cause === "unknown" ? "other" : reason.cause } } satisfies ConversationEnd;
    case "failed": return { at, reason: "failed", ...(reason.error.kind === "serverFailed" && { failure: { kind: "server" } }) } satisfies ConversationEnd;
    default: return { at, reason: reason.kind } satisfies ConversationEnd;
  }
}
function snapshot(state: CallsSnapshot, revision: number) {
  const conversations = state.calls.map<Conversation>(call => {
    const base = {
      id: conversationID(call.id),
      members: call.parties.map(({ id, handle, displayName }) => ({ ...participant(handle), id, displayName })),
      capabilities: { hold: false, merge: false, tones: false, video: false },
      isVideo: call.video.confirmed === "video", isMuted: call.muted, direction: call.direction,
      ...(call.media.owner === "native" && call.media.stage === "prepared" && { media: "native" as const }),
    };
    const lifecycle = call.lifecycle;
    if (call.held && lifecycle.kind !== "ending" && lifecycle.kind !== "ended") return { ...base, status: "held" };
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
