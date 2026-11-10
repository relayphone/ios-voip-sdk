// Prepares the Exact package in exact/: an Exact package compiles only the Swift files its manifest
// names, inside the package, so this copies the SDK's and writes the manifest.
// Usage: node tools/package-exact.ts [--compile]
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isMain, main, repository, run } from './command.ts';

/** SDK targets an Exact app's call needs, compiled together as one Swift module. */
export const exactSdkTargets = ['VoIPCore', 'VoIPLiveCommunicationKit', 'VoIPPushKit'] as const;

/** The commit of relayphone/exact's voip/integration branch this package compiles against. */
export const exactCommit = 'cd06c16c4708e7e59d1b61e333f2ef09a0170526';

function swiftFiles(directory: string): string[] {
  return readdirSync(directory).filter(file => file.endsWith('.swift')).sort();
}

/** Copies the SDK's Swift into `exact/Vendor` and writes `exact/exact.json`; returns its sources. */
export function prepareExactPackage(checkout: string): string[] {
  const root = join(checkout, 'exact');
  const vendor = join(root, 'Vendor');
  rmSync(vendor, { recursive: true, force: true });
  const sources = exactSdkTargets.flatMap(target => {
    const from = join(checkout, 'Sources', target);
    if (!existsSync(from)) throw new Error(`Missing SDK target: ${target}`);
    mkdirSync(join(vendor, target), { recursive: true });
    return swiftFiles(from).map(file => {
      copyFileSync(join(from, file), join(vendor, target, file));
      return `Vendor/${target}/${file}`;
    });
  });
  sources.push(...swiftFiles(join(root, 'apple/Bridge')).map(file => `apple/Bridge/${file}`));
  sources.push(...swiftFiles(join(root, 'apple')).map(file => `apple/${file}`));
  writeFileSync(join(root, 'exact.json'), `${JSON.stringify({
    kind: 'implementation',
    implements: '@exact/calls@^1.0',
    platform: 'apple',
    targets: ['ios'],
    start: 'launch',
    entitlements: ['aps-environment'],
    shapes: {},
    options: {},
    names: [],
    views: [],
    hatches: [],
    sources: { swift: sources },
    artifacts: [],
    class: 'VoIPCallsModule',
    frameworks: { LiveCommunicationKit: { ios: '17.4' }, PushKit: { ios: '17.0' }, AVFAudio: { ios: '17.0' } },
  }, null, 2)}\n`);
  return sources;
}

/** Compiles the package with the flags Exact's Apple build gives a package, against Exact's seam. */
export function compileExactPackage(checkout: string, sources: readonly string[]): void {
  const temporary = mkdtempSync(join(tmpdir(), 'voip-exact-'));
  try {
    const seam = join(temporary, 'ExactPackage.swift');
    run('curl', ['-fsSL', '--retry', '3', '-o', seam,
      `https://raw.githubusercontent.com/relayphone/exact/${exactCommit}/host/apple/modules/ExactPackage.swift`]);
    const sdk = run('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-path']).trim();
    const swiftc = (name: string, files: readonly string[]) => {
      run('xcrun', ['--sdk', 'iphonesimulator', 'swiftc', '-parse-as-library', '-wmo', '-O', '-swift-version', '5',
        '-module-cache-path', join(temporary, 'cache'), '-module-name', name, '-emit-module',
        '-emit-module-path', join(temporary, `${name}.swiftmodule`), '-I', temporary, '-c', ...files,
        '-o', join(temporary, `${name}.o`), '-target', 'arm64-apple-ios26.0-simulator', '-sdk', sdk]);
    };
    swiftc('ExactPackage', [seam]);
    swiftc('ExactPkg_calls', sources.map(source => join(checkout, 'exact', source)));
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) {
  await main(() => {
    const sources = prepareExactPackage(repository);
    if (process.argv.includes('--compile')) compileExactPackage(repository, sources);
    console.log(`Prepared the Exact package with ${sources.length} Swift files.`);
  });
}
