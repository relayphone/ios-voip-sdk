import { randomUUID } from 'node:crypto';
import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createMarker } from '../../expo/src/testing/marker.ts';
import type { MediaTestOptions } from '../../expo/src/testing/types.ts';
import { nativeJourneyFailure } from './native-video-evidence.ts';

export type NativeJourneyAction =
  | { readonly operation: 'beginPhase'; readonly phaseId: string }
  | { readonly operation: 'mute' | 'hold'; readonly enabled: boolean }
  | { readonly operation: 'video'; readonly enabled: boolean; readonly source: 'app' }
  | { readonly operation: 'snapshot' | 'armTeardown' | 'end' | 'close' };
export interface NativeJourneyBudget {
  /** Absolute host monotonic deadline supplied by the caller; polling never renews it. */
  readonly deadlineMs: number;
  readonly signal: AbortSignal;
}
export interface NativeJourneyReply {
  readonly sessionId: string;
  readonly clockId: string;
  readonly phaseId: string | null;
  readonly phaseAtMs: number | null;
  readonly observedAtMs: number;
  /** Original untrusted snapshot. PCM, processing and terminal evidence require their own validation. */
  readonly evidence: unknown;
}

const uuid = (value: unknown): value is string => typeof value === 'string' &&
  /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Invalid native journey reply');
  return value as Record<string, unknown>;
}
function timestamp(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) throw Error('Invalid native journey time');
  return value;
}
function read(path: string): unknown {
  try { return JSON.parse(readFileSync(path, 'utf8')) as unknown; }
  catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') return undefined;
    throw Error('Cannot decode native journey reply');
  }
}
function envelope(value: unknown, options: MediaTestOptions): NativeJourneyReply {
  const row = object(value);
  if (row.fixtureId !== options.fixtureId || row.conversationId !== options.conversationId ||
      !uuid(row.sessionId) || !uuid(row.clockId)) throw Error('Foreign native journey identity');
  const phaseId = row.phaseId ?? null, phaseAtMs = row.phaseAtMs ?? null;
  if (phaseId !== null && (typeof phaseId !== 'string' || !phaseId || phaseId.length > 4096))
    throw Error('Invalid native journey phase');
  if ((phaseId === null) !== (phaseAtMs === null)) throw Error('Incomplete native journey anchor');
  const observedAtMs = timestamp(row.observedAtMs);
  if (phaseAtMs !== null && timestamp(phaseAtMs) > observedAtMs) throw Error('Future native journey anchor');
  return Object.freeze({ sessionId: row.sessionId.toLowerCase(), clockId: row.clockId.toLowerCase(),
    phaseId, phaseAtMs: phaseAtMs as number | null, observedAtMs, evidence: value });
}

/**
 * Prepare before launching the example, so a previous process's ready file cannot open a session.
 * This mailbox owns only the journey control files in the supplied example Documents directory.
 * It does not start or stop the app, server, peer or audio session.
 */
export function prepareNativeJourney(directory: string, options: MediaTestOptions) {
  if (!options.fixtureId || options.fixtureId.length > 128 || !options.conversationId || options.conversationId.length > 256)
    throw Error('Invalid native journey scope');
  const scope = Object.freeze({ fixtureId: options.fixtureId, conversationId: options.conversationId });
  const paths = {
    ready: join(directory, 'media-journey-ready.json'), command: join(directory, 'media-journey-command.json'),
    response: join(directory, 'media-journey-response.json'), failure: join(directory, 'media-journey-failure.json'),
  };
  for (const path of Object.values(paths)) rmSync(path, { force: true });
  let current: NativeJourneyReply | undefined, poisoned = false, closed = false;
  let queue = Promise.resolve();
  async function enqueue<T>(budget: NativeJourneyBudget, operation: () => Promise<T>): Promise<T> {
    check(budget);
    const turn = queue, completed = Promise.withResolvers<void>();
    // An abandoned waiter releases its own slot, but cannot bypass earlier active work.
    queue = turn.then(() => completed.promise);
    try {
      await new Promise<void>((resolve, reject) => {
        let finished = false;
        const finish = (settle: () => void) => {
          if (finished) return;
          finished = true; clearTimeout(timer); budget.signal.removeEventListener('abort', abort); settle();
        };
        const abort = () => finish(() => reject(budget.signal.reason));
        const timer = setTimeout(() => finish(() => reject(Error('Native journey deadline exceeded'))),
          Math.max(0, budget.deadlineMs - performance.now()));
        budget.signal.addEventListener('abort', abort, { once: true });
        if (budget.signal.aborted) abort();
        void turn.then(() => finish(resolve));
      });
      check(budget);
      return await operation();
    } finally { completed.resolve(); }
  }
  function check(budget: NativeJourneyBudget) {
    budget.signal.throwIfAborted();
    if (!Number.isFinite(budget.deadlineMs) || performance.now() >= budget.deadlineMs)
      throw Error('Native journey deadline exceeded');
    if (poisoned || closed) throw Error('Native journey mailbox closed');
  }
  async function poll<T>(budget: NativeJourneyBudget, attempt: () => T | undefined): Promise<T> {
    while (true) {
      check(budget);
      const value = attempt();
      if (value !== undefined) { check(budget); return value; }
      await delay(Math.min(20, Math.max(0, budget.deadlineMs - performance.now())), undefined, { signal: budget.signal });
    }
  }
  function assertNoFailure() {
    const failure = read(paths.failure);
    if (failure !== undefined) throw nativeJourneyFailure(object(failure).failure, 'attempt');
  }
  return Object.freeze({
    connect(budget: NativeJourneyBudget): Promise<NativeJourneyReply> {
      return enqueue(budget, async () => {
        check(budget);
        if (current) throw Error('Native journey already connected');
        try {
          current = await poll(budget, () => {
            assertNoFailure();
            const value = read(paths.ready);
            if (value === undefined) return;
            const reply = envelope(value, scope), row = object(value);
            if (reply.phaseId !== null || row.commandId != null) throw Error('Stale native journey ready reply');
            return reply;
          });
          return current;
        } catch (error) { poisoned = true; throw error; }
      });
    },
    request(action: NativeJourneyAction, budget: NativeJourneyBudget): Promise<NativeJourneyReply> {
      return enqueue(budget, async () => {
        check(budget);
        if (!current) throw Error('Native journey is not connected');
        const previous = current, id = randomUUID();
        const phaseId = action.operation === 'beginPhase' ? action.phaseId : previous.phaseId;
        if (action.operation !== 'close' && !phaseId) throw Error('Native journey phase required');
        const frequencies = action.operation === 'beginPhase' ? createMarker(action.phaseId).frequencies : undefined;
        const command = { id, sessionId: previous.sessionId, ...scope, operation: action.operation, phaseId,
          ...(frequencies ? { frequencies } : {}), ...('enabled' in action ? { enabled: action.enabled } : {}),
          ...(action.operation === 'video' ? { videoSource: action.source } : {}) };
        const temporary = join(directory, `media-journey-command-${id}.json`);
        try {
          writeFileSync(temporary, JSON.stringify(command), { mode: 0o600, flag: 'wx' });
          renameSync(temporary, paths.command);
          const reply = await poll(budget, () => {
            assertNoFailure();
            const value = read(paths.response);
            if (value === undefined) return;
            const row = object(value);
            if (!uuid(row.commandId) || row.commandId.toLowerCase() !== id) return;
            if (row.rejected === true) throw nativeJourneyFailure(row.failure, 'command');
            const reply = envelope(value, scope);
            if (reply.sessionId !== previous.sessionId || reply.clockId !== previous.clockId || reply.phaseId !== phaseId ||
                reply.observedAtMs < previous.observedAtMs) throw Error('Stale native journey response');
            if (action.operation === 'beginPhase' ? reply.phaseAtMs === null || reply.phaseAtMs < previous.observedAtMs :
              reply.phaseAtMs !== previous.phaseAtMs) throw Error('Invalid native journey acknowledgement');
            return reply;
          });
          current = reply;
          if (action.operation === 'close') closed = true;
          return reply;
        } catch (error) {
          // A published command may already have changed native state. Never reuse an uncertain session.
          poisoned = true;
          throw error;
        } finally { rmSync(temporary, { force: true }); }
      });
    },
  });
}
