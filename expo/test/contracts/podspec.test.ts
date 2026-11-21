import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { packageRoot, podspecFixture } from '../fixtures/podspec.ts';

test('the compiled guard runs from node_modules and rejects stale installed sources', t => {
  const root = podspecFixture(t);
  const installed = join(root, 'node_modules/@relayphone/ios-voip-sdk');
  cpSync(join(root, 'expo'), installed, { recursive: true });
  mkdirSync(join(installed, 'build-scripts'));
  const script = join(installed, 'build-scripts/prepare-package.mjs');
  copyFileSync(join(packageRoot, 'build-scripts/prepare-package.mjs'), script);
  const run = () => spawnSync(process.execPath, [script, '--check'], { encoding: 'utf8', timeout: 10_000 });
  assert.equal(run().status, 0);
  assert.equal(spawnSync(process.execPath, [script, '--sync'], { timeout: 10_000 }).status, 0);
  writeFileSync(join(installed, 'ios/Vendor/VoIPCore/Example.swift'), '// changed\n');
  const failure = run();
  assert.notEqual(failure.status, 0);
  assert.match(failure.stderr, /Vendor differs from the SDK sources/);
});

test('the compiled build guard rejects changed checkout sources until they are synchronized', t => {
  const root = podspecFixture(t);
  const directory = join(root, 'expo/build-scripts');
  mkdirSync(directory);
  const script = join(directory, 'prepare-package.mjs');
  copyFileSync(join(packageRoot, 'build-scripts/prepare-package.mjs'), script);
  const run = (command: string) => spawnSync(process.execPath, [script, command], { encoding: 'utf8', timeout: 10_000 });
  assert.equal(run('--check').status, 0);
  writeFileSync(join(root, 'Sources/VoIPCore/Example.swift'), '// new SDK revision\n');
  const failure = run('--check');
  assert.notEqual(failure.status, 0);
  assert.match(failure.stderr, /Vendor manifest differs from the SDK sources/);
  assert.equal(run('--sync').status, 0);
  assert.equal(run('--check').status, 0);
});

test('a clean checkout sync generates the guard required by Xcode', t => {
  const root = podspecFixture(t);
  const directory = join(root, 'expo');
  rmSync(join(directory, 'ios/Vendor'), { recursive: true });
  mkdirSync(join(directory, 'scripts'));
  copyFileSync(join(packageRoot, 'scripts/prepare-package.mts'), join(directory, 'scripts/prepare-package.mts'));
  for (const name of ['package.json', 'tsconfig.json', 'tsconfig.scripts.json']) {
    copyFileSync(join(packageRoot, name), join(directory, name));
  }
  const metadata: unknown = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'));
  assert.ok(metadata && typeof metadata === 'object' && 'version' in metadata && typeof metadata.version === 'string');
  writeFileSync(join(root, 'VERSION'), `${metadata.version}\n`);
  symlinkSync(join(packageRoot, 'node_modules'), join(directory, 'node_modules'), 'dir');
  const result = spawnSync('npm', ['run', 'sync:sources', '--prefix', directory], {
    encoding: 'utf8', timeout: 30_000,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.ok(existsSync(join(directory, 'build-scripts/prepare-package.mjs')));
  const guard = spawnSync(process.execPath, [join(directory, 'build-scripts/prepare-package.mjs'), '--check'], {
    encoding: 'utf8', timeout: 10_000,
  });
  assert.equal(guard.status, 0, guard.stderr);
});
