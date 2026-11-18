import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { createMarker } from '../../expo/src/testing/marker.ts';
import type { ConversationId } from '../../expo/src/conversations/types.ts';
import { prepareNativeJourney, type NativeJourneyBudget } from './native-journey.ts';

const scope = { fixtureId: 'fixture', conversationId: 'call' as ConversationId };
const budget = (signal = new AbortController().signal): NativeJourneyBudget => ({ deadlineMs: performance.now() + 1000, signal });
function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'native-journey-test-'));
  const sessionId = randomUUID().toUpperCase(), clockId = randomUUID().toUpperCase();
  let time = 100;
  const state = { ...scope, sessionId, clockId, observedAtMs: time,
    phaseId: null as string | null, phaseAtMs: null as number | null };
  const path = (name: string) => join(directory, `media-journey-${name}.json`);
  const write = (name: string, value: unknown) => {
    writeFileSync(path(name) + '.tmp', JSON.stringify(value)); renameSync(path(name) + '.tmp', path(name));
  };
  const reply = (command: Record<string, unknown>) => {
    time += 20;
    state.observedAtMs = time;
    if (command.operation === 'beginPhase') { state.phaseId = command.phaseId as string; state.phaseAtMs = time; }
    write('response', { ...state, commandId: command.id });
  };
  let timer: ReturnType<typeof setInterval> | undefined;
  const received: Record<string, unknown>[] = [];
  return { directory, state, path, write, received,
    mailbox: prepareNativeJourney(directory, scope),
    ready() { write('ready', state); },
    serve(handle = reply) {
      timer = setInterval(() => {
        if (!existsSync(path('command'))) return;
        const command = JSON.parse(readFileSync(path('command'), 'utf8')) as Record<string, unknown>;
        if (received.some(prior => prior.id === command.id)) return;
        received.push(command); handle(command);
      }, 1);
    },
    cleanup() { clearInterval(timer); rmSync(directory, { recursive: true, force: true }); },
  };
}

test('preparation retires stale files and connects only to a newly published native identity', async () => {
  const f = fixture();
  try {
    for (const name of ['ready', 'command', 'response', 'failure']) f.write(name, { stale: true });
    const mailbox = prepareNativeJourney(f.directory, scope);
    assert.deepEqual(readdirSync(f.directory), []);
    f.ready();
    const reply = await mailbox.connect(budget());
    assert.equal(reply.sessionId, f.state.sessionId.toLowerCase());
    assert.equal(reply.clockId, f.state.clockId.toLowerCase());
    assert.equal(reply.phaseId, null);
    await assert.rejects(mailbox.connect(budget()), /already connected/);
  } finally { f.cleanup(); }
});

test('serialized commands bind phase markers and every control to acknowledged native state', async () => {
  const f = fixture();
  try {
    f.ready(); f.serve(); await f.mailbox.connect(budget());
    await assert.rejects(f.mailbox.request({ operation: 'snapshot' }, budget()), /phase required/);
    const first = f.mailbox.request({ operation: 'beginPhase', phaseId: 'phase-one' }, budget());
    const second = f.mailbox.request({ operation: 'mute', enabled: true }, budget());
    const [phase, muted] = await Promise.all([first, second]);
    assert.equal(phase.phaseId, 'phase-one');
    assert.equal(muted.phaseAtMs, phase.phaseAtMs);
    assert.deepEqual(f.received[0]!.frequencies, createMarker('phase-one').frequencies);
    assert.equal(f.received[1]!.phaseId, 'phase-one'); assert.equal(f.received[1]!.enabled, true);
    for (const action of [
      { operation: 'video', enabled: true, source: 'app' }, { operation: 'video', enabled: false, source: 'app' },
      { operation: 'hold', enabled: true }, { operation: 'armTeardown' }, { operation: 'end' },
      { operation: 'snapshot' }, { operation: 'audioSnapshot' }, { operation: 'close' },
    ] as const) await f.mailbox.request(action, budget());
    const video = f.received.filter(command => command.operation === 'video');
    assert.ok(f.received.some(command => command.operation === 'audioSnapshot'));
    assert.deepEqual(video.map(command => [command.enabled, command.videoSource]), [[true, 'app'], [false, 'app']]);
    for (const command of f.received) {
      assert.equal(command.fixtureId, scope.fixtureId); assert.equal(command.conversationId, scope.conversationId);
      assert.equal(command.sessionId, f.state.sessionId.toLowerCase());
    }
    assert.equal(new Set(f.received.map(command => command.id)).size, f.received.length);
    assert.ok(!readdirSync(f.directory).some(name => /command-/.test(name)));
    await assert.rejects(f.mailbox.request({ operation: 'snapshot' }, budget()), /closed/);
  } finally { f.cleanup(); }
});

test('a native connection failure takes precedence over readiness', async () => {
  const f = fixture();
  try {
    f.ready();
    f.write('failure', { ...f.state, failure: { operation: 'connect', category: 'other', code: 1 } });
    await assert.rejects(f.mailbox.connect(budget()), /reported failure: connect\/other\/1/);
    await assert.rejects(f.mailbox.connect(budget()), /mailbox closed/);
  } finally { f.cleanup(); }
});

test('coded native setup and video rejection errors retire the uncertain mailbox without secrets', async () => {
  for (const operation of ['prepare', 'video'] as const) {
    const f = fixture();
    try {
      f.ready(); await f.mailbox.connect(budget());
      f.serve(command => {
        const failure = { operation, category: 'livekit', code: 101, message: 'fixture-token-secret' };
        if (operation === 'prepare') f.write('failure', { ...f.state, failure });
        else f.write('response', { commandId: command.id, rejected: true, failure });
      });
      await assert.rejects(f.mailbox.request({ operation: 'beginPhase', phaseId: 'video' }, budget()), (error: unknown) => {
        assert.ok(error instanceof Error); assert.match(error.message, /livekit\/101/);
        assert.ok(!error.message.includes('fixture-token-secret')); return true;
      });
      await assert.rejects(f.mailbox.request({ operation: 'snapshot' }, budget()), /closed/);
    } finally { f.cleanup(); }
  }
});

test('old command replies cannot acknowledge a new phase, even when all other identities match', async () => {
  const f = fixture();
  try {
    f.ready(); await f.mailbox.connect(budget());
    f.write('response', { ...f.state, commandId: randomUUID(), phaseId: 'new', phaseAtMs: 100 });
    const abort = new AbortController();
    const pending = f.mailbox.request({ operation: 'beginPhase', phaseId: 'new' }, budget(abort.signal));
    await delay(25); abort.abort();
    await assert.rejects(pending, { name: 'AbortError' });
    await assert.rejects(f.mailbox.request({ operation: 'snapshot' }, budget()), /closed/);
  } finally { f.cleanup(); }
});

test('matching command IDs still reject foreign identities, changed anchors and backwards time', async () => {
  for (const mutation of [
    { fixtureId: 'foreign' }, { conversationId: 'foreign' }, { sessionId: randomUUID() },
    { clockId: randomUUID() }, { phaseId: 'foreign' }, { observedAtMs: 99 },
    { phaseAtMs: 99 }, { phaseAtMs: 121 }, { phaseAtMs: null },
  ]) {
    const f = fixture();
    try {
      f.ready(); f.serve(command => f.write('response', { ...f.state, commandId: command.id,
        phaseId: 'current', phaseAtMs: 120, observedAtMs: 120, ...mutation }));
      await f.mailbox.connect(budget());
      await assert.rejects(f.mailbox.request({ operation: 'beginPhase', phaseId: 'current' }, budget()));
      await assert.rejects(f.mailbox.request({ operation: 'close' }, budget()), /closed/);
    } finally { f.cleanup(); }
  }
});

test('snapshot cannot renew an existing phase anchor', async () => {
  const f = fixture();
  try {
    f.ready(); f.serve(); await f.mailbox.connect(budget());
    await f.mailbox.request({ operation: 'beginPhase', phaseId: 'one' }, budget());
    f.state.phaseAtMs!++;
    await assert.rejects(f.mailbox.request({ operation: 'snapshot' }, budget()), /acknowledgement/);
  } finally { f.cleanup(); }
});

test('expired and canceled queued work does not overwrite a published command', async () => {
  const f = fixture();
  try {
    f.ready(); f.serve(); await f.mailbox.connect(budget());
    const active = f.mailbox.request({ operation: 'beginPhase', phaseId: 'active' }, budget());
    const aborted = AbortSignal.abort();
    const canceled = assert.rejects(f.mailbox.request({ operation: 'close' }, budget(aborted)), { name: 'AbortError' });
    const expired = assert.rejects(f.mailbox.request({ operation: 'close' },
      { ...budget(), deadlineMs: performance.now() - 1 }), /deadline/);
    await Promise.all([active, canceled, expired]);
    assert.equal(f.received.length, 1);
    await f.mailbox.request({ operation: 'snapshot' }, budget());
  } finally { f.cleanup(); }
});

test('native rejection, failure checkpoint and malformed JSON fail instead of passing a snapshot', async () => {
  for (const kind of ['rejected', 'failure', 'malformed'] as const) {
    const f = fixture();
    try {
      f.ready(); f.serve(command => {
        if (kind === 'rejected') f.write('response', { commandId: command.id, rejected: true });
        if (kind === 'failure') f.write('failure', { ...f.state });
        if (kind === 'malformed') writeFileSync(f.path('response'), '{');
      });
      await f.mailbox.connect(budget());
      await assert.rejects(f.mailbox.request({ operation: 'beginPhase', phaseId: 'one' }, budget()),
        kind === 'rejected' ? /rejected/ : kind === 'failure' ? /reported failure/ : /decode/);
    } finally { f.cleanup(); }
  }
});

test('ready file with an old phase or an invalid native clock cannot open a session', async () => {
  for (const mutation of [{ phaseId: 'old', phaseAtMs: 0 }, { clockId: '' }, { observedAtMs: -1 }]) {
    const f = fixture();
    try {
      f.write('ready', { ...f.state, ...mutation });
      await assert.rejects(f.mailbox.connect(budget()));
    } finally { f.cleanup(); }
  }
});

test('polling stale replies exhausts the original deadline and retires the uncertain session', async () => {
  const f = fixture();
  try {
    f.ready(); await f.mailbox.connect(budget());
    f.write('response', { ...f.state, commandId: randomUUID() });
    const deadlineMs = performance.now() + 30;
    await assert.rejects(f.mailbox.request({ operation: 'beginPhase', phaseId: 'one' },
      { ...budget(), deadlineMs }), /deadline exceeded/);
    assert.ok(performance.now() >= deadlineMs);
    await assert.rejects(f.mailbox.request({ operation: 'close' }, budget()), /closed/);
  } finally { f.cleanup(); }
});

test('queued cancellation and expiry settle while an earlier command is still unanswered', async () => {
  const f = fixture(), activeAbort = new AbortController();
  const settled: Promise<unknown>[] = [];
  try {
    f.ready(); await f.mailbox.connect(budget());
    settled.push(f.mailbox.request({ operation: 'beginPhase', phaseId: 'active' }, budget(activeAbort.signal)).catch(() => {}));
    let canceled = false, expired = false;
    settled.push(f.mailbox.request({ operation: 'close' }, budget(AbortSignal.abort())).catch(() => { canceled = true; }));
    settled.push(f.mailbox.request({ operation: 'close' }, { ...budget(), deadlineMs: performance.now() + 25 })
      .catch(() => { expired = true; }));
    await delay(75);
    assert.ok(canceled, 'Queued cancellation must not wait for the active command');
    assert.ok(expired, 'Queued deadline must not wait for the active command');
    assert.equal(JSON.parse(readFileSync(f.path('command'), 'utf8')).operation, 'beginPhase');
  } finally { activeAbort.abort(); await Promise.allSettled(settled); f.cleanup(); }
});
