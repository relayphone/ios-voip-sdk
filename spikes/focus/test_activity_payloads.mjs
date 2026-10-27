import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { buildPayload, buildCadence, checkedTokenSnapshot, expectedInvalidTokenRejection, simulateBackoff, simulateProjection, validateInvalidTokenFixture, validateRegistration, validateStartToken } from './activity-payloads.mjs';

test('updates are silent and an end carries final state', () => {
  const value = buildPayload({ timestamp: 1700000000, revision: 4, excerpt: 'Synthetic turn' });
  assert.equal(value.payload.aps.event, 'update');
  assert.deepEqual(value.payload.aps['content-state'], { revision: 4, excerpt: 'Synthetic turn', updatedAt: 1700000000 });
  assert.equal(value.payload.aps['stale-date'], 1700000030);
  assert.equal('alert' in value.payload.aps, false);
  assert.equal(value.bytes, Buffer.byteLength(JSON.stringify(value.payload)));
  const ended = buildPayload({ timestamp: 1700000001, event: 'end' });
  assert.equal(ended.payload.aps['dismissal-date'], 1700000001);
  assert.equal(ended.payload.aps.event, 'end');
  assert.equal('alert' in ended.payload.aps, false);
});

test('optional session binding accepts only the synthetic UUID shape', () => {
  const sessionID = 'focus-synthetic-550e8400-e29b-41d4-a716-446655440000';
  const bound = buildPayload({ timestamp: 1, sessionID, excerpt: '🙂'.repeat(2000), fit: true });
  assert.equal(bound.payload.aps['content-state'].sessionID, sessionID);
  assert.ok(bound.bytes <= 4096);
  assert.ok(bound.stateBytes <= 4096);
  assert.equal('sessionID' in buildPayload({ timestamp: 1 }).payload.aps['content-state'], false);
  for (const invalid of ['real-account-id', 'focus-synthetic-1234', 'focus-synthetic-550e8400-e29b-41d4-a716-446655440000-extra', null]) {
    assert.throws(() => buildPayload({ timestamp: 1, sessionID: invalid }), /Invalid synthetic session/);
  }
});

test('alerting remote start requires explicit authorization', () => {
  assert.throws(() => buildPayload({ timestamp: 1, event: 'start' }), /explicit alert/);
  const start = buildPayload({ timestamp: 1, event: 'start', alertAllowed: true });
  assert.equal(start.payload.aps['attributes-type'], 'FocusAttributes');
  assert.equal(start.payload.aps['input-push-token'], 1);
  assert.equal(typeof start.payload.aps.attributes.surfaceID, 'string');
  assert.equal(typeof start.payload.aps.alert.title, 'string');
});

test('per-activity sends require the same active registration and token generation', () => {
  const registration = { activityID: 'activity-a', surfaceID: 'surface-a', tokenGeneration: 'generation-a', state: 'active' };
  const token = { ...registration, token: 'ab'.repeat(32) };
  assert.equal(validateRegistration(token, registration), true);
  assert.equal(validateRegistration(token, { ...registration, tokenGeneration: 'generation-b' }), false);
  assert.equal(validateRegistration(token, { ...registration, activityID: 'other' }), false);
  assert.equal(validateRegistration(token, { ...registration, surfaceID: 'other' }), false);
  assert.equal(validateRegistration(token, { ...registration, state: 'ended' }), false);
  assert.equal(validateRegistration({ ...token, token: 'bad' }, registration), false);
  assert.equal(validateStartToken({ token: token.token, tokenGeneration: 'start-generation' }), true);
  assert.equal(validateStartToken({ token: token.token }), false);
});

test('private receipt snapshot identifies checked token without exposing token bytes', () => {
  const token = { activityID: 'activity-a', surfaceID: 'surface-a', tokenGeneration: 'generation-a',
    state: 'active', token: 'ab'.repeat(32) };
  const update = checkedTokenSnapshot(token, 'update');
  assert.deepEqual(Object.keys(update).sort(), ['activityID', 'kind', 'qualification', 'state', 'surfaceID', 'tokenGeneration'].sort());
  assert.equal(update.tokenGeneration, 'generation-a');
  assert.match(update.qualification, /later device rotation is not excluded/);
  assert.equal(JSON.stringify(update).includes(token.token), false);
  const start = checkedTokenSnapshot(token, 'start');
  assert.equal(start.kind, 'push-to-start');
  assert.equal(start.tokenGeneration, 'generation-a');
  assert.equal(JSON.stringify(start).includes(token.token), false);
});

test('invalid-token negative control is isolated and never equals a real token', () => {
  const registration = { activityID: 'synthetic-invalid-token', surfaceID: '00000000-0000-4000-8000-000000000001',
    tokenGeneration: 'synthetic-invalid-1', state: 'active' };
  const fixture = { ...registration, token: '00'.repeat(32) };
  assert.equal(validateInvalidTokenFixture(fixture, registration), true);
  assert.equal(validateInvalidTokenFixture({ ...fixture, token: 'ab'.repeat(32) }, registration), false);
  assert.equal(validateInvalidTokenFixture({ ...fixture, activityID: 'real' }, { ...registration, activityID: 'real' }), false);
  assert.equal(validateInvalidTokenFixture(fixture, { ...registration, tokenGeneration: 'stale' }), false);
  assert.equal(expectedInvalidTokenRejection(400, 'BadDeviceToken'), true);
  assert.equal(expectedInvalidTokenRejection(410, 'Unregistered'), true);
  assert.equal(expectedInvalidTokenRejection(400, 'BadPayload'), false);
  assert.equal(expectedInvalidTokenRejection(200, null), false);
});

test('UTF-8 fitting preserves full scalars and enforces both 4 KB limits', () => {
  const excerpt = '🙂👩🏽‍💻 " \\ — '.repeat(1000);
  assert.throws(() => buildPayload({ timestamp: 1, excerpt }), /4 KB/);
  const fitted = buildPayload({ timestamp: 1, excerpt, fit: true });
  assert.equal(fitted.truncated, true);
  assert.ok(fitted.bytes <= 4096);
  assert.ok(fitted.stateBytes <= 4096);
  assert.ok(excerpt.startsWith(fitted.payload.aps['content-state'].excerpt));
  assert.equal(fitted.payload.aps['content-state'].excerpt.includes('\uFFFD'), false);
  assert.deepEqual(JSON.parse(JSON.stringify(fitted.payload)), fitted.payload);
});

test('cadence is bounded and priority is explicitly selected', () => {
  const plan = buildCadence({ count: 60, intervalMs: 5000, priority: 5, firstTimestamp: 10 });
  assert.equal(plan.length, 60);
  assert.deepEqual(plan.at(-1), { offsetMs: 295000, timestamp: 305, revision: 60, priority: 5 });
  assert.equal(buildCadence({ count: 2, intervalMs: 1000, priority: 10, firstTimestamp: 10 })[1].timestamp, 11);
  assert.throws(() => buildCadence({ count: 61, intervalMs: 5000, firstTimestamp: 1 }));
  assert.throws(() => buildCadence({ count: 2, intervalMs: 500, firstTimestamp: 1 }));
  assert.throws(() => buildCadence({ count: 2, intervalMs: 1000, priority: 7, firstTimestamp: 1 }));
});

test('offline projection rejects stale token and revision without inferring rendering', () => {
  const result = simulateProjection([
    { type: 'register', version: 2, tokenID: 'new' },
    { type: 'register', version: 1, tokenID: 'old' },
    { type: 'snapshot', revision: 8 },
    { type: 'snapshot', revision: 7 },
    { type: 'apnsAccepted' },
    { type: 'rendered', revision: 7 },
  ]);
  assert.equal(result.currentToken, 'new');
  assert.equal(result.latestRevision, 8);
  assert.equal(result.renderedRevision, null);
  assert.equal(result.decisions[1].accepted, false);
  assert.equal(result.decisions[3].accepted, false);
  assert.equal(result.decisions[4].rendered, false);
  assert.equal(result.decisions[5].accepted, false);
  const ended = simulateProjection([{ type: 'end' }, { type: 'register', version: 1, tokenID: 'old' }]);
  assert.equal(ended.currentToken, null);
  assert.equal(ended.decisions[1].accepted, false);
});

test('offline backoff coalesces revisions and stays bounded', () => {
  const result = simulateBackoff({ revisions: [9, 7, 12], attempts: 5, initialDelayMs: 1000, maxDelayMs: 4000 });
  assert.equal(result.coalescedRevision, 12);
  assert.deepEqual(result.planned.map(x => x.offsetMs), [0, 1000, 3000, 7000, 11000]);
  assert.ok(result.planned.every(x => x.revision === 12));
  assert.throws(() => simulateBackoff({ revisions: [1], attempts: 7 }));
});

test('CLI dry-run is credential-free and start is refused without explicit alert opt-in', () => {
  const file = new URL('./activity-payloads.mjs', import.meta.url).pathname;
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('PHONE_APNS_')));
  const dry = spawnSync(process.execPath, [file, '--dry-run', '--event', 'update', '--timestamp', '10'], { env, encoding: 'utf8' });
  assert.equal(dry.status, 0, dry.stderr);
  assert.equal(JSON.parse(dry.stdout).simulated, true);
  const bound = spawnSync(process.execPath, [file, '--dry-run', '--event', 'update', '--timestamp', '10',
    '--session-id', 'focus-synthetic-550e8400-e29b-41d4-a716-446655440000'], { env, encoding: 'utf8' });
  assert.equal(bound.status, 0, bound.stderr);
  assert.equal(JSON.parse(bound.stdout).payload.aps['content-state'].sessionID, 'focus-synthetic-550e8400-e29b-41d4-a716-446655440000');
  const dir = mkdtempSync(join(tmpdir(), 'focus-apns-test-'));
  try {
    const token = join(dir, 'token.json'), receipt = join(dir, 'receipt.json');
    writeFileSync(token, JSON.stringify({ token: 'ab'.repeat(32), tokenGeneration: 'start-generation' }));
    const rejected = spawnSync(process.execPath, [file, '--event', 'start', '--token-file', token, '--receipt-file', receipt], { env, encoding: 'utf8' });
    assert.notEqual(rejected.status, 0);
    assert.equal(rejected.stdout, '');
    assert.equal(rejected.stderr.includes('ab'.repeat(32)), false);
    assert.throws(() => readFileSync(receipt));
    const rejectedUpdate = spawnSync(process.execPath, [file, '--event', 'update', '--token-file', token, '--receipt-file', receipt], { env, encoding: 'utf8' });
    assert.notEqual(rejectedUpdate.status, 0);
    assert.throws(() => readFileSync(receipt));
    const registrationFile = join(dir, 'registration.json');
    const registration = { activityID: 'synthetic-invalid-token', surfaceID: '00000000-0000-4000-8000-000000000001', tokenGeneration: 'synthetic-invalid-1', state: 'active' };
    writeFileSync(token, JSON.stringify({ ...registration, token: 'ab'.repeat(32) }));
    writeFileSync(registrationFile, JSON.stringify(registration));
    const rejectedFixture = spawnSync(process.execPath, [file, '--event', 'update', '--test-invalid-token', '--token-file', token, '--registration-file', registrationFile, '--receipt-file', receipt], { env, encoding: 'utf8' });
    assert.notEqual(rejectedFixture.status, 0);
    assert.throws(() => readFileSync(receipt));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
