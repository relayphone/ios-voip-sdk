import assert from 'node:assert/strict';
import { test } from 'node:test';
import { check, notes, type Source } from './release.ts';
import type { BuildInfo } from './runtime-package.ts';

const commit = 'a'.repeat(40);

function source(changes: Partial<Source> = {}): Source {
  return {
    version: '0.1.2',
    type: () => 'tag',
    commit: () => commit,
    head: () => commit,
    isAncestor: () => true,
    dirty: () => false,
    commitTime: () => 1_790_000_000,
    ...changes,
  };
}

function info(changes: Partial<BuildInfo> = {}): BuildInfo {
  return {
    schemaVersion: 1, version: '0.1.2', profile: 'ios-27.0', sourceCommit: commit, sourceDirty: false,
    sourceInputsSHA256: 'b'.repeat(64), sourceDateEpoch: 1_790_000_000,
    toolchain: { xcode: 'Xcode 27.1', swift: 'Swift 6.4', clang: 'clang 21' },
    sdk: { version: '27.0', build: '24A5355q' }, sdkPath: '/sdk', architectures: ['x86_64', 'arm64'],
    files: {}, ...changes,
  };
}

test('an annotated version tag merged into main can be released', () => {
  assert.deepEqual(check('v0.1.2', source(), 'origin/main', info()), {
    version: '0.1.2', tag: 'v0.1.2', sourceCommit: commit, mainRef: 'origin/main', packageVerified: true,
  });
});

test('the tag and the checkout must be the release', () => {
  const cases: [string, Partial<Source>, RegExp][] = [
    ['v0.1.3', {}, /must match VERSION/],
    ['v0.1.2', { type: () => 'commit' }, /annotated tag/],
    ['v0.1.2', { head: () => 'c'.repeat(40) }, /differs from tagged commit/],
    ['v0.1.2', { isAncestor: () => false }, /not merged into main/],
    ['v0.1.2', { dirty: () => true }, /dirty/],
  ];
  for (const [tag, changes, message] of cases) {
    assert.throws(() => check(tag, source(changes)), message);
  }
});

test('the package must come from the release and have both simulator slices', () => {
  const cases: [Partial<BuildInfo>, RegExp][] = [
    [{ version: '0.1.1' }, /version or source differs/],
    [{ sourceDirty: true }, /version or source differs/],
    [{ sourceDateEpoch: 1 }, /source date differs/],
    [{ toolchain: { xcode: '', swift: 'Swift', clang: 'clang' } }, /missing toolchain xcode/],
    [{ sdk: { version: '27.0', build: ' ' } }, /missing SDK build/],
    [{ architectures: ['arm64'] }, /arm64 and x86_64/],
  ];
  for (const [changes, message] of cases) {
    assert.throws(() => check('v0.1.2', source(), 'origin/main', info(changes)), message);
  }
});

test('the notes link the run that built the release', () => {
  const text = notes(commit, 'https://github.com/example/runs/1');
  assert.match(text, new RegExp(commit));
  assert.match(text, /\(https:\/\/github\.com\/example\/runs\/1\)/);
});
