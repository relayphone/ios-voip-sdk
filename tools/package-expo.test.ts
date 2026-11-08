import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { preparePackage, sdkTargets } from '../expo/scripts/prepare-package.mts';
import { run } from './command.ts';
import { packageExpo, verifyExpoArchive } from './package-expo.ts';
import { sha256 } from './runtime-package.ts';

function fixture(t: { after: (cleanup: () => void) => void }): string {
  const root = mkdtempSync(join(tmpdir(), 'voip-release-package-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'expo'), { recursive: true });
  writeFileSync(join(root, 'VERSION'), '0.3.1\n');
  for (const target of sdkTargets) {
    mkdirSync(join(root, 'Sources', target), { recursive: true });
    writeFileSync(join(root, 'Sources', target, 'Example.swift'), `// ${target}\n`);
  }
  const script = fileURLToPath(new URL('../expo/scripts/prepare-package.mts', import.meta.url));
  const prepack = `node --input-type=module -e 'import { preparePackage } from ${JSON.stringify(script)}; preparePackage(${JSON.stringify(root)})'`;
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({
    name: '@relayphone/ios-voip-sdk', version: '0.3.1', private: true,
    scripts: { prepack }, files: ['ios'],
  }));
  run('npm', ['install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'], {
    directory: join(root, 'expo'),
  });
  return root;
}

test('release packing runs prepack and preserves runtime checksums', t => {
  const root = fixture(t);
  const output = join(root, 'release');
  mkdirSync(output);
  const runtime = `${'a'.repeat(64)}  runtime.tar.gz\n`;
  writeFileSync(join(output, 'SHA256SUMS'), runtime);
  const name = packageExpo(root, output);
  assert.equal(name, 'relayphone-ios-voip-sdk-0.3.1.tgz');
  const archive = join(output, name);
  verifyExpoArchive(archive, '0.3.1');
  assert.equal(readFileSync(join(output, 'SHA256SUMS'), 'utf8'),
    `${runtime}${sha256(readFileSync(archive))}  ${name}\n`);
  assert.throws(() => verifyExpoArchive(archive, '0.3.2'), /version must equal VERSION/);
});

for (const fault of ['missing', 'modified'] as const) {
  test(`packed ${fault} Vendor sources fail verification`, t => {
    const root = fixture(t);
    preparePackage(root);
    const vendor = join(root, 'expo/ios/Vendor/VoIPCore/Example.swift');
    if (fault === 'missing') rmSync(vendor);
    else writeFileSync(vendor, '// changed\n');
    run('npm', ['pack', '--ignore-scripts'], { directory: join(root, 'expo') });
    assert.throws(() => verifyExpoArchive(join(root, 'expo/relayphone-ios-voip-sdk-0.3.1.tgz'), '0.3.1'),
      /differs from the SDK sources/);
  });
}

test('a tarball without Vendor cannot pass', t => {
  const root = fixture(t);
  run('npm', ['pack', '--ignore-scripts'], { directory: join(root, 'expo') });
  assert.throws(() => verifyExpoArchive(join(root, 'expo/relayphone-ios-voip-sdk-0.3.1.tgz'), '0.3.1'));
});
