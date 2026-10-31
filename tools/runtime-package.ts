// The standalone runtime package: its manifest, its validation and its reproducible archive.
import { createHash } from 'node:crypto';
import { lstatSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { gzipSync } from 'node:zlib';

/** The files every package has, besides `build-info.json`. */
export const requiredFiles = [
  'CKSimLoader.dylib',
  'CKSimRuntime.dylib',
  'VERSION',
  'cksim',
  'profiles/ios-27.0.json',
] as const;

export interface BuildInfo {
  schemaVersion: 1;
  version: string;
  profile: string;
  sourceCommit: string;
  sourceDirty: boolean;
  sourceInputsSHA256: string;
  sourceDateEpoch: number;
  toolchain: { xcode: string; swift: string; clang: string };
  sdk: { version: string; build: string };
  sdkPath: string;
  architectures: string[];
  /** Every other file in the package and its SHA-256. */
  files: Record<string, string>;
}

export function sha256(data: Uint8Array | string): string {
  return createHash('sha256').update(data).digest('hex');
}

/** Whether the text is a version such as `1.2.3`, without leading zeros. */
export function isVersion(text: string): boolean {
  return /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(text);
}

/** Every file under the directory, as sorted paths relative to it with `/` separators. */
export function listFiles(directory: string): string[] {
  const files: string[] = [];
  const visit = (folder: string) => {
    for (const name of readdirSync(folder).sort()) {
      const path = join(folder, name);
      const status = lstatSync(path);
      if (status.isDirectory()) visit(path);
      else if (status.isFile()) files.push(relative(directory, path).split(sep).join('/'));
      else throw new Error(`Unsupported package entry: ${path}`);
    }
  };
  visit(directory);
  return files.sort();
}

/** The digest of every file in the package, which `build-info.json` records. */
export function manifest(directory: string): Record<string, string> {
  return Object.fromEntries(
    listFiles(directory).map(name => [name, sha256(readFileSync(join(directory, name)))]),
  );
}

/** The digest of the sources a package was built from, each named by its path. */
export function sourceDigest(root: string, paths: readonly string[]): string {
  const hash = createHash('sha256');
  for (const path of [...paths].sort()) {
    hash.update(path).update('\0').update(readFileSync(join(root, path))).update('\0');
  }
  return hash.digest('hex');
}

/** Checks that a package is complete and that every file matches its recorded digest. */
export function validate(directory: string): BuildInfo {
  const root = realpathSync(directory);
  let info: BuildInfo;
  let version: string;
  try {
    info = JSON.parse(readFileSync(join(root, 'build-info.json'), 'utf8')) as BuildInfo;
    version = readFileSync(join(root, 'VERSION'), 'utf8').trim();
  } catch {
    throw new Error('Incomplete or unsupported runtime package.');
  }
  if (
    info.schemaVersion !== 1 || !isVersion(version) || info.version !== version ||
    typeof info.files !== 'object' || !requiredFiles.every(name => name in info.files)
  ) {
    throw new Error('Incomplete or unsupported runtime package.');
  }
  for (const [name, digest] of Object.entries(info.files)) {
    const path = resolve(root, name);
    let actual: string | undefined;
    try {
      if (realpathSync(path).startsWith(root + sep)) actual = sha256(readFileSync(path));
    } catch {
      actual = undefined;
    }
    if (actual !== digest) throw new Error(`Runtime package checksum mismatch: ${name}`);
  }
  return info;
}

/** One ustar header block. */
function header(name: string, mode: number, size: number, mtime: number, directory: boolean): Buffer {
  const block = Buffer.alloc(512);
  let prefix = '';
  let base = name;
  if (Buffer.byteLength(name) > 100) {
    const split = name.lastIndexOf('/', 155);
    prefix = name.slice(0, split);
    base = name.slice(split + 1);
    if (split < 0 || Buffer.byteLength(base) > 100 || Buffer.byteLength(prefix) > 155) {
      throw new Error(`Path too long for the archive: ${name}`);
    }
  }
  const octal = (value: number, length: number) => value.toString(8).padStart(length - 1, '0') + '\0';
  block.write(base, 0, 100, 'utf8');
  block.write(octal(mode, 8), 100, 8, 'ascii');
  block.write(octal(0, 8), 108, 8, 'ascii');
  block.write(octal(0, 8), 116, 8, 'ascii');
  block.write(octal(size, 12), 124, 12, 'ascii');
  block.write(octal(mtime, 12), 136, 12, 'ascii');
  block.write('        ', 148, 8, 'ascii');
  block.write(directory ? '5' : '0', 156, 1, 'ascii');
  block.write('ustar\0', 257, 6, 'ascii');
  block.write('00', 263, 2, 'ascii');
  block.write(prefix, 345, 155, 'utf8');
  let checksum = 0;
  for (const byte of block) checksum += byte;
  block.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
  return block;
}

/**
 * A gzip-compressed ustar archive of the directory, with every entry's owner, time and mode
 * normalized, so that archiving the same files again gives the same bytes.
 */
export function archive(directory: string, mtime: number): Buffer {
  const parts: Buffer[] = [];
  const directories = new Set<string>(['.']);
  for (const name of listFiles(directory)) {
    const segments = name.split('/');
    for (let index = 1; index < segments.length; index += 1) {
      directories.add(segments.slice(0, index).join('/'));
    }
  }
  const entries = [
    ...[...directories].map(name => ({ name, directory: true })),
    ...listFiles(directory).map(name => ({ name, directory: false })),
  ].sort((a, b) => (a.name === '.' ? -1 : b.name === '.' ? 1 : a.name < b.name ? -1 : 1));
  for (const entry of entries) {
    const archived = entry.name === '.' ? './' : `./${entry.name}${entry.directory ? '/' : ''}`;
    if (entry.directory) {
      parts.push(header(archived, 0o755, 0, mtime, true));
      continue;
    }
    const path = join(directory, entry.name);
    const content = readFileSync(path);
    const executable = (statSync(path).mode & 0o111) !== 0;
    parts.push(header(archived, executable ? 0o755 : 0o644, content.length, mtime, false));
    parts.push(content, Buffer.alloc((512 - (content.length % 512)) % 512));
  }
  parts.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(parts), { level: 9 });
}
