import { array, id, integer, literal, object, optional, union, type Decoded } from './decode.ts';
import { actionID, attemptID, callID, decodeWireRecord, eventID, projectCall,
  type Call, type CallID, type Feature, type PushHealth, type WireRecord } from './model.ts';
import { wireCall } from './wire-v0.ts';
import { pushHealth, type Capability } from './wire-v1.ts';

const cursor = object({ epoch: id<'epoch'>(), sequence: integer() });
export type Cursor = Decoded<typeof cursor>;
const nativeSnapshot = object({
  cursor, calls: array(wireCall), completed: optional(array(callID)),
  pushHealth: optional(pushHealth), records: optional(array(decodeWireRecord)),
});
const correlation = object({ callID: optional(callID), actionID: optional(actionID),
  eventID: optional(eventID), attemptID: optional(attemptID) });
const frame = union(
  object({ cursor, kind: literal('record'), record: decodeWireRecord, correlation: optional(correlation) }),
  object({ cursor, kind: literal('callRemoved'), callID }),
  object({ cursor, kind: literal('cleanup'), callID, outcome: literal('removed', 'failed') }),
  object({ cursor, kind: literal('terminalCompleted'), callID }),
);
type Frame = Decoded<typeof frame>;
export type CallsSnapshot = Readonly<{
  cursor: Cursor; calls: readonly Call[]; capabilities: readonly Capability[]; pushHealth?: PushHealth;
}>;
export type Observation = Frame
  | Readonly<{ kind: 'snapshot' | 'resyncRequired'; cursor: Cursor; snapshot: CallsSnapshot }>;
type Listener = (observation: Observation) => void;

export interface CallsTransport {
  /** Attach before reading state. Snapshot terminal calls are ordered by first terminal intent. */
  attach(receive: (frame: unknown) => void): { snapshot: unknown; unsubscribe: () => void };
  /** Read the authoritative state when a frame arrives ahead of the store. */
  snapshot(): unknown;
}
export interface CallsStore {
  snapshot(): CallsSnapshot;
  observe(options?: { readonly after: Cursor }): AsyncIterable<Observation, undefined>;
  subscribe(listener: Listener): () => void;
  close(): void;
}

type Projection = {
  calls: Map<CallID, Call>;
  // Ordered by first terminal intent. Native snapshots preserve that order for terminal calls.
  terminal: Map<CallID, 'pending' | 'complete'>;
  capabilities: Map<Feature, Capability>;
  pushHealth: PushHealth | undefined;
};
function stable<Value>(previous: Value | undefined, next: Value): Value {
  return previous !== undefined && JSON.stringify(previous) === JSON.stringify(next) ? previous : next;
}
function applyRecord(state: Projection, record: WireRecord): void {
  switch (record.kind) {
    case 'call': {
      const id = record.value.id;
      const previous = state.calls.get(id);
      state.calls.set(id, stable(previous, projectCall(record.value, previous)));
      const kind = record.value.lifecycle.kind;
      if ((kind === 'ending' || kind === 'ended') && !state.terminal.has(id)) state.terminal.set(id, 'pending');
      break;
    }
    case 'mediaState': {
      const call = state.calls.get(record.value.callID);
      if (call) state.calls.set(call.id, stable(call, Object.freeze({ ...call, media: record.value })));
      break;
    }
    case 'capability': {
      const capability = record.value;
      if (!capability.callID) {
        state.capabilities.set(capability.feature, stable(state.capabilities.get(capability.feature), capability));
        break;
      }
      const call = state.calls.get(capability.callID);
      if (call) {
        const index = call.capabilities.findIndex(entry => entry.feature === capability.feature);
        const capabilities = [...call.capabilities];
        capabilities[index < 0 ? capabilities.length : index] = capability;
        state.calls.set(call.id, stable(call, Object.freeze({ ...call, capabilities: Object.freeze(capabilities) })));
      }
      break;
    }
    case 'pushHealth': state.pushHealth = stable(state.pushHealth, record.value); break;
  }
}
function removeCall(state: Projection, id: CallID): void {
  state.calls.delete(id);
  state.terminal.delete(id);
}
function prune(state: Projection, limit: number): void {
  const completed = [...state.terminal].filter(([, status]) => status === 'complete');
  for (const [id] of completed.slice(0, Math.max(0, completed.length - limit))) removeCall(state, id);
}
function hydrate(wire: Decoded<typeof nativeSnapshot>, limit: number): Projection {
  const state: Projection = { calls: new Map(), terminal: new Map(), capabilities: new Map(), pushHealth: wire.pushHealth };
  for (const call of wire.calls) {
    if (state.calls.has(call.id)) throw new TypeError('Duplicate call in native snapshot');
    applyRecord(state, { version: 0, kind: 'call', value: call });
  }
  for (const record of wire.records ?? []) applyRecord(state, record);
  for (const id of wire.completed ?? []) {
    if (state.calls.get(id)?.lifecycle.kind !== 'ended') throw new TypeError('Cleanup requires an ended call');
    state.terminal.set(id, 'complete');
  }
  prune(state, limit);
  return state;
}

export function createCallsStore(transport: CallsTransport, options: {
  readonly replayLimit?: number; readonly terminalLimit?: number;
} = {}): CallsStore {
  const replayLimit = integer(1)(options.replayLimit ?? 256);
  const terminalLimit = integer(1)(options.terminalLimit ?? 256);
  const listeners = new Set<Listener>();
  const iterators = new Set<() => void>();
  const journal: Frame[] = [];
  const pending: unknown[] = [];
  let current: CallsSnapshot;
  let state: Projection;
  let draining = true;
  let closed = false;

  function capture(at: Cursor): CallsSnapshot {
    const calls = [...state.calls.values()];
    const previous = current?.calls;
    return Object.freeze({
      cursor: at,
      calls: previous?.length === calls.length && calls.every((call, i) => previous[i] === call)
        ? previous : Object.freeze(calls),
      capabilities: stable(current?.capabilities, Object.freeze([...state.capabilities.values()])),
      ...(state.pushHealth ? { pushHealth: state.pushHealth } : {}),
    });
  }
  function checkpoint(kind: 'snapshot' | 'resyncRequired'): Observation {
    return Object.freeze({ kind, cursor: current.cursor, snapshot: current });
  }
  function publish(observation: Observation): void {
    for (const listener of [...listeners]) {
      if (!listeners.has(listener)) continue;
      try { listener(observation); }
      catch (error) { queueMicrotask(() => { throw error; }); }
    }
  }
  function accept(incoming: Frame): void {
    const { epoch, sequence } = current.cursor;
    const next = incoming.cursor;
    if (next.epoch === epoch && next.sequence <= sequence) return;
    if (next.epoch !== epoch || next.sequence !== sequence + 1) {
      const recovered = nativeSnapshot(transport.snapshot());
      const at = recovered.cursor;
      // An old epoch can replay after a replacement. The authoritative read identifies it.
      if (next.epoch !== epoch && at.epoch === epoch && at.sequence === sequence) return;
      if ((at.epoch === epoch && at.sequence <= sequence) ||
          (at.epoch === next.epoch && at.sequence < next.sequence)) {
        throw new TypeError('Native snapshot does not cover the observation gap');
      }
      state = hydrate(recovered, terminalLimit);
      current = capture(at);
      journal.length = 0;
      publish(checkpoint('resyncRequired'));
      return;
    }
    switch (incoming.kind) {
      case 'record': applyRecord(state, incoming.record); break;
      // Native owns the monotonic expiry and reports removal only after outstanding work completes.
      case 'callRemoved': removeCall(state, incoming.callID); break;
      // This acknowledgement covers media, removal, and all other outstanding adapter work.
      case 'terminalCompleted':
        if (state.calls.get(incoming.callID)?.lifecycle.kind === 'ended') {
          state.terminal.set(incoming.callID, 'complete');
          prune(state, terminalLimit);
        }
        break;
    }
    current = capture(next);
    journal.push(incoming);
    if (journal.length > replayLimit) journal.shift();
    publish(incoming);
  }
  function drain(): void {
    if (draining || closed) return;
    draining = true;
    let failure: { error: unknown } | undefined;
    try {
      for (let i = 0; i < pending.length && !closed; i++) {
        try { accept(frame(pending[i])); }
        catch (error) { failure ??= { error }; }
      }
    } finally {
      pending.length = 0;
      draining = false;
    }
    if (failure) throw failure.error;
  }
  const attachment = transport.attach(value => {
    if (closed) return;
    pending.push(value);
    drain();
  });
  try {
    const wire = nativeSnapshot(attachment.snapshot);
    state = hydrate(wire, terminalLimit);
    current = capture(wire.cursor);
    draining = false;
    drain();
  } catch (error) {
    closed = true;
    attachment.unsubscribe();
    throw error;
  }

  return {
    snapshot: () => current,
    subscribe(listener) {
      if (closed) return () => {};
      const subscription: Listener = observation => listener(observation);
      listeners.add(subscription);
      try { subscription(checkpoint('snapshot')); }
      catch (error) { listeners.delete(subscription); throw error; }
      return () => { listeners.delete(subscription); };
    },
    observe(options) {
      const after = options && cursor(options.after);
      return {
        [Symbol.asyncIterator]() {
          const queue: Observation[] = [];
          const waiting: ((result: IteratorResult<Observation>) => void)[] = [];
          const done = { done: true, value: undefined } as const;
          let initial: Observation | undefined;
          let finished = closed;
          const notify: Listener = observation => {
            const resume = waiting.shift();
            if (resume) resume({ done: false, value: observation });
            else if (queue.length >= replayLimit) queue.splice(0, queue.length, checkpoint('resyncRequired'));
            else queue.push(observation);
          };
          const finish = () => {
            finished = true;
            initial = undefined;
            queue.length = 0;
            listeners.delete(notify);
            iterators.delete(finish);
            for (const resume of waiting.splice(0)) resume(done);
          };
          if (!finished) {
            const distance = current.cursor.sequence - (after?.sequence ?? 0);
            if (!after) initial = checkpoint('snapshot');
            else if (after.epoch !== current.cursor.epoch || distance < 0 || distance > journal.length) {
              initial = checkpoint('resyncRequired');
            } else queue.push(...journal.slice(journal.length - distance));
            listeners.add(notify);
            iterators.add(finish);
          }
          return {
            async next() {
              if (finished) return done;
              const observation = initial ?? queue.shift();
              initial = undefined;
              return observation ? { done: false, value: observation } : new Promise(resolve => waiting.push(resolve));
            },
            async return() { finish(); return done; },
          };
        },
      };
    },
    close() {
      if (closed) return;
      closed = true;
      for (const finish of iterators) finish();
      listeners.clear();
      attachment.unsubscribe();
    },
  };
}
