import { createCallsStore, type CallsSnapshot } from "../calls/store.ts";
import type { Call, CallError, EndReason } from "../calls/model.ts";
import { ended, incomingOutcome, performed } from "../calls/receipts.ts";
import type { NativeEvents, NativeTransport } from "./transport.ts";
import type {
  Conversation, ConversationEnd, ConversationErrorCode, ConversationId, IncomingCallPayload, IncomingConversationOutcome,
  MediaKind, Participant, Subscription,
} from "./types.ts";

type Handle = Call["parties"][number]["handle"];
type ErrorResult = { readonly ok: false; readonly error: CallError };
type Reply<Value> = { readonly ok: true; readonly value: Value } | ErrorResult;
type Permission = "granted" | "denied" | "restricted" | "notDetermined";
type DefaultLine = Pick<Call["line"], "id" | "label" | "accountID">;

export interface AndroidBridge {
  negotiate(offer: string): string;
  line(): string;
  attach(): string;
  detach(): void;
  snapshot(): string;
  command(request: string): Promise<string>;
  addListener(name: "bridgeFrame", receive: (event: { json: string }) => void): Subscription;
}

export function bindAndroid(native: AndroidBridge): NativeTransport {
  const negotiation = JSON.parse(native.negotiate(JSON.stringify({ kind: "negotiate", versions: [1] })));
  if (negotiation?.kind !== "negotiated" || negotiation.result?.ok !== true ||
      negotiation.result.value?.version !== 1) throw failure("conversation", "The calling bridge is unavailable");
  const line: DefaultLine | null = JSON.parse(native.line());
  function configuredLine() {
    if (!line) throw failure("invalid_arguments", "Configure an Android calling line");
    return line;
  }
  const listeners = new Set<(name: keyof NativeEvents, value: unknown) => void>();
  const emit = <Name extends keyof NativeEvents>(name: Name, value: NativeEvents[Name]) => {
    for (const deliver of listeners) deliver(name, value);
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

  async function command<Value>(operation: string, input?: unknown): Promise<Value> {
    const reply: { kind: string; operation: string; result: Reply<Value> } = JSON.parse(
      await native.command(JSON.stringify({ kind: "command", operation, input })),
    );
    if (reply.kind !== "reply" || reply.operation !== operation)
      throw failure("conversation", "Invalid calling bridge reply");
    if (!reply.result.ok) throw commandError(reply.result.error);
    return reply.result.value;
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
          conversationId: callID as string as ConversationId, origin, action: performed,
        } });
      }
    }
  });
  async function perform(id: ConversationId, kind: "answer" | "end") {
    const value: unknown = await command("perform", { id, action: { kind } });
    if (kind === "end") ended(value);
    else {
      const { action } = performed(value).receipt;
      if (action.kind !== "answer" || (action.callID as string) !== id)
        throw failure("conversation", "Invalid Answer receipt");
    }
  }
  const unsupported = (feature: string): never => { throw failure("unsupported", `${feature} is unavailable on Android`); };
  async function permission(kind: MediaKind, request: boolean) {
    const status = (await command<{ kind: Permission }>(`permissions.${request ? "request" : "read"}`, { kind })).kind;
    return {
      status: status === "notDetermined" ? "undetermined" : status === "restricted" ? "denied" : status,
      granted: status === "granted", canAskAgain: status !== "restricted", expires: "never",
    } as const;
  }
  const permissions = async () => ({ microphone: await permission("microphone", false), camera: await permission("camera", false) });
  const receive = (id: string, event: object, eventID = newID()) =>
    command<{ kind: string }>("receive", { target: { kind: "call", id }, eventID, ...event });
  return {
    get snapshot() { return current; },
    mediaAdapter: "none",
    addListener(name, listener) {
      const deliver = (event: keyof NativeEvents, value: unknown) => {
        if (event === name) listener(value as NativeEvents[typeof name]);
      };
      listeners.add(deliver);
      return { remove: () => { listeners.delete(deliver); } };
    },
    getConversations: async () => current,
    getAudioRoutes: async () => ({ revision: 0, routes: [], current: null }),
    getPushToken: async () => { await command("push.registration"); return { revision: 0, token: null }; },
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
      const outcome = incomingOutcome(await command("reportIncoming", {
        callID: payload.serverCallId, eventID: payload.eventId, line: configuredLine(), party: callerParty(payload.caller),
      }));
      const decision = outcome.kind === "duplicate" ? outcome.original : outcome;
      const id = decision.callID as string as ConversationId;
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
          conversationId: payload.serverCallId as ConversationId, serverCallId: payload.serverCallId, eventId: payload.eventId,
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
}

function failure(code: ConversationErrorCode, message: string) {
  return Object.assign(new Error(message), { code });
}
function commandError(error: CallError): Error & { code: ConversationErrorCode; nativeCode?: number } {
  switch (error.kind) {
    case "unknownCall": return failure("unknown_conversation", "Unknown conversation");
    case "unsupported": return failure("unsupported", `${error.feature} is unavailable on Android`);
    case "permissionRequired": return failure("not_foreground", "Open the app to request permission");
    case "deadlineExceeded": return failure("deadline_exceeded", "The call action expired");
    case "placementFailed": return failure("handler_failed", "Conversation handler failed");
    case "refused": return failure("refused", "The call action was refused");
    case "systemFailed": return Object.assign(failure("conversation", "Android Telecom could not complete the call action"),
      { ...(error.cause.code !== undefined && { nativeCode: error.cause.code }) });
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
function participant(handle: Handle): Partial<Participant> {
  return handle.kind === "phone" ? { phoneNumber: handle.e164 } : handle.kind === "email" ? { email: handle.address } : {};
}
function remoteReason(kind: string) {
  return kind === "failed" ? { kind, error: { kind: "serverFailed" } } : { kind };
}
function end(at: string, reason: EndReason): ConversationEnd {
  switch (reason.kind) {
    case "localDeclined": case "localEnded": return { at, reason: "local" };
    case "filtered": return { at, reason: "failed", failure: { kind: "filtered",
      cause: reason.cause === "unknown" ? "other" : reason.cause } };
    case "failed": return { at, reason: "failed", ...(reason.error.kind === "serverFailed" && { failure: { kind: "server" } }) };
    default: return { at, reason: reason.kind };
  }
}
function snapshot(state: CallsSnapshot, revision: number) {
  const conversations = state.calls.map((call): Conversation => {
    const base = {
      // The call ID decoder validated this opaque identifier for both public views.
      id: call.id as string as ConversationId,
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
