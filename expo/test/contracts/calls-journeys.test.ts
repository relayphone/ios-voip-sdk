import assert from "node:assert/strict";
import { test } from "node:test";

import type { Call, CallError, EndExpectation, EndReason, Lifecycle, Model, SystemFailure, WireID } from "../../../tools/conformance/model.ts";
import type { ExpectationV1, InputV1, ModelV1 } from "../../../tools/conformance/model-v1.ts";
import { loadCatalog } from "../../../tools/conformance/runner.ts";
import { wireID } from "../../../tools/conformance/schema.ts";
import { loadCatalogV1 } from "../../../tools/conformance/v1.ts";
import { createCallsStore } from "../../src/calls/store.ts";

type ExpectedCall = Extract<ExpectationV1, { kind: "call" }>;
type CallIdentity = Pick<Call, "id" | "direction" | "line" | "parties">;
type BridgePayload = { readonly kind: "record"; readonly record: Model | ModelV1;
  readonly correlation?: { readonly callID: WireID } }
  | { readonly kind: "callRemoved"; readonly callID: WireID }
  | { readonly kind: "terminalCompleted"; readonly callID: WireID }
  | Extract<ExpectationV1, { kind: "cleanup" }>;
type Frame = BridgePayload & { readonly cursor: { readonly epoch: string; readonly sequence: number } };

const timestamp = "2026-11-17T18:00:00.000Z";

function callIdentity(input: InputV1): CallIdentity | undefined {
  if (input.kind === "incoming") {
    return { id: input.callID, direction: "incoming", line: input.line, parties: [input.party] };
  }
  if (input.kind === "action" && input.action.kind === "start") {
    const { callID, line, party } = input.action;
    return { id: callID, direction: "outgoing", line, parties: [party] };
  }
  return undefined;
}

function claimTimedOut(callID: WireID): Extract<CallError, { kind: "claimTimedOut" }> {
  // The journey checks the error kind. The bridge still requires a correlated action.
  return { kind: "claimTimedOut", actionID: wireID(`answer-${callID}`) };
}

function completeEndReason(reason: EndExpectation, callID: WireID, systemFailure?: SystemFailure): EndReason {
  if (reason.kind !== "failed") return reason;
  switch (reason.error) {
    case "refused": return { kind: "failed", error: { kind: "refused", reason: { kind: "notAllowed" } } };
    case "claimTimedOut": return { kind: "failed", error: claimTimedOut(callID) };
    case "systemFailed":
      assert.ok(systemFailure, `Missing system failure input for ${callID}`);
      return { kind: "failed", error: { kind: "systemFailed", cause: systemFailure } };
    default: assert.fail(`Missing bridge fixture details for ${reason.error}`);
  }
}

function completeLifecycle({ lifecycle, callID }: ExpectedCall, systemFailure?: SystemFailure): Lifecycle {
  switch (lifecycle.kind) {
    case "ending": return { kind: "ending", reason: completeEndReason(lifecycle.reason, callID, systemFailure) };
    case "ended": return { kind: "ended", reason: completeEndReason(lifecycle.reason, callID, systemFailure), endedAt: timestamp };
    case "connected":
    case "reconnecting": return { kind: lifecycle.kind, connectedAt: timestamp };
    case "previewing": return lifecycle;
    default: return { kind: lifecycle.kind };
  }
}

function fakeNativeTransport(epoch: string) {
  const calls = new Map<WireID, Call>();
  const terminalOrder = new Set<WireID>();
  const completed = new Set<WireID>();
  const media = new Map<WireID, Extract<ModelV1, { kind: "mediaState" }>>();
  const capabilities = new Map<string, Extract<ModelV1, { kind: "capability" }>>();
  let cursor = { epoch, sequence: 0 };
  let pushHealth: Extract<ModelV1, { kind: "pushHealth" }>["value"] | undefined;
  let previous: Frame | undefined;
  let receive: ((frame: unknown) => void) | undefined;
  const snapshot = () => ({
    cursor,
    calls: [
      ...[...calls.values()].filter(call => !terminalOrder.has(call.id)),
      ...[...terminalOrder].map(id => calls.get(id)),
    ],
    completed: [...completed],
    records: [...media.values(), ...capabilities.values()],
    ...(pushHealth && { pushHealth }),
  });

  return {
    snapshot,
    attach(listener: (frame: unknown) => void) {
      assert.equal(receive, undefined, "store attaches to native once");
      receive = listener;
      return { snapshot: snapshot(), unsubscribe: () => { receive = undefined; } };
    },
    publish(payload: BridgePayload): Frame {
      if (payload.kind === "callRemoved") {
        calls.delete(payload.callID);
        terminalOrder.delete(payload.callID);
        completed.delete(payload.callID);
        media.delete(payload.callID);
        for (const [key, capability] of capabilities) {
          if (capability.value.callID === payload.callID) capabilities.delete(key);
        }
      } else if (payload.kind === "terminalCompleted") completed.add(payload.callID);
      else if (payload.kind === "cleanup") { /* System outcome is independent of adapter completion. */ }
      else if (payload.record.kind === "call") {
        const { value } = payload.record;
        calls.set(value.id, value);
        if (value.lifecycle.kind === "ending" || value.lifecycle.kind === "ended") terminalOrder.add(value.id);
      } else if (payload.record.kind === "pushHealth") pushHealth = payload.record.value;
      else if (payload.record.kind === "mediaState") media.set(payload.record.value.callID, payload.record);
      else if (payload.record.kind === "capability") {
        const { feature, callID } = payload.record.value;
        capabilities.set(JSON.stringify([feature, callID]), payload.record);
      }
      cursor = { epoch, sequence: cursor.sequence + 1 };
      const frame = { ...payload, cursor };
      assert.ok(receive, "the store has attached");
      receive(frame);
      if (previous) receive(previous);
      receive(frame);
      previous = frame;
      return frame;
    },
  };
}

function assertProjectedRecord(store: ReturnType<typeof createCallsStore>, record: ModelV1): void {
  const { calls, pushHealth } = store.snapshot();
  switch (record.kind) {
    case "pushHealth":
      assert.deepEqual(pushHealth, record.value);
      break;
    case "mediaState": {
      const { callID, ...media } = record.value;
      const call = calls.find(({ id }) => id.toString() === callID);
      assert.ok(call);
      assert.partialDeepStrictEqual(call.media, media);
      break;
    }
    case "capability": {
      const { callID, feature, availability } = record.value;
      if (callID === undefined) break;
      const call = calls.find(({ id }) => id.toString() === callID);
      assert.ok(call);
      assert.deepEqual(call.capabilities.find((item) => item.feature === feature)?.availability, availability);
      break;
    }
  }
}

// Native counters, participation and system end reports are assertions for platform drivers.
// Replay the bridge-visible observations from the same catalog through the JS store.
for (const journey of [...loadCatalog(), ...loadCatalogV1()]) {
  test(`call store replays ${journey.id}`, { timeout: 2000 }, async () => {
    const native = fakeNativeTransport(journey.id);
    const store = createCallsStore(native);
    const identities = new Map<WireID, CallIdentity>();
    const systemFailures = new Map<WireID, SystemFailure>();
    const wireCalls = new Map<WireID, Call>();
    const received: unknown[] = [];
    const unsubscribe = store.subscribe((observation) => received.push(observation));
    const stream = store.observe()[Symbol.asyncIterator]();

    async function send(payload: BridgePayload): Promise<void> {
      const previous = received.length;
      const published = native.publish(payload);
      assert.equal(received.length, previous + 1, "bridge retries must be idempotent");
      assert.deepEqual(received.at(-1), published);
      const next = await stream.next();
      assert.ok(!next.done);
      assert.deepEqual(next.value, published);
    }

    try {
      const initial = { kind: "snapshot", cursor: store.snapshot().cursor, snapshot: store.snapshot() };
      assert.deepEqual(received, [initial]);
      assert.deepEqual((await stream.next()).value, initial);
      for (const step of journey.steps) {
        if (step.kind === "input") {
          const identity = callIdentity(step.input);
          if (identity) identities.set(identity.id, identity);
          if (step.input.kind === "admissionFailed") {
            systemFailures.set(step.input.callID, step.input.failure);
          }
          continue;
        }
        const expected = step.expectation;
        switch (expected.kind) {
          case "call": {
            const identity = identities.get(expected.callID);
            assert.ok(identity, `Missing incoming or start input for ${expected.callID}`);
            const previous = wireCalls.get(expected.callID);
            const remoteID = expected.remoteID ?? previous?.remoteID;
            const lifecycle = completeLifecycle(expected, systemFailures.get(expected.callID));
            const value: Call = {
              ...identity,
              ...(remoteID && { remoteID }),
              lifecycle,
              held: expected.held ?? previous?.held ?? false,
              muted: expected.muted ?? previous?.muted ?? false,
              video: false,
              media: { owner: "native", preparation: "unprovided", audio: "inactive", transport: "disconnected" },
            };
            wireCalls.set(expected.callID, value);
            await send({ kind: "record", record: { version: 0, kind: "call", value } });
            const observed = store.snapshot().calls.find(({ id }) => id.toString() === expected.callID);
            assert.ok(observed, `Missing call ${expected.callID}`);
            assert.deepEqual(observed.lifecycle, lifecycle);
            assert.equal(observed.direction, identity.direction);
            assert.deepEqual(observed.parties, identity.parties);
            if (expected.lineID !== undefined) assert.equal(observed.line.id, expected.lineID);
            for (const key of ["remoteID", "held", "muted"] as const) {
              if (key in expected) assert.equal(observed[key], expected[key]);
            }
            for (const record of native.snapshot().records) assertProjectedRecord(store, record);
            break;
          }
          case "callAbsent":
            wireCalls.delete(expected.callID);
            await send({ kind: "callRemoved", callID: expected.callID });
            assert.ok(!store.snapshot().calls.some(({ id }) => id.toString() === expected.callID));
            break;
          case "cleanup":
            await send(expected);
            await send({ kind: "terminalCompleted", callID: expected.callID });
            break;
          case "record":
            await send({ kind: "record", record: expected.record });
            assertProjectedRecord(store, expected.record);
            break;
          case "endResult":
            await send({ kind: "record", correlation: { callID: expected.callID },
              record: { version: 0, kind: "endResult", value: expected.result } });
            break;
          case "actionError":
            await send({ kind: "record", correlation: { callID: expected.callID },
              record: { version: 0, kind: "error", value: expected.error } });
            break;
          case "error":
            if (expected.error === "refused" && expected.reason) {
              await send({ kind: "record", correlation: { callID: expected.callID },
                record: { version: 0, kind: "error", value: { kind: "refused", reason: expected.reason } } });
            } else if (expected.error === "claimTimedOut") {
              await send({ kind: "record", correlation: { callID: expected.callID },
                record: { version: 0, kind: "error", value: claimTimedOut(expected.callID) } });
            }
            break;
        }
      }
      const hydrated: unknown[] = [];
      const detach = store.subscribe((observation) => hydrated.push(observation));
      assert.deepEqual(hydrated, [{ kind: "snapshot", cursor: store.snapshot().cursor, snapshot: store.snapshot() }]);
      for (const record of native.snapshot().records) assertProjectedRecord(store, record);
      detach();
    } finally {
      unsubscribe();
      store.close();
    }
    assert.equal((await stream.next()).done, true);

    const reattached = createCallsStore(native);
    try {
      assert.deepEqual(reattached.snapshot().cursor, native.snapshot().cursor);
      assert.deepEqual(
        new Map<string, unknown>(reattached.snapshot().calls.map(({ id, lifecycle }) => [id, lifecycle])),
        new Map<string, unknown>([...wireCalls.values()].map(({ id, lifecycle }) => [id, lifecycle])),
      );
      assert.deepEqual(reattached.snapshot().pushHealth, native.snapshot().pushHealth);
      for (const record of native.snapshot().records) assertProjectedRecord(reattached, record);
    } finally {
      reattached.close();
    }
  });
}
