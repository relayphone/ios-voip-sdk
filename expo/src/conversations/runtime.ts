import type { NativeTransport, HandlerAction } from "./transport.ts";
import type { Conversation, ConversationHandler, ActionContext } from "./types.ts";

/** Native revisions order snapshots and delayed reads on one timeline. */
export class RevisionStore<Value> {
  private revision = -1;
  private failure: unknown;
  private readonly listeners = new Set<() => void>();
  private value: Value;
  constructor(value: Value) { this.value = value; }
  readonly peek = () => this.value;
  readonly read = () => {
    if (this.revision < 0 && this.failure) throw this.failure;
    return this.value;
  };
  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  accept(revision: number, value: Value) {
    if (!Number.isSafeInteger(revision) || revision < 0)
      throw new Error("Invalid native revision");
    if (revision <= this.revision) return;
    this.revision = revision;
    this.value = immutable(value);
    this.failure = undefined;
    this.listeners.forEach((listener) => listener());
  }
  fail(error: unknown) {
    this.failure = error;
    this.listeners.forEach((listener) => listener());
  }
}
function isObject<Value>(value: Value): value is Value & object {
  return value !== null && typeof value === "object";
}

const immutable: <Value>(value: Value) => Value = <Value>(value: Value) => {
  if (!isObject(value) || Object.isFrozen(value)) return value;
  if (Array.isArray(value)) {
    const entries: readonly unknown[] = value;
    // SAFETY: Copying a native snapshot array visits each element and preserves its typed data.
    return Object.freeze(entries.map(immutable)) as Value;
  }
  const entries: [string, unknown][] = Object.entries(value);
  // SAFETY: Native snapshots are JSON records. The copy keeps every field and recursively copies its value.
  return Object.freeze(Object.fromEntries(entries.map(([key, entry]) => [key, immutable(entry)]))) as Value;
};

/** Handler generations prevent a replaced or cancelled promise settling native work. */
export class HandlerDispatcher {
  private handler: ConversationHandler | null = null;
  private generation = 0;
  private readonly pending = new Map<string, AbortController>();
  private readonly bridge: Pick<NativeTransport, "setHandlerAttached" | "settleAction">;
  constructor(bridge: Pick<NativeTransport, "setHandlerAttached" | "settleAction">) { this.bridge = bridge; }
  set(handler: ConversationHandler | null) {
    const generation = ++this.generation;
    const pending = [...this.pending.values()];
    this.pending.clear();
    this.handler = handler;
    pending.forEach((controller) => controller.abort("handlerReplaced"));
    if (generation === this.generation)
      this.bridge.setHandlerAttached(handler !== null, generation);
  }
  cancel(actionID: string, generation: number, reason: string) {
    const key = `${generation}:${actionID}`;
    const controller = this.pending.get(key);
    this.pending.delete(key);
    controller?.abort(reason);
  }
  dispatch(action: HandlerAction) {
    if (
      !Number.isFinite(Date.parse(action.deadline)) ||
      Date.parse(action.deadline) <= Date.now()
    )
      return;
    const handler = this.handler;
    if (!handler || action.generation !== this.generation) return;
    const key = `${action.generation}:${action.actionID}`;
    if (this.pending.has(key)) return;
    const controller = new AbortController();
    this.pending.set(key, controller);
    const context: ActionContext = {
      deadline: action.deadline,
      signal: controller.signal,
      origin: action.origin,
    };
    const invoke = () => {
      switch (action.kind) {
        case "join":
          if (!handler.join) throw new Error("Join handler required");
          return handler.join(action.conversation, context);
        case "start":
          return handler.start(action.conversation, context);

      }
    };
    const settle = (success: boolean) => {
      if (this.pending.get(key) !== controller || controller.signal.aborted)
        return;
      this.pending.delete(key);
      this.bridge.settleAction(
        action.actionID,
        action.generation,
        success,
        success
          ? undefined
          : { name: "HandlerError", message: "Conversation handler failed" }
      );
    };
    Promise.resolve()
      .then(() => {
        if (!controller.signal.aborted) return invoke();
      })
      .then(
        () => settle(true),
        () => settle(false)
      );
  }
}

/** Preserve identity for unchanged conversations so individual hooks can skip renders. */
export function reconcile(
  previous: readonly Conversation[],
  next: readonly Conversation[]
) {
  const byId = new Map(
    previous.map((conversation) => [conversation.id, conversation])
  );
  const conversations: readonly Conversation[] = next.map((conversation) => {
    const prior = byId.get(conversation.id);
    return prior && JSON.stringify(prior) === JSON.stringify(conversation)
      ? prior
      : conversation;
  });
  return conversations;
}
