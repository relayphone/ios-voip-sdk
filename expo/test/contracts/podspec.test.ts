import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { preparePackage, sdkTargets } from '../../scripts/prepare-package.mts';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function fixture(t: { after: (cleanup: () => void) => void }): string {
  const root = mkdtempSync(join(tmpdir(), 'voip-podspec-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'expo/ios'), { recursive: true });
  writeFileSync(join(root, 'VERSION'), '0.2.1\n');
  writeFileSync(join(root, 'expo/package.json'), JSON.stringify({
    name: '@relayphone/ios-voip-sdk', version: '0.2.1', description: 'Calls for iOS',
    homepage: 'https://github.com/relayphone/ios-voip-sdk', author: 'Relayphone', license: 'MIT',
  }));
  for (const target of sdkTargets) {
    mkdirSync(join(root, 'Sources', target), { recursive: true });
    const file = target === 'VoIPPushDelivery' ? 'Example.h' : 'Example.swift';
    writeFileSync(join(root, 'Sources', target, file), '// source fixture\n');
  }
  copyFileSync(join(packageRoot, 'ios/VoIPConversations.podspec'), join(root, 'expo/ios/VoIPConversations.podspec'));
  preparePackage(root);
  return root;
}

test('CocoaPods discovers every expected SDK source from the synchronized copy', t => {
  const root = fixture(t);
  const spec = join(root, 'expo/ios/VoIPConversations.podspec');
  const result = spawnSync('pod', ['ipc', 'spec', spec], { encoding: 'utf8', timeout: 15_000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

test('the Swift driver accepts the sources discovered by every CocoaPods subspec', t => {
  const root = fixture(t);
  rmSync(join(root, 'Sources'), { recursive: true });
  for (const target of sdkTargets) {
    cpSync(join(packageRoot, '../Sources', target), join(root, 'Sources', target), { recursive: true });
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
  assert.equal(discovered.status, 0, discovered.stdout + discovered.stderr);
  const sources: unknown = JSON.parse(readFileSync(sourcesPath, 'utf8'));
  assert.ok(Array.isArray(sources) && sources.length > 0 && sources.every(path => typeof path === 'string'));
  const result = spawnSync('xcrun', ['swiftc', '-driver-print-jobs', '-module-name', 'VoIPConversations', ...sources], {
    encoding: 'utf8', timeout: 15_000,
  });
  assert.equal(result.status, 0, result.stderr);
});

for (const change of ['missing', 'extra'] as const) {
  test(`CocoaPods rejects ${change} SDK sources before compilation`, t => {
    const root = fixture(t);
    const core = join(root, 'expo/ios/Vendor/VoIPCore');
    if (change === 'missing') rmSync(join(core, 'Example.swift'));
    else writeFileSync(join(core, 'Extra.swift'), '// unexpected fixture\n');
    const result = spawnSync('pod', ['ipc', 'spec', join(root, 'expo/ios/VoIPConversations.podspec')], {
      encoding: 'utf8', timeout: 15_000,
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stdout + result.stderr, /CocoaPods discovered [02] SDK files for Core; expected 1/);
  });
}

test('the compiled guard runs from node_modules and rejects stale installed sources', t => {
  const root = fixture(t);
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
  const root = fixture(t);
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
  const root = fixture(t);
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
