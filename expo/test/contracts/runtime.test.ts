import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { RevisionStore } from "../../src/conversations/runtime.ts";

describe("native snapshot ordering", () => {
  test("stale hydration cannot replace a newer event or mutate the cache", () => {
    const store = new RevisionStore<readonly { id: string }[]>([]);
    store.accept(2, [{ id: "new" }]);
    const value = store.read();
    store.accept(1, [{ id: "old" }]);
    assert.strictEqual(store.read(), value);
    assert.strictEqual(Object.isFrozen(store.read()[0]), true);
    assert.throws(() => store.accept(-1, []));
  });
  test("valid state recovers failed hydration", () => {
    const store = new RevisionStore<readonly string[]>([]);
    store.fail(new Error("read failed"));
    assert.throws(() => store.read());
    store.accept(0, []);
    assert.deepStrictEqual(store.read(), []);
  });
  test("unchanged frozen values retain their identity across revisions", () => {
    const store = new RevisionStore<readonly { id: string }[]>([]);
    store.accept(1, [{ id: "stable" }]);
    const first = store.read()[0];
    store.accept(2, [first!]);
    assert.strictEqual(store.read()[0], first);
  });
});

import { HandlerDispatcher } from "../../src/conversations/runtime.ts";
import type {
  HandlerAction,
  NativeTransport,
} from "../../src/conversations/transport.ts";
import type {
  ConversationHandler,
  ConversationId,
} from "../../src/conversations/types.ts";

function harness() {
  const attachments: [boolean, number][] = [];
  const settlements: [string, number, boolean][] = [];
  const bridge: Pick<NativeTransport, "setHandlerAttached" | "settleAction"> = {
    setHandlerAttached(attached, generation) {
      attachments.push([attached, generation]);
    },
    settleAction(id, generation, success) {
      settlements.push([id, generation, success]);
    },
  };
  return {
    dispatcher: new HandlerDispatcher(bridge),
    attachments,
    settlements,
  };
}
function action(generation = 1): HandlerAction {
  return {
    actionID: "action",
    generation,
    kind: "join",
    origin: "system",
    deadline: new Date(Date.now() + 30_000).toISOString(),
    conversation: {
      // Literal represents a native UUID at the bridge fixture boundary.
      id: "e9799cf2-daba-51df-8bdf-d59b88db0bca" as ConversationId,
      direction: "incoming",
      status: "ringing",
      members: [],
      isMuted: false,
      isVideo: false,
      capabilities: { hold: true, merge: false, tones: true, video: true },
    },
  };
}
const signaling: ConversationHandler = { start() {}, join() {} };
const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

describe("handler generation and cancellation", () => {
  test("resolves once; duplicate delivery cannot repeat application work", async () => {
    const h = harness();
    let joined = 0;
    h.dispatcher.set({
      ...signaling,
      join() {
        joined++;
      },
    });
    h.dispatcher.dispatch(action());
    h.dispatcher.dispatch(action());
    await flush();
    assert.strictEqual(joined, 1);
    assert.deepStrictEqual(h.settlements, [["action", 1, true]]);
  });
  test("cancellation before invocation skips application work", async () => {
    const h = harness();
    let joined = false;
    h.dispatcher.set({
      ...signaling,
      join() {
        joined = true;
      },
    });
    h.dispatcher.dispatch(action());
    h.dispatcher.cancel("action", 1, "deadline");
    await flush();
    assert.strictEqual(joined, false);
    assert.deepStrictEqual(h.settlements, []);
  });
  test("joinFailed aborts pending work and ignores its late resolution", async () => {
    const h = harness();
    let finish: (() => void) | undefined;
    let signal: AbortSignal | undefined;
    h.dispatcher.set({
      ...signaling,
      join(_, context) {
        signal = context.signal;
        return new Promise<void>((resolve) => {
          finish = resolve;
        });
      },
    });
    h.dispatcher.dispatch(action());
    await flush();
    h.dispatcher.cancel("action", 1, "joinFailed");
    h.dispatcher.cancel("action", 1, "cancelled");
    assert.strictEqual(signal?.aborted, true);
    assert.strictEqual(signal?.reason, "joinFailed");
    finish?.();
    await flush();
    assert.deepStrictEqual(h.settlements, []);
  });
  test("replacement aborts old work and ignores its late resolution", async () => {
    const h = harness();
    let finish: (() => void) | undefined;
    let signal: AbortSignal | undefined;
    h.dispatcher.set({
      ...signaling,
      join(_, context) {
        signal = context.signal;
        return new Promise<void>((resolve) => {
          finish = resolve;
        });
      },
    });
    h.dispatcher.dispatch(action());
    await flush();
    h.dispatcher.set(signaling);
    assert.strictEqual(signal?.aborted, true);
    finish?.();
    h.dispatcher.dispatch(action(2));
    await flush();
    assert.deepStrictEqual(h.settlements, [["action", 2, true]]);
  });
  test("a reentrant abort listener owns the final replacement", async () => {
    const h = harness();
    h.dispatcher.set({
      ...signaling,
      join(_, { signal }) {
        signal.addEventListener("abort", () => h.dispatcher.set(signaling));
        return new Promise<void>(() => {});
      },
    });
    h.dispatcher.dispatch(action());
    await flush();
    h.dispatcher.set(null);
    assert.deepStrictEqual(h.attachments, [
      [true, 1],
      [true, 3],
    ]);
  });
  test("missing required join fails; expired work never invokes it", async () => {
    const h = harness();
    h.dispatcher.set({ start() {} });
    h.dispatcher.dispatch(action());
    await flush();
    assert.deepStrictEqual(h.settlements, [["action", 1, false]]);
    h.dispatcher.dispatch({
      ...action(),
      actionID: "expired",
      deadline: new Date(0).toISOString(),
    });
    await flush();
    assert.strictEqual(h.settlements.length, 1);
  });
});

import { commandError, withCommandErrors } from '../../src/conversations/errors.ts';

test('native command errors preserve typed code and platform details', () => {
  const error = commandError(new Error('Native call rejected: expo-conversation:{"code":"conversation","message":"Control failed","nativeDomain":"LCKErrorDomain","nativeCode":4}'));
  assert.ok(error instanceof Error);
  assert.equal(error.message, 'Control failed');
  assert.partialDeepStrictEqual({ ...error }, { code: 'conversation', nativeDomain: 'LCKErrorDomain', nativeCode: 4 });
  const unrelated = new Error('Other library');
  assert.strictEqual(commandError(unrelated), unrelated);
  const malformed = new Error('expo-conversation:{"code":"made_up","message":"bad"}');
  assert.strictEqual(commandError(malformed), malformed);
});

describe("a join that its handler doesn't place", () => {
  test("a rejected join handler settles the join as failed", async () => {
    const h = harness();
    h.dispatcher.set({
      ...signaling,
      join() {
        throw new Error("The room refused the join");
      },
    });
    h.dispatcher.dispatch(action());
    await flush();
    assert.deepStrictEqual(h.settlements, [["action", 1, false]]);
  });
  test("joinConversation rejects with the typed handler_failed failure", async () => {
    const native = {
      async joinConversation(): Promise<void> {
        throw new Error(
          'expo-conversation:{"code":"handler_failed","message":"The join handler failed"}'
        );
      },
    };
    const api = withCommandErrors(native);
    const rejection = api.joinConversation().then(
      () => undefined,
      (error: unknown) => error
    );
    const error = await rejection;
    assert.ok(error instanceof Error);
    assert.equal(error.message, "The join handler failed");
    assert.partialDeepStrictEqual({ ...error }, { code: "handler_failed" });
  });
});
