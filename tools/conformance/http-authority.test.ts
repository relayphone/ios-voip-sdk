import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { decodeHTTPAuthority } from './http-authority.ts';
import { canonical } from './schema.ts';
import { checkV1, loadCatalogV1 } from './v1.ts';

const fixtures = new URL('../../spec/v1/http-authority/fixtures/', import.meta.url);

for (const validity of ['valid', 'invalid'] as const) {
  const directory = new URL(`${validity}/`, fixtures);
  for (const file of readdirSync(directory).filter(name => name.endsWith('.json')).sort()) {
    const messages: unknown = JSON.parse(readFileSync(new URL(file, directory), 'utf8'));
    assert.ok(Array.isArray(messages) && messages.length > 0);
    for (const [index, message] of messages.entries()) {
      test(`HTTP Answer ${validity}/${file} #${index + 1}`, () => {
        if (validity === 'valid') assert.equal(canonical(decodeHTTPAuthority(message)), canonical(message));
        else assert.throws(() => decodeHTTPAuthority(message));
      });
    }
  }
}

test('HTTP journey assertions require complete, ordered evidence for the original action', () => {
  const journey = loadCatalogV1().find(journey => journey.id === 'http-answer-timeout-reconcile');
  const step = journey?.steps.findLast(step => step.kind === 'expect' && step.expectation.kind === 'httpRequests');
  assert.ok(step?.kind === 'expect' && step.expectation.kind === 'httpRequests');
  const expected = step.expectation;
  assert.deepEqual(expected.requests.map(request => request.operation), ['claim', 'reconcile']);
  const observed = {
    calls: [], counts: [], participating: [], systemEnds: [], errors: [],
    records: [], actionErrors: [], cleanup: [],
  };
  assert.throws(() => checkV1(expected, observed), /Missing HTTP Answer request evidence/);
  assert.throws(() => checkV1(expected, { ...observed, httpRequests: expected.requests.toReversed() }));
  assert.throws(() => checkV1(expected, { ...observed, httpRequests: [...expected.requests, ...expected.requests] }));
  checkV1(expected, { ...observed, httpRequests: expected.requests });
});
