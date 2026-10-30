import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);

test('package version matches VERSION', () => {
  const version = readFileSync(new URL('VERSION', root), 'utf8').trim();
  const packageJSON: unknown = JSON.parse(readFileSync(new URL('package.json', root), 'utf8'));
  assert.match(version, /^\d+\.\d+\.\d+$/);
  assert.ok(packageJSON && typeof packageJSON === 'object' && 'version' in packageJSON);
  assert.equal(packageJSON.version, version);
});
