import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { isList, isString } from '../../../tools/json-fields.ts';
import { preparePackage, sdkTargets, sdkSourceDirectory } from '../../scripts/prepare-package.mts';
import { packageRoot, podspecFixture } from '../fixtures/podspec.ts';

test('CocoaPods discovers every expected SDK source from the synchronized copy', t => {
  const root = podspecFixture(t);
  const spec = join(root, 'expo/ios/VoIPConversations.podspec');
  const result = spawnSync('pod', ['ipc', 'spec', spec], { encoding: 'utf8', timeout: 15_000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

test('the Swift driver accepts the sources discovered by every CocoaPods subspec', t => {
  const root = podspecFixture(t);
  rmSync(join(root, 'Sources'), { recursive: true });
  for (const target of sdkTargets) {
    cpSync(sdkSourceDirectory(resolve(packageRoot, '..'), target), sdkSourceDirectory(root, target), { recursive: true });
  }
  cpSync(join(packageRoot, 'ios'), join(root, 'expo/ios'), {
    recursive: true, filter: path => path !== join(packageRoot, 'ios/Vendor'),
  });
  preparePackage(root);
  const discoverySpec = join(root, 'VoIPConversations.podspec');
  const sourcesPath = join(root, 'sources.json');
  writeFileSync(discoverySpec, `
    path = ENV.fetch('VOIP_TEST_PODSPEC')
    spec = Pod::Specification.from_file(path)
    files = spec.recursive_subspecs.flat_map do |subspec|
      Pod::Sandbox::FileAccessor.new(Pathname(path).dirname, subspec.consumer(:ios)).source_files
    end
    File.write(ENV.fetch('VOIP_TEST_SOURCES'), JSON.generate(files.map(&:to_s).select { |file| File.extname(file) == '.swift' }.uniq))
    spec
  `);
  const discovered = spawnSync('pod', ['ipc', 'spec', discoverySpec], {
    encoding: 'utf8', timeout: 15_000, env: {
      ...process.env, VOIP_TEST_PODSPEC: join(root, 'expo/ios/VoIPConversations.podspec'),
      VOIP_TEST_SOURCES: sourcesPath,
    },
  });
  assert.ifError(discovered.error);
  assert.equal(discovered.status, 0, discovered.stdout + discovered.stderr);
  const sources: unknown = JSON.parse(readFileSync(sourcesPath, 'utf8'));
  assert.ok(isList(sources) && sources.length > 0 && sources.every(isString));
  const result = spawnSync('xcrun', ['swiftc', '-driver-print-jobs', '-module-name', 'VoIPConversations', ...sources], {
    encoding: 'utf8', timeout: 15_000, stdio: ['ignore', 'ignore', 'pipe'],
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
});

for (const change of ['missing', 'extra'] as const) {
  test(`CocoaPods rejects ${change} SDK sources before compilation`, t => {
    const root = podspecFixture(t);
    const core = join(root, 'expo/ios/Vendor/VoIPCore');
    if (change === 'missing') rmSync(join(core, 'Example.swift'));
    else writeFileSync(join(core, 'Extra.swift'), '// unexpected fixture\n');
    const result = spawnSync('pod', ['ipc', 'spec', join(root, 'expo/ios/VoIPConversations.podspec')], {
      encoding: 'utf8', timeout: 15_000,
    });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout + result.stderr, /CocoaPods discovered [02] SDK files for Core; expected 1/);
  });
}
