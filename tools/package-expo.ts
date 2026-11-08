// Packs the React Native release asset from the full SDK checkout.
// Usage: node tools/package-expo.ts <release directory>
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { checkDistribution, checkVersion } from '../expo/scripts/prepare-package.mts';
import { isMain, main, repository, run } from './command.ts';
import { isVersion, sha256 } from './runtime-package.ts';

/** Checks the packed version and every vendored SDK source, rather than the checkout copy. */
export function verifyExpoArchive(archive: string, version: string): void {
  if (!isVersion(version)) throw new Error('Invalid package release version');
  const temporary = mkdtempSync(join(tmpdir(), 'voip-package-'));
  try {
    run('tar', ['-xzf', resolve(archive), '-C', temporary]);
    const distribution = join(temporary, 'package');
    const manifest: unknown = JSON.parse(readFileSync(join(distribution, 'package.json'), 'utf8'));
    if (!manifest || typeof manifest !== 'object' || !('version' in manifest) || manifest.version !== version) {
      throw new Error('Packed package version must equal VERSION');
    }
    checkDistribution(distribution);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

/** Runs prepack, verifies its tarball and adds it to the release checksums. */
export function packageExpo(checkout: string, output: string): string {
  checkVersion(checkout);
  const version = readFileSync(join(checkout, 'VERSION'), 'utf8').trim();
  const name = `relayphone-ios-voip-sdk-${version}.tgz`;
  mkdirSync(output, { recursive: true });
  const directory = join(checkout, 'expo');
  run('npm', ['ci', '--no-audit', '--no-fund'], { directory });
  run('npm', ['pack', '--pack-destination', resolve(output)], { directory });
  const archive = join(output, name);
  verifyExpoArchive(archive, version);
  appendFileSync(join(output, 'SHA256SUMS'), `${sha256(readFileSync(archive))}  ${name}\n`);
  return name;
}

if (isMain(import.meta.url)) {
  await main(() => {
    const output = process.argv[2];
    if (!output) throw new Error('Usage: node tools/package-expo.ts <release directory>');
    console.log(packageExpo(repository, resolve(output)));
  });
}
