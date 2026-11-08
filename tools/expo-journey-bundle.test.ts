import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { run } from './command.ts';
import { configureBundledExample } from './expo-journey-bundle.ts';

test('the Debug journey build embeds production JavaScript without dev-server startup', t => {
  const ios = mkdtempSync(join(tmpdir(), 'expo-journey-bundle-'));
  t.after(() => rmSync(ios, { recursive: true, force: true }));
  configureBundledExample(ios);
  const environment = JSON.parse(run('bash', ['-c',
    'source "$1"; "$2" -e \'console.log(JSON.stringify({ skip: process.env.SKIP_BUNDLING ?? null, force: process.env.FORCE_BUNDLING, args: process.env.EXTRA_PACKAGER_ARGS }))\'',
    'bundle-test', join(ios, '.xcode.env.updates'), process.execPath], {
    environment: { ...process.env, SKIP_BUNDLING: '1', FORCE_BUNDLING: '', EXTRA_PACKAGER_ARGS: '' },
  }));
  assert.deepEqual(environment, { skip: null, force: '1', args: '--dev false' });
});
