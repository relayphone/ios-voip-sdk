import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, type TestContext } from 'node:test';
import { captureInspectorFailure, captureInspectorJournal } from './inspector-failure.ts';

const bundle = 'dev.test';
const identity = { schemaVersion: 1, bundleID: bundle, runID: 'run', pid: 123 };
function fixture(context: TestContext) {
  const container = mkdtempSync(join(tmpdir(), 'inspector-failure-'));
  context.after(() => rmSync(container, { recursive: true, force: true }));
  const channel = join(container, 'Documents/.callkit-simulator');
  mkdirSync(join(channel, 'run'), { recursive: true });
  const session = join(channel, 'session.json');
  const journal = join(channel, 'run/events.jsonl');
  const prefix = join(container, 'failure');
  writeFileSync(session, JSON.stringify(identity));
  writeFileSync(journal, '{"event":"incomingFilter.configured","sequence":1}\n');
  return { container, channel, prefix, session, journal };
}

test('copies current identity and runtime evidence without changing the source', context => {
  const f = fixture(context);
  const original = readFileSync(f.journal);
  captureInspectorJournal(f.container, bundle, f.prefix);
  assert.deepEqual(JSON.parse(readFileSync(`${f.prefix}-current-session.json`, 'utf8')), identity);
  assert.deepEqual(readFileSync(`${f.prefix}-runtime-tail.jsonl`), original);
  assert.deepEqual(readFileSync(f.journal), original);
});

test('retains a bounded tail on complete line boundaries', context => {
  const f = fixture(context);
  writeFileSync(f.journal, '{"event":"older"}\n'.repeat(40_000) + '{"event":"latest"}\n');
  captureInspectorJournal(f.container, bundle, f.prefix);
  const output = readFileSync(`${f.prefix}-runtime-tail.jsonl`, 'utf8');
  assert.ok(Buffer.byteLength(output) <= 256 * 1024);
  assert.equal(output.trim().split('\n').map(line => JSON.parse(line)).at(-1).event, 'latest');
});

test('invalid or stale session identity never selects a journal path', context => {
  const f = fixture(context);
  for (const fields of [{ runID: '../outside' }, { bundleID: 'other' }, { pid: 0 }, { schemaVersion: 2 }]) {
    writeFileSync(f.session, JSON.stringify({ ...identity, ...fields }));
    assert.throws(() => captureInspectorJournal(f.container, bundle, f.prefix), /Invalid current runtime identity/);
  }
});

test('oversized sessions, symbolic links and non-regular files are rejected', context => {
  const f = fixture(context);
  writeFileSync(f.session, ' '.repeat(65_537));
  assert.throws(() => captureInspectorJournal(f.container, bundle, f.prefix), /oversized/);
  rmSync(f.session);
  symlinkSync(f.journal, f.session);
  assert.throws(() => captureInspectorJournal(f.container, bundle, f.prefix));
  rmSync(f.session);
  mkdirSync(f.session);
  assert.throws(() => captureInspectorJournal(f.container, bundle, f.prefix), /Unsafe/);
});

test('failure capture resolves only the selected container with a ten-second command bound', context => {
  const f = fixture(context);
  let calls = 0;
  captureInspectorFailure('owned-device', bundle, f.prefix, (command, args, options) => {
    calls++;
    assert.equal(command, 'xcrun');
    assert.deepEqual(args, ['simctl', 'get_app_container', 'owned-device', bundle, 'data']);
    assert.equal(options?.timeout, 10);
    return f.container;
  });
  assert.equal(calls, 1);
  assert.ok(statSync(`${f.prefix}-runtime-tail.jsonl`).size > 0);
});

test('capture errors are bounded diagnostics and do not throw or retry', context => {
  const f = fixture(context);
  let calls = 0;
  captureInspectorFailure('owned-device', bundle, f.prefix, () => {
    calls++;
    throw new Error('container unavailable ' + 'é'.repeat(10_000));
  });
  assert.equal(calls, 1);
  assert.ok(statSync(`${f.prefix}-journal-capture.log`).size <= 4096);
  assert.match(readFileSync(`${f.prefix}-journal-capture.log`, 'utf8'), /container unavailable/);
});

test('an unwritable evidence destination still preserves the journey failure', context => {
  const f = fixture(context);
  context.mock.method(console, 'warn', () => {});
  assert.doesNotThrow(() => captureInspectorFailure('owned-device', bundle, join(f.container, 'absent/failure'), () => f.container));
});
