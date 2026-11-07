import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { checkVersion, preparePackage, sdkTargets } from '../expo/scripts/prepare-package.ts';

function fixture(t: { after: (cleanup: () => void) => void }): string {
  const root = mkdtempSync(join(tmpdir(), 'voip-expo-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'expo/ios'), { recursive: true });
  writeFileSync(join(root, 'VERSION'), '0.2.1\n');
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({ version: '0.2.1' }));
  return root;
}

test('version drift fails before packaging', t => {
  const root = fixture(t);
  checkVersion(root);
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({ version: '0.2.0' }));
  assert.throws(() => preparePackage(root), /must equal VERSION/);
});

test('prepack copies exact sources and removes stale files and the standalone loader', t => {
  const root = fixture(t);
  for (const target of sdkTargets) {
    mkdirSync(join(root, 'Sources', target), { recursive: true });
    writeFileSync(join(root, 'Sources', target, 'Example.swift'), `// ${target}\n`);
  }
  writeFileSync(join(root, 'Sources/Interposition/CKLoader.m'), 'loader');
  writeFileSync(join(root, 'Sources/Engine/build.o'), 'object');
  mkdirSync(join(root, 'expo/ios/Vendor'), { recursive: true });
  writeFileSync(join(root, 'expo/ios/Vendor/stale.swift'), 'old');
  preparePackage(root);
  for (const target of sdkTargets) {
    assert.equal(readFileSync(join(root, 'expo/ios/Vendor', target, 'Example.swift'), 'utf8'), `// ${target}\n`);
  }
  assert.equal(existsSync(join(root, 'expo/ios/Vendor/stale.swift')), false);
  assert.equal(existsSync(join(root, 'expo/ios/Vendor/Interposition/CKLoader.m')), false);
  assert.equal(existsSync(join(root, 'expo/ios/Vendor/Engine/build.o')), false);
});

test('an incomplete checkout cannot produce a tarball with missing targets', t => {
  assert.throws(() => preparePackage(fixture(t)), /Missing SDK target/);
});
