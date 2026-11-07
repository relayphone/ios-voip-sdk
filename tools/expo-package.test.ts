import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { checkDistribution, checkVendor, checkVersion, preparePackage, sdkTargets } from '../expo/scripts/prepare-package.mts';

function fixture(t: { after: (cleanup: () => void) => void }): string {
  const root = mkdtempSync(join(tmpdir(), 'voip-expo-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'expo/ios'), { recursive: true });
  writeFileSync(join(root, 'VERSION'), '0.2.1\n');
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({ version: '0.2.1' }));
  return root;
}

function sourceFixture(t: { after: (cleanup: () => void) => void }): string {
  const root = fixture(t);
  for (const target of sdkTargets) {
    mkdirSync(join(root, 'Sources', target), { recursive: true });
    writeFileSync(join(root, 'Sources', target, 'Example.swift'), `// ${target}\n`);
  }
  return root;
}

test('version drift fails before packaging', t => {
  const root = fixture(t);
  checkVersion(root);
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({ version: '0.2.0' }));
  assert.throws(() => preparePackage(root), /must equal VERSION/);
});

test('prepack copies exact sources and removes stale files and the standalone loader', t => {
  const root = sourceFixture(t);
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
  checkVendor(root);
  checkDistribution(join(root, 'expo'));
});

test('an incomplete checkout cannot produce a tarball with missing targets', t => {
  assert.throws(() => preparePackage(fixture(t)), /Missing SDK target/);
});

test('a checkout without a generated copy can still run the tools check', t => {
  checkVendor(fixture(t));
});

for (const change of ['source', 'vendor', 'missing', 'extra'] as const) {
  test(`the tools check rejects ${change} drift without repairing it`, t => {
    const root = sourceFixture(t);
    preparePackage(root);
    const vendor = join(root, 'expo/ios/Vendor/VoIPCore/Example.swift');
    switch (change) {
      case 'source': writeFileSync(join(root, 'Sources/VoIPCore/Example.swift'), '// changed\n'); break;
      case 'vendor': writeFileSync(vendor, '// changed\n'); break;
      case 'missing': rmSync(vendor); break;
      case 'extra': writeFileSync(join(root, 'expo/ios/Vendor/VoIPCore/Extra.swift'), '// extra\n'); break;
    }
    assert.throws(() => checkVendor(root), /differs from the SDK sources/);
    assert.throws(() => checkVendor(root), /differs from the SDK sources/);
    preparePackage(root);
    checkVendor(root);
  });
}

test('installed packages reject changed content even without the source checkout', t => {
  const root = sourceFixture(t);
  preparePackage(root);
  rmSync(join(root, 'Sources'), { recursive: true });
  checkDistribution(join(root, 'expo'));
  writeFileSync(join(root, 'expo/ios/Vendor/VoIPCore/Example.swift'), '// changed\n');
  assert.throws(() => checkDistribution(join(root, 'expo')), /differs from the SDK sources/);
});
