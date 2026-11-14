import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

/** SDK targets compiled by the package's optional CocoaPods subspecs. */
export const sdkTargets = [
  'VoIPCore', 'VoIPAudio', 'VoIPLiveCommunicationKit', 'VoIPPushKit', 'VoIPPushDelivery',
  'VoIPNotifications', 'VoIPLiveActivity', 'VoIPFocus', 'VoIPSimulator', 'VoIPMediaTesting',
  'CKSimProtocol', 'Engine', 'Interposition',
] as const;

const manifestName = 'sources.json';
interface SourceManifest {
  version: string;
  files: Record<string, string>;
}

function packageVersion(directory: string): string {
  const value: unknown = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'));
  if (!value || typeof value !== 'object' || !('version' in value) || typeof value.version !== 'string') {
    throw new Error('The Expo package has no version');
  }
  return value.version;
}

function filesIn(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? filesIn(path) : [path];
  });
}

function ships(path: string): boolean {
  const parts = path.split('/');
  return path !== 'Interposition/CKLoader.m' &&
    parts.slice(0, -1).every(part => extname(part) === '') &&
    ['.swift', '.m', '.h'].includes(extname(path));
}

function digest(path: string): string {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function sourceManifest(repository: string): SourceManifest {
  const sources = join(repository, 'Sources');
  const files: Record<string, string> = {};
  for (const target of sdkTargets) {
    const directory = join(sources, target);
    if (!existsSync(directory)) throw new Error(`Missing SDK target: ${target}`);
    const paths = filesIn(directory).map(path => relative(sources, path)).filter(ships).sort();
    if (paths.length === 0) throw new Error(`Empty SDK target: ${target}`);
    for (const path of paths) files[path] = digest(join(sources, path));
  }
  return { version: packageVersion(join(repository, 'expo')), files };
}

function readManifest(vendor: string): SourceManifest {
  const value: unknown = JSON.parse(readFileSync(join(vendor, manifestName), 'utf8'));
  if (!value || typeof value !== 'object' || !('version' in value) ||
      typeof value.version !== 'string' || !('files' in value) ||
      !value.files || typeof value.files !== 'object' || Array.isArray(value.files)) {
    throw new Error('Invalid SDK source manifest');
  }
  const files: Record<string, string> = {};
  for (const [path, hash] of Object.entries(value.files)) {
    if (!ships(path) || path.split('/').some(part => !part || part === '.' || part === '..') ||
        !sdkTargets.some(target => path.startsWith(`${target}/`)) ||
        typeof hash !== 'string' || !/^[a-f0-9]{64}$/.test(hash)) {
      throw new Error(`Invalid SDK source manifest entry: ${path}`);
    }
    files[path] = hash;
  }
  for (const target of sdkTargets) {
    if (!Object.keys(files).some(path => path.startsWith(`${target}/`))) {
      throw new Error(`Missing SDK target in manifest: ${target}`);
    }
  }
  return { version: value.version, files };
}

function verifyFiles(vendor: string, expected: SourceManifest): void {
  const actual = filesIn(vendor).map(path => relative(vendor, path)).filter(path => path !== manifestName).sort();
  const paths = Object.keys(expected.files).sort();
  if (JSON.stringify(actual) !== JSON.stringify(paths)) {
    throw new Error('Vendor file list differs from the SDK sources; run npm run sync:sources');
  }
  for (const path of paths) {
    if (digest(join(vendor, path)) !== expected.files[path]) {
      throw new Error(`Vendor differs from the SDK sources at ${path}; run npm run sync:sources`);
    }
  }
}

/** Reject a package version that differs from the tag's SDK version. */
export function checkVersion(repository: string): void {
  const version = readFileSync(join(repository, 'VERSION'), 'utf8').trim();
  if (packageVersion(join(repository, 'expo')) !== version) {
    throw new Error(`The Expo package version must equal VERSION (${version})`);
  }
}

/** Fail on stale, missing or extra files in an existing checkout copy, without changing it. */
export function checkVendor(repository: string): void {
  const vendor = join(repository, 'expo/ios/Vendor');
  if (!existsSync(vendor)) return;
  const expected = sourceManifest(repository);
  const manifest = readManifest(vendor);
  if (manifest.version !== expected.version ||
      Object.keys(manifest.files).length !== Object.keys(expected.files).length ||
      Object.entries(expected.files).some(([path, hash]) => manifest.files[path] !== hash)) {
    throw new Error('Vendor manifest differs from the SDK sources; run npm run sync:sources');
  }
  verifyFiles(vendor, expected);
}

/** Check an installed distribution too, where the source checkout is unavailable. */
export function checkDistribution(directory: string): void {
  const vendor = join(directory, 'ios/Vendor');
  const manifest = readManifest(vendor);
  if (manifest.version !== packageVersion(directory)) throw new Error('Vendor version differs from the package');
  verifyFiles(vendor, manifest);
}

/** Copy source files, without build outputs or the standalone simulator loader. */
export function preparePackage(repository: string): void {
  checkVersion(repository);
  const manifest = sourceManifest(repository);
  const vendor = join(repository, 'expo/ios/Vendor');
  rmSync(vendor, { recursive: true, force: true });
  mkdirSync(vendor, { recursive: true });
  for (const path of Object.keys(manifest.files)) {
    const destination = join(vendor, path);
    mkdirSync(dirname(destination), { recursive: true });
    copyFileSync(join(repository, 'Sources', path), destination);
  }
  writeFileSync(join(vendor, manifestName), `${JSON.stringify(manifest, null, 2)}\n`);
  checkVendor(repository);
}

function packageDirectory(): string {
  let directory = dirname(fileURLToPath(import.meta.url));
  while (directory !== dirname(directory)) {
    if (existsSync(join(directory, 'ios/VoIPConversations.podspec'))) return directory;
    directory = dirname(directory);
  }
  throw new Error('Cannot locate the Expo package');
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const directory = packageDirectory();
    const repository = dirname(directory);
    const command = process.argv[2];
    if (command !== '--sync' && command !== '--check') throw new Error('Use --sync or --check');
    if (existsSync(join(repository, 'Sources/VoIPCore')) && existsSync(join(repository, 'VERSION'))) {
      if (command === '--sync') preparePackage(repository);
      else { checkVersion(repository); checkVendor(repository); }
    }
    checkDistribution(directory);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
