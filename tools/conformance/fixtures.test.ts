import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { invalidTypeFixtures, validTypeFixtures } from './fixtures.types.ts';
import { canonical, decodeJourney, decodeModel, decodeTransitions, validate, validateBudgets, wireID } from './schema.ts';
import { loadCatalog } from './runner.ts';

const root = new URL('../../spec/', import.meta.url);
for (const [kind, witnesses] of Object.entries({ valid: validTypeFixtures, invalid: invalidTypeFixtures })) {
  const directory = new URL(`fixtures/${kind}/`, root);
  const names = readdirSync(directory).filter(name => name.endsWith('.json')).sort();
  test(`${kind} type witnesses cover every JSON fixture`, () => {
    assert.deepEqual(names, Object.keys(witnesses).map(name => `${name}.json`).sort());
  });
  for (const name of names) test(`${kind}/${name} agrees with types and the schema decoder`, () => {
    const value: unknown = JSON.parse(readFileSync(new URL(name, directory), 'utf8'));
    assert.deepEqual(value, witnesses[name.slice(0, -5) as keyof typeof witnesses]);
    if (kind === 'invalid') assert.throws(() => decodeModel(value));
    else {
      const decoded = decodeModel(value);
      assert.equal(canonical(decoded), canonical(value));
      assert.deepEqual(decodeModel(JSON.parse(canonical(decoded))), value);
    }
  });
}

test('canonical serialization preserves IDs, Unicode and array order while sorting keys', () => {
  assert.equal(canonical({ z: ['b', 'a'], a: wireID('call-α') }), '{"a":"call-α","z":["b","a"]}');
  assert.equal(canonical({ z: 1, a: { b: true, a: null } }), canonical({ a: { a: null, b: true }, z: 1 }));
  assert.equal(canonical({ '2': false, '10': true }), '{"10":true,"2":false}');
  assert.throws(() => canonical(new Date()));
  for (const invalid of [undefined, NaN, Infinity, 1.5, 9007199254740992, 1n, () => 1]) assert.throws(() => canonical(invalid));
});

test('decoding copies caller data and preserves identity bytes', () => {
  const input = structuredClone(validTypeFixtures.incoming);
  const decoded = decodeModel(input);
  assert.equal(decoded.kind, 'call');
  assert.ok(decoded.kind === 'call');
  assert.equal(decoded.value.id, 'call-α');
  assert.notEqual(decoded.value, input.value);
  assert.notEqual(decoded.value.parties, input.value.parties);
});

test('value constraints reject blank IDs, impossible timestamps and lifecycle/direction mismatch', () => {
  for (const id of ['', ' \t\n', '\u00A0\uFEFF', 'a'.repeat(257)]) assert.throws(() => decodeModel({ ...validTypeFixtures.incoming, value: { ...validTypeFixtures.incoming.value, id } }));
  assert.doesNotThrow(() => decodeModel({ ...validTypeFixtures.incoming, value: { ...validTypeFixtures.incoming.value, id: '😀'.repeat(256) } }));
  assert.throws(() => decodeModel({ ...validTypeFixtures.connected, value: { ...validTypeFixtures.connected.value, lifecycle: { kind: 'connected', connectedAt: '2026-02-30T00:00:00.000Z' } } }));
  assert.throws(() => decodeModel({ ...validTypeFixtures.incoming, value: { ...validTypeFixtures.incoming.value, lifecycle: { kind: 'dialing' } } }));
  assert.throws(() => decodeModel({ ...validTypeFixtures.deferred, value: { ...validTypeFixtures.deferred.value, lifecycle: { kind: 'ringing' } } }));
});

test('every wire ID rejects boundary whitespace and controls without normalizing valid strings', () => {
  const whitespace = [...'\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680\u2028\u2029\u202F\u205F\u3000\uFEFF', ...Array.from({ length: 11 }, (_, i) => String.fromCodePoint(0x2000 + i))];
  const controls = Array.from({ length: 65 }, (_, i) => String.fromCodePoint(i < 32 ? i : i + 95));
  for (const space of whitespace) for (const id of [`${space}call-a`, `call-a${space}`]) assert.throws(() => wireID(id));
  for (const control of controls) for (const id of [`${control}call-a`, `call${control}a`, `call-a${control}`]) assert.throws(() => wireID(id));
  for (const id of ['call-a', 'call a', 'call-α', 'é', 'e\u0301', '😀'.repeat(256)]) assert.equal(wireID(id), id);
  for (const field of ['id', 'remoteID'] as const) assert.throws(() => decodeModel({ ...validTypeFixtures.incoming, value: { ...validTypeFixtures.incoming.value, [field]: 'call-a ' } }));
  for (const field of ['accountID', 'id'] as const) assert.throws(() => decodeModel({ ...validTypeFixtures.incoming, value: { ...validTypeFixtures.incoming.value, line: { ...validTypeFixtures.incoming.value.line, [field]: ' personal' } } }));
  assert.throws(() => decodeModel({ ...validTypeFixtures.incoming, value: { ...validTypeFixtures.incoming.value, parties: [{ ...validTypeFixtures.incoming.value.parties[0], id: 'alice\u0000' }] } }));
  assert.throws(() => decodeModel({ ...validTypeFixtures.failed, value: { kind: 'failed', error: { kind: 'claimTimedOut', actionID: 'answer\u007F' } } }));
  const journey = loadCatalog(root)[0]!;
  assert.throws(() => decodeJourney({ ...journey, id: ' journey' }));
  assert.throws(() => decodeJourney({ ...journey, steps: [{ kind: 'input', input: { kind: 'connected', callID: 'call-a', eventID: 'event-a\n' } }, ...journey.steps] }));
  const table = decodeTransitions(JSON.parse(readFileSync(new URL('transitions.json', root), 'utf8')));
  assert.throws(() => decodeTransitions({ ...table, rules: [{ ...table.rules[0], id: 'rule\u0085' }] }));
});

test('all budget values are validated and adapter deadlines remain separate from decoding', () => {
  const budgets = validTypeFixtures.budgets.value;
  for (const value of [0, -1, 1.5, Infinity, NaN]) assert.throws(() => validateBudgets({ ...budgets, placement: value }));
  assert.throws(() => validateBudgets({ ...budgets, answer: { ...budgets.answer, total: 3500 } }));
  assert.doesNotThrow(() => validateBudgets({ ...budgets, answer: { ...budgets.answer, total: 3501 } }));
  assert.throws(() => validateBudgets(budgets, 4000));
  assert.doesNotThrow(() => validateBudgets(budgets, 4500));
  const larger = { ...budgets, answer: { ...budgets.answer, total: 6000 } };
  assert.doesNotThrow(() => decodeModel({ version: 0, kind: 'budgets', value: larger }));
  assert.throws(() => validateBudgets(larger, 5000));
});

test('retention is optional on the wire and validates both bounds when supplied', () => {
  const { retention, ...budgets } = validTypeFixtures.budgets.value;
  assert.deepEqual(decodeModel({ version: 0, kind: 'budgets', value: budgets }).value, budgets);
  for (const policy of [
    { ...retention, lifetime: 0 }, { ...retention, terminalRecords: 0 },
    { ...retention, terminalRecords: 2_147_483_648 }, { lifetime: retention.lifetime },
  ]) {
    assert.throws(() => decodeModel({ version: 0, kind: 'budgets', value: { ...budgets, retention: policy } }));
  }
});

test('schema support is fail-closed even in unmatched union branches', () => {
  // @ts-expect-error An unknown keyword intentionally tests validation of schema extensions.
  assert.throws(() => validate('yes', { oneOf: [{ const: 'yes' }, { mystery: true }] }), /Unsupported schema keyword/);
  assert.throws(() => validate({}, { $ref: '#/$defs/missing' }), /Unknown schema reference/);
  assert.throws(() => validate({}, { $ref: '#/$defs/constructor' }), /Unknown schema reference/);
  assert.throws(() => validate(1, JSON.parse('{"type":"number"}')), /Unsupported schema type/);
  assert.throws(() => validate('same', { oneOf: [{ const: 'same' }, { const: 'same' }] }));
  assert.throws(() => decodeModel(JSON.parse('{"version":0,"kind":"action","value":{"kind":"answer","callID":"a","__proto__":{}}}')));
});

test('all reference journeys and the transition table decode without claiming execution', () => {
  const journeys = loadCatalog(root);
  assert.equal(journeys.length, 14);
  assert.deepEqual(journeys.map(j => j.id).sort(), [
    'incoming-killed-answer', 'claim-timeout-reconcile', 'answer-refusal', 'answer-not-allowed',
    'answer-refusal-preview', 'outgoing-deferred-binding', 'no-answer-direction', 'local-server-end-race',
    'answered-elsewhere', 'cross-line-waiting', 'end-before-admission', 'late-answer-permit',
    'end-after-server-end', 'hold-request-confirm',
  ].sort());
  const table: unknown = JSON.parse(readFileSync(new URL('transitions.json', root), 'utf8'));
  assert.ok(decodeTransitions(table).rules.length >= 26);
  assert.throws(() => decodeTransitions({ version: 0, rules: [{ id: 'bad', from: ['held'], input: 'answer', guard: 'always', to: 'connected', effects: [] }] }));
  const first = journeys[0]!;
  assert.throws(() => decodeJourney({ ...first, version: 1 }));
  assert.throws(() => decodeJourney({ ...first, steps: [{ kind: 'input', input: { kind: 'advance', milliseconds: 1 } }] }));
  assert.throws(() => decodeJourney({ ...first, steps: [{ kind: 'expect', expectation: { kind: 'count', callID: 'a', metric: 'claims', value: -1 } }] }));
});

test('every declared reducer input has a transition rule', () => {
  const schema = JSON.parse(readFileSync(new URL('model.schema.json', root), 'utf8'));
  const rules = decodeTransitions(JSON.parse(readFileSync(new URL('transitions.json', root), 'utf8'))).rules;
  assert.deepEqual(new Set(rules.map(rule => rule.input)), new Set(schema.$defs.transition.properties.input.enum));
});
