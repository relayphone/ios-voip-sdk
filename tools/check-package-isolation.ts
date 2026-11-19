import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { isMain, main, repository } from './command.ts';

interface ResolvedPin {
  identity: string;
  state: { version?: string };
}

function isResolvedState(value: unknown): value is ResolvedPin['state'] {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && (!('version' in value) || typeof value.version === 'string');
}

function isResolvedPin(value: unknown): value is ResolvedPin {
  return value !== null && typeof value === 'object'
    && 'identity' in value && typeof value.identity === 'string'
    && 'state' in value && isResolvedState(value.state);
}

function isResolvedPackage(value: unknown): value is { pins: ResolvedPin[] } {
  return value !== null && typeof value === 'object'
    && 'pins' in value && Array.isArray(value.pins) && value.pins.every(isResolvedPin);
}

/** Resolve real manifests in an empty checkout so prior pins/artifacts cannot hide a regression. */
export function checkPackageIsolation(mode: 'production' | 'media') {
  const scratch = mkdtempSync(join(tmpdir(), 'voip-resolution-'));
  const checkout = join(scratch, 'sdk');
  try {
    for (const path of ['Package.swift', 'VERSION', 'Sources', 'Tests', 'Inspector',
      'expo/ios/Mapping', 'exact/apple/Bridge', 'MediaTesting', 'tools/fixtures/production-consumer']) {
      const destination = join(checkout, path);
      mkdirSync(dirname(destination), { recursive: true });
      cpSync(join(repository, path), destination, {
        recursive: true, filter: file => !['.build', '.swiftpm', 'Package.resolved', '.DS_Store']
          .includes(basename(file)),
      });
    }
    const directory = join(checkout, mode === 'production' ? 'tools/fixtures/production-consumer' : 'MediaTesting');
    const result = spawnSync('swift', ['package', '--package-path', directory, 'resolve'], {
      encoding: 'utf8', timeout: 300_000, killSignal: 'SIGKILL', maxBuffer: 16 * 1024 * 1024,
    });
    const output = (result.stdout ?? '') + (result.stderr ?? '');
    assert.ifError(result.error);
    assert.equal(result.status, 0, output);
    const lockfile = join(directory, 'Package.resolved');
    const resolved: unknown =
      existsSync(lockfile) ? JSON.parse(readFileSync(lockfile, 'utf8')) : { pins: [] };
    if (!isResolvedPackage(resolved)) throw new Error('Invalid Swift package resolution');
    const livekit = resolved.pins.find(pin => pin.identity === 'client-sdk-swift');
    if (mode === 'media') {
      assert.equal(livekit?.state.version, '2.19.0', 'The optional package must resolve pinned LiveKit');
    } else {
      assert.equal(livekit, undefined, 'Production products must not resolve LiveKit');
      assert.ok(!output.includes('Fetching binary artifact'), 'Production resolution downloaded a binary artifact');
      const artifacts = join(directory, '.build/artifacts');
      assert.ok(!existsSync(artifacts) || readdirSync(artifacts).length === 0,
        'Production resolution populated binary artifacts');
    }
    console.log(`${mode}: resolved ${resolved.pins.map(pin => pin.identity).join(', ') || 'no remote dependencies'}`);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) {
  await main(() => {
    const mode = process.argv[2];
    if (mode !== 'production' && mode !== 'media') throw new Error('Use production or media');
    checkPackageIsolation(mode);
  });
}
