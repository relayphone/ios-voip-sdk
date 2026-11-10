import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { exactSdkTargets, prepareExactPackage } from './package-exact.ts';

function fixture(t: TestContext): string {
  const root = mkdtempSync(join(tmpdir(), 'voip-exact-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const target of exactSdkTargets) {
    mkdirSync(join(root, 'Sources', target), { recursive: true });
    writeFileSync(join(root, 'Sources', target, `${target}.swift`), `// ${target}\n`);
    writeFileSync(join(root, 'Sources', target, 'notes.md'), 'not Swift');
  }
  mkdirSync(join(root, 'exact/apple/Bridge'), { recursive: true });
  writeFileSync(join(root, 'exact/apple/Bridge/Bridge.swift'), '// bridge\n');
  writeFileSync(join(root, 'exact/apple/Module.swift'), '// module\n');
  return root;
}

test('prepares the vendored sources and names them in the manifest', t => {
  const root = fixture(t);
  const sources = prepareExactPackage(root);
  const manifest = JSON.parse(readFileSync(join(root, 'exact/exact.json'), 'utf8'));
  assert.deepEqual(manifest.sources.swift, sources);
  assert.deepEqual(sources.slice(-2), ['apple/Bridge/Bridge.swift', 'apple/Module.swift']);
  assert.equal(manifest.implements, '@exact/calls@^1.0');
  assert.equal(manifest.start, 'launch');
  for (const target of exactSdkTargets) {
    assert.equal(readFileSync(join(root, 'exact/Vendor', target, `${target}.swift`), 'utf8'), `// ${target}\n`);
    assert.equal(existsSync(join(root, 'exact/Vendor', target, 'notes.md')), false);
  }
});

test('removes stale vendored files', t => {
  const root = fixture(t);
  mkdirSync(join(root, 'exact/Vendor/VoIPCore'), { recursive: true });
  writeFileSync(join(root, 'exact/Vendor/VoIPCore/Stale.swift'), 'old');
  prepareExactPackage(root);
  assert.equal(existsSync(join(root, 'exact/Vendor/VoIPCore/Stale.swift')), false);
});

test('fails on a missing SDK target', t => {
  const root = fixture(t);
  rmSync(join(root, 'Sources/VoIPPushKit'), { recursive: true });
  assert.throws(() => prepareExactPackage(root), /Missing SDK target: VoIPPushKit/);
});
