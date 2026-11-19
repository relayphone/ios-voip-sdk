import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { gunzipSync } from 'node:zlib';
import { packageRuntime } from './package-runtime.ts';
import { archive, hasBuildInfo, isVersion, manifest, requiredFiles, sha256, sourceDigest, validate } from './runtime-package.ts';

/** A package with placeholder files and a correct manifest, in a new temporary directory. */
function makePackage() {
  const root = mkdtempSync(join(tmpdir(), 'runtime-package-'));
  const directory = join(root, 'package');
  mkdirSync(join(directory, 'profiles'), { recursive: true });
  for (const name of requiredFiles) {
    writeFileSync(join(directory, name), name === 'VERSION' ? '0.1.2\n' : `placeholder ${name}`);
  }
  chmodSync(join(directory, 'cksim'), 0o755);
  const info = { schemaVersion: 1, version: '0.1.2', sourceDateEpoch: 1_790_000_000, files: manifest(directory) };
  writeFileSync(join(directory, 'build-info.json'), JSON.stringify(info));
  return { root, directory, info };
}

interface Entry { name: string; mode: number; uid: number; gid: number; size: number; mtime: number; type: string }

/** The entries of a gzip-compressed ustar archive. */
function entries(data: Buffer) {
  const tar = gunzipSync(data);
  const result: Entry[] = [];
  for (let offset = 0; offset + 512 <= tar.length;) {
    const block = tar.subarray(offset, offset + 512);
    if (block.every(byte => byte === 0)) break;
    const text = (start: number, length: number) =>
      block.subarray(start, start + length).toString('utf8').replace(/\0.*$/s, '');
    const number = (start: number, length: number) => parseInt(text(start, length).trim() || '0', 8);
    const prefix = text(345, 155);
    const entry = {
      name: prefix ? `${prefix}/${text(0, 100)}` : text(0, 100), mode: number(100, 8), uid: number(108, 8),
      gid: number(116, 8), size: number(124, 12), mtime: number(136, 12), type: text(156, 1),
    };
    result.push(entry);
    offset += 512 + Math.ceil(entry.size / 512) * 512;
  }
  return result;
}

test('versions have three numbers without leading zeros', () => {
  assert.ok(isVersion('0.1.12') && isVersion('10.0.0'));
  for (const text of ['01.1.0', '1.2', '1.2.x', 'v1.2.3', '1.2.3 ']) assert.ok(!isVersion(text), text);
});

test('a complete package validates and a changed or escaping file does not', () => {
  const { root, directory } = makePackage();
  try {
    assert.equal(validate(directory).version, '0.1.2');
    writeFileSync(join(directory, 'CKSimRuntime.dylib'), 'corrupted');
    assert.throws(() => validate(directory), /Runtime package checksum mismatch: CKSimRuntime.dylib/);

    const other = makePackage();
    writeFileSync(join(other.root, 'outside.dylib'), 'outside');
    other.info.files['../outside.dylib'] = sha256('outside');
    writeFileSync(join(other.directory, 'build-info.json'), JSON.stringify(other.info));
    assert.throws(() => validate(other.directory), /Runtime package checksum mismatch: \.\.\/outside\.dylib/);
    rmSync(other.root, { recursive: true });

    const incomplete = makePackage();
    rmSync(join(incomplete.directory, 'cksim'));
    delete incomplete.info.files['cksim'];
    writeFileSync(join(incomplete.directory, 'build-info.json'), JSON.stringify(incomplete.info));
    assert.throws(() => validate(incomplete.directory), /Incomplete or unsupported runtime package/);
    rmSync(incomplete.root, { recursive: true });
  } finally {
    rmSync(root, { recursive: true });
  }
});

test('a checksum-valid package can be inspected without release provenance', () => {
  const { root, directory, info } = makePackage();
  try {
    const path = join(directory, 'build-info.json');
    assert.equal(hasBuildInfo(validate(directory)), false);
    const qualified = {
      ...info,
      profile: 'ios-27.0',
      sourceCommit: 'a'.repeat(40),
      sourceDirty: false,
      sourceInputsSHA256: 'b'.repeat(64),
      toolchain: { xcode: 'Xcode 27.1', swift: 'Swift 6.4', clang: 'clang 21' },
      sdk: { version: '27.0', build: '24A5355q' },
      sdkPath: '/sdk',
      architectures: ['arm64', 'x86_64'],
    };
    writeFileSync(path, JSON.stringify(qualified));
    assert.equal(hasBuildInfo(validate(directory)), true);
    writeFileSync(path, JSON.stringify({ ...qualified, architectures: ['arm64', 1] }));
    assert.equal(hasBuildInfo(validate(directory)), false);
    writeFileSync(path, JSON.stringify({ ...qualified, files: null }));
    assert.throws(() => validate(directory), /Incomplete or unsupported runtime package/);
  } finally {
    rmSync(root, { recursive: true });
  }
});

test('the archive normalizes every entry and is reproducible', () => {
  const { root, directory } = makePackage();
  try {
    const first = archive(directory, 1_790_000_000);
    utimesSync(join(directory, 'VERSION'), new Date(), new Date());
    assert.deepEqual(archive(directory, 1_790_000_000), first);
    const listed = entries(first);
    assert.deepEqual(listed.map(entry => entry.name), [
      './', './CKSimLoader.dylib', './CKSimRuntime.dylib', './VERSION', './build-info.json', './cksim',
      './profiles/', './profiles/ios-27.0.json',
    ]);
    for (const entry of listed) {
      assert.equal(entry.uid, 0);
      assert.equal(entry.gid, 0);
      assert.equal(entry.mtime, 1_790_000_000);
      const executable = entry.type === '5' || entry.name === './cksim';
      assert.equal(entry.mode, executable ? 0o755 : 0o644, entry.name);
    }
    assert.equal(listed.find(entry => entry.name === './VERSION')?.size, '0.1.2\n'.length);
  } finally {
    rmSync(root, { recursive: true });
  }
});

test('packaging writes the archive and its checksum', () => {
  const { root, directory } = makePackage();
  try {
    const output = join(root, 'release');
    const name = packageRuntime(directory, output);
    assert.equal(name, 'callkit-simulator-v0.1.2-macos.tar.gz');
    const data = readFileSync(join(output, name));
    assert.equal(readFileSync(join(output, 'SHA256SUMS'), 'utf8'), `${sha256(data)}  ${name}\n`);
    assert.throws(() => packageRuntime(directory, output), /Output already exists/);
  } finally {
    rmSync(root, { recursive: true });
  }
});

test('the source digest names each input and ignores their order', () => {
  const root = mkdtempSync(join(tmpdir(), 'source-digest-'));
  try {
    writeFileSync(join(root, 'a'), 'one');
    writeFileSync(join(root, 'b'), 'two');
    assert.equal(sourceDigest(root, ['a', 'b']), sourceDigest(root, ['b', 'a']));
    writeFileSync(join(root, 'b'), 'changed');
    assert.notEqual(sourceDigest(root, ['a', 'b']), sha256(''));
  } finally {
    rmSync(root, { recursive: true });
  }
});
