import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { run } from './command.ts';
import { configureBundledExample, configureJourneyDeadline } from './expo-journey-bundle.ts';

test('the Debug journey build embeds production JavaScript without dev-server startup', t => {
  const ios = mkdtempSync(join(tmpdir(), 'expo-journey-bundle-'));
  t.after(() => rmSync(ios, { recursive: true, force: true }));
  configureBundledExample(ios);
  const environment = JSON.parse(run('bash', ['-c',
    'source "$1"; "$2" -e \'console.log(JSON.stringify({ skip: process.env.SKIP_BUNDLING ?? null, force: process.env.FORCE_BUNDLING, args: process.env.EXTRA_PACKAGER_ARGS, entry: process.env.ENTRY_FILE }))\'',
    'bundle-test', join(ios, '.xcode.env.updates'), process.execPath], {
    environment: { ...process.env, PROJECT_DIR: ios, SKIP_BUNDLING: '1', FORCE_BUNDLING: '', EXTRA_PACKAGER_ARGS: '' },
  }));
  assert.deepEqual(environment, { skip: null, force: '1', args: '--dev false', entry: `${ios}/../journeys/entry.ts` });
});

test('the integration build configures 27 seconds without altering other plist settings', { skip: process.platform !== 'darwin' }, t => {
  const ios = mkdtempSync(join(tmpdir(), 'expo-journey-deadline-'));
  t.after(() => rmSync(ios, { recursive: true, force: true }));
  mkdirSync(join(ios, 'VoIPExample'));
  const plist = join(ios, 'VoIPExample/Info.plist');
  writeFileSync(plist, JSON.stringify({ unrelated: 'preserved' }));
  configureJourneyDeadline(ios);
  assert.deepEqual(JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', plist])), {
    unrelated: 'preserved', VoIPConversationsFulfillAnswerCallTimeout: 27,
  });
});
