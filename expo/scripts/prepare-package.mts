import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

/** SDK targets compiled by the package's optional CocoaPods subspecs. */
export const sdkTargets = [
  'VoIPCore', 'VoIPAudio', 'VoIPLiveCommunicationKit', 'VoIPPushKit', 'VoIPPushDelivery',
  'VoIPNotifications', 'VoIPLiveActivity', 'VoIPFocus', 'VoIPSimulator', 'MediaTesting',
  'CKSimProtocol', 'Engine', 'Interposition',
] as const;

/** Source directory for a vendored target, including the optional nested package. */
export function sdkSourceDirectory(repository: string, target: string) {
  return target === 'MediaTesting' ? join(repository, 'MediaTesting/Sources/VoIPMediaTesting')
    : join(repository, 'Sources', target);
}

function sourceFile(repository: string, path: string) {
  const [target, ...parts] = path.split('/');
  if (target === undefined) throw new Error('Missing SDK target in source path');
  return join(sdkSourceDirectory(repository, target), ...parts);
}

const manifestName = 'sources.json';

interface SourceManifest {
  version: string;
  files: Record<string, string>;
}

function isRecord(value: unknown): value is object {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isString(value: unknown): value is string {
  return typeof value === 'string';
}

function packageVersion(directory: string) {
  const value: unknown = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'));
  if (!isRecord(value) || !('version' in value) || !isString(value.version)) {
    throw new Error('The Expo package has no version');
  }
  return value.version;
}

function filesIn(directory: string) {
  return readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter(entry => !entry.isDirectory())
    .map(entry => join(entry.parentPath, entry.name));
}

function ships(path: string) {
  const parts = path.split('/');
  return path !== 'Interposition/CKLoader.m' &&
    parts.slice(0, -1).every(part => extname(part) === '') &&
    ['.swift', '.m', '.h'].includes(extname(path));
}

function digest(path: string) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function sourceManifest(repository: string) {
  const files: Record<string, string> = {};
  for (const target of sdkTargets) {
    const directory = sdkSourceDirectory(repository, target);
    if (!existsSync(directory)) throw new Error(`Missing SDK target: ${target}`);
    const paths = filesIn(directory).map(path => join(target, relative(directory, path))).filter(ships).sort();
    if (paths.length === 0) throw new Error(`Empty SDK target: ${target}`);
    for (const path of paths) files[path] = digest(sourceFile(repository, path));
  }
  return { version: packageVersion(join(repository, 'expo')), files } satisfies SourceManifest;
}

function readManifest(vendor: string) {
  const value: unknown = JSON.parse(readFileSync(join(vendor, manifestName), 'utf8'));
  if (!isRecord(value) || !('version' in value) || !isString(value.version) ||
      !('files' in value) || !isRecord(value.files)) {
    throw new Error('Invalid SDK source manifest');
  }
  const files: Record<string, string> = {};
  const entries: [string, unknown][] = Object.entries(value.files);
  for (const [path, hash] of entries) {
    if (!ships(path) || path.split('/').some(part => !part || part === '.' || part === '..') ||
        !sdkTargets.some(target => path.startsWith(`${target}/`)) ||
        !isString(hash) || !/^[a-f0-9]{64}$/.test(hash)) {
      throw new Error(`Invalid SDK source manifest entry: ${path}`);
    }
    files[path] = hash;
  }
  for (const target of sdkTargets) {
    if (!Object.keys(files).some(path => path.startsWith(`${target}/`))) {
      throw new Error(`Missing SDK target in manifest: ${target}`);
    }
  }
  return { version: value.version, files } satisfies SourceManifest;
}

function verifyFiles(vendor: string, expected: SourceManifest) {
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
export function checkVersion(repository: string) {
  const version = readFileSync(join(repository, 'VERSION'), 'utf8').trim();
  if (packageVersion(join(repository, 'expo')) !== version) {
    throw new Error(`The Expo package version must equal VERSION (${version})`);
  }
}

/** Fail on stale, missing or extra files in an existing checkout copy, without changing it. */
export function checkVendor(repository: string) {
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
export function checkDistribution(directory: string) {
  const vendor = join(directory, 'ios/Vendor');
  const manifest = readManifest(vendor);
  if (manifest.version !== packageVersion(directory)) throw new Error('Vendor version differs from the package');
  verifyFiles(vendor, manifest);
}

/** Copy source files, without build outputs or the standalone simulator loader. */
export function preparePackage(repository: string) {
  checkVersion(repository);
  const manifest = sourceManifest(repository);
  const vendor = join(repository, 'expo/ios/Vendor');
  rmSync(vendor, { recursive: true, force: true });
  mkdirSync(vendor, { recursive: true });
  for (const path of Object.keys(manifest.files)) {
    const destination = join(vendor, path);
    mkdirSync(dirname(destination), { recursive: true });
    copyFileSync(sourceFile(repository, path), destination);
  }
  writeFileSync(join(vendor, manifestName), `${JSON.stringify(manifest, null, 2)}\n`);
  checkVendor(repository);
}

function packageDirectory() {
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
