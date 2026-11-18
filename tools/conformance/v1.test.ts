import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import { invalidV1, validV1 } from './fixtures-v1.types.ts';
import { validTypeFixtures } from './fixtures.types.ts';
import type { ModelV1 } from './model-v1.ts';
import { validatePushEnvelope } from './push-v1.ts';
import { loadCatalog } from './runner.ts';
import { canonical, decodeModel, wireID } from './schema.ts';
import { checkV1, decodeCapabilityCatalog, decodeJourneyV1, decodeModelV1, decodeVersionedModel, loadCatalogV1 } from './v1.ts';

const root = new URL('../../spec/', import.meta.url);
for (const [kind, witnesses] of Object.entries({ valid: validV1, invalid: invalidV1 })) {
  const directory = new URL('v1/fixtures/' + kind + '/', root);
  const names = readdirSync(directory).filter(name => name.endsWith('.json')).sort();
  test(`v1 ${kind} type witnesses cover every fixture`, () => {
    assert.deepEqual(names, Object.keys(witnesses).map(name => name + '.json').sort());
  });
  for (const name of names) test(`v1 ${kind}/${name} agrees with the decoder and type witness`, () => {
    const raw: unknown = JSON.parse(readFileSync(new URL(name, directory), 'utf8'));
    assert.deepEqual(raw, witnesses[name.slice(0, -5) as keyof typeof witnesses]);
    if (kind === 'invalid') assert.throws(() => decodeVersionedModel(raw));
    else {
      const decoded = decodeVersionedModel(raw);
      assert.equal(canonical(decoded), canonical(raw));
      assert.deepEqual(decodeVersionedModel(JSON.parse(canonical(decoded))), raw);
    }
  });
}

test('version dispatch keeps v0 forms readable and rejects the wrong version', () => {
  assert.deepEqual(decodeVersionedModel(validTypeFixtures.incoming), validTypeFixtures.incoming);
  assert.throws(() => decodeModel(validV1.prejoined));
  assert.throws(() => decodeModelV1(validTypeFixtures.incoming));
  assert.throws(() => decodeVersionedModel({ ...validV1.prejoined, version: 2 }));
  assert.throws(() => decodeVersionedModel({ ...validV1.pushEnvelope, value: {
    ...validV1.pushEnvelope.value, invitation: { ...validV1.pushEnvelope.value.invitation, callID: 'padded ' },
  } }));
});

test('post evidence preserves required buttons and rejects reserved extra action IDs', () => {
  const posted = validV1.posted;
  assert.throws(() => decodeModelV1({ ...posted, value: { ...posted.value, systemButtons: [] } }), /required system controls/);
  const incoming = { ...posted.value, surface: 'incomingCallStyle', systemButtons: ['answer', 'decline'] };
  assert.doesNotThrow(() => decodeModelV1({ ...posted, value: incoming }));
  assert.throws(() => decodeModelV1({ ...posted, value: { ...incoming, systemButtons: ['answer'] } }));
  const descriptor = validV1.presentation;
  assert.throws(() => decodeModelV1({ ...descriptor, value: {
    ...descriptor.value, extraActions: [{ id: wireID('answer'), title: 'Replace Answer' }],
  } }), /replace system buttons/);
});

test('media preparation, activation, transport and packet evidence stay independent', () => {
  const prejoin = validV1.prejoined;
  assert.throws(() => decodeModelV1({ ...prejoin, value: { ...prejoin.value, output: 'open' } }), /observed activation/);
  assert.throws(() => decodeModelV1({ ...prejoin, value: { ...prejoin.value, owner: 'application' } }), /native ownership/);
  assert.throws(() => decodeModelV1({ ...prejoin, value: { ...prejoin.value, firstPackets: { sent: 'unknown', received: 'observed' } } }));
  assert.doesNotThrow(() => decodeModelV1({ ...prejoin, value: {
    ...prejoin.value, stage: 'prepared', activation: 'active', output: 'open', transport: 'connecting',
  } }));
  const released = validV1.released;
  assert.throws(() => decodeModelV1({ ...released, value: { ...released.value, transport: 'connected' } }));
});

test('push expiry and evidence generation are enforced independently of shape', () => {
  const envelope = validV1.pushEnvelope;
  const { issuedAt, expiresAt } = envelope.value;
  assert.doesNotThrow(() => validatePushEnvelope(envelope.value, issuedAt));
  assert.throws(() => validatePushEnvelope(envelope.value, expiresAt));
  assert.throws(() => validatePushEnvelope(envelope.value, '2026-11-17T23:59:59.999Z'));
  assert.throws(() => decodeModelV1({ ...envelope, value: { ...envelope.value, expiresAt: issuedAt } }));
  assert.throws(() => decodeModelV1({ ...envelope, value: { ...envelope.value, issuedAt: '2026-02-30T00:00:00.000Z' } }));
  const health = validV1.pushHealth;
  assert.throws(() => decodeModelV1({ ...health, value: {
    ...health.value, registration: { ...health.value.registration, generation: 3 },
  } }), /current registered generation/);
});

test('timing boundaries require the appropriate correlation', () => {
  const timing = validV1.timing;
  assert.throws(() => decodeModelV1({ ...timing, value: {
    ...timing.value, correlation: { callID: timing.value.correlation.callID, actionID: timing.value.correlation.actionID },
  } }), /attempt identifiers/);
  assert.throws(() => decodeModelV1({ ...timing, value: {
    ...timing.value, correlation: { callID: timing.value.correlation.callID, attemptID: timing.value.correlation.attemptID },
  } }), /action identifiers/);
  assert.doesNotThrow(() => decodeModelV1({ ...timing, value: {
    ...timing.value, stage: 'pushIntake', correlation: {}, boundary: 'started', outcome: 'pending',
  } }));
});

test('capability conditions cover every feature once without overlapping Android profiles', () => {
  const raw: unknown = JSON.parse(readFileSync(new URL('capabilities.json', root), 'utf8'));
  const catalog = decodeCapabilityCatalog(raw);
  assert.throws(() => decodeCapabilityCatalog({ ...catalog, features: catalog.features.slice(1) }));
  const row = catalog.features[0]!;
  assert.throws(() => decodeCapabilityCatalog({ ...catalog, features: [
    { ...row, ios: [...row.ios, { unavailable: 'notImplemented' }] }, ...catalog.features.slice(1),
  ] }), /Overlapping iOS conditions/);
  assert.throws(() => decodeCapabilityCatalog({ ...catalog, features: [
    { ...row, android: [...row.android, { requires: 'Overlapping', minApi: 34 }] }, ...catalog.features.slice(1),
  ] }), /Overlapping Android conditions/);
});

test('the catalog keeps the v0 journeys alongside the ten v1 journeys', () => {
  assert.equal(loadCatalog(root).length, 19);
  const journeys = loadCatalogV1(root);
  assert.deepEqual(journeys.map(journey => journey.id), [
    'dialing-text-before-connect', 'http-answer-allow', 'http-answer-late-permit-release',
    'http-answer-refused-elsewhere', 'http-answer-timeout-reconcile', 'prejoin-promote',
    'refused-post-fallback', 'retention-pressure-late-removal',
    'token-rotation-stale-upload', 'unsupported-tones',
  ]);
  assert.throws(() => decodeJourneyV1({ ...journeys[0], version: 0 }));
});

test('v1 assertions reject stale snapshots and require matched cleanup evidence', () => {
  const observed = { calls: [], counts: [], participating: [], systemEnds: [], errors: [],
    records: [validV1.pushRegistration], cleanup: [], actionErrors: [] };
  const snapshot = { kind: 'record', record: validV1.pushRegistration } as const;
  checkV1(snapshot, observed);
  const older: ModelV1 = { ...validV1.pushRegistration, value: { ...validV1.pushRegistration.value, generation: 1 } };
  assert.throws(() => checkV1(snapshot, { ...observed, records: [older] }));
  assert.throws(() => checkV1(snapshot, { ...observed, records: [older, validV1.pushRegistration] }));
  const removed = { kind: 'cleanup', callID: validTypeFixtures.incoming.value.id, outcome: 'removed' } as const;
  assert.throws(() => checkV1(removed, observed), /matched to its owner/);
  assert.throws(() => checkV1({ kind: 'callAbsent', callID: removed.callID },
    { ...observed, calls: [validTypeFixtures.incoming.value] }));
  checkV1(removed, { ...observed, cleanup: [{ callID: removed.callID, outcome: 'removed' }] });
  assert.throws(() => checkV1({ kind: 'actionError', callID: removed.callID, error: { kind: 'unsupported', feature: 'tones' } },
    { ...observed, actionErrors: [{ callID: removed.callID, error: { kind: 'unsupported', feature: 'hold' } }] }));
});

test('a same-surface refusal preserves the earlier posted observation', () => {
  const observed = { calls: [], counts: [], participating: [], systemEnds: [], errors: [],
    records: [validV1.posted, validV1.refusedPost], cleanup: [], actionErrors: [] };
  const visible = { kind: 'record', record: validV1.posted } as const;
  checkV1(visible, observed);
  checkV1({ kind: 'record', record: validV1.refusedPost }, observed);
  assert.throws(() => checkV1(visible, { ...observed, records: [validV1.refusedPost] }));
  assert.throws(() => checkV1(visible, { ...observed, records: [validV1.posted, validV1.shed] }));
});
