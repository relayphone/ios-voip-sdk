// Checks that a release comes from an annotated version tag merged into main, and writes the
// release's qualification record and notes.
//
// Usage:
//   node tools/release.ts check <tag> [--main-ref origin/main] [--package <runtime package>]
//   node tools/release.ts record <tag> --package <runtime package> --release <release directory>
//     --notes <notes file>
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain, main, option, repository, run } from './command.ts';
import { type BuildInfo, isVersion, validate } from './runtime-package.ts';

export interface ReleaseCheck {
  version: string;
  tag: string;
  sourceCommit: string;
  mainRef: string;
  packageVerified: boolean;
}

/** The repository facts a release check needs. Tests replace them. */
export interface Source {
  version: string;
  /** The object type of a ref, such as `tag` or `commit`. */
  type(ref: string): string;
  commit(ref: string): string;
  head(): string;
  isAncestor(commit: string, ref: string): boolean;
  dirty(): boolean;
  commitTime(commit: string): number;
}

export function gitSource(): Source {
  const git = (...args: string[]) => run('git', args);
  return {
    version: readFileSync(join(repository, 'VERSION'), 'utf8').trim(),
    type: ref => git('cat-file', '-t', ref),
    commit: ref => git('rev-parse', `${ref}^{commit}`),
    head: () => git('rev-parse', 'HEAD'),
    isAncestor: (commit, ref) => {
      try {
        git('merge-base', '--is-ancestor', commit, ref);
        return true;
      } catch {
        return false;
      }
    },
    dirty: () => git('status', '--porcelain') !== '',
    commitTime: commit => Number(git('show', '-s', '--format=%ct', commit)),
  };
}

/** Checks the tag, the checkout and, if given, the package built from it. */
export function check(tag: string, source: Source, mainRef = 'origin/main', info?: BuildInfo): ReleaseCheck {
  const { version } = source;
  if (!isVersion(version) || tag !== `v${version}`) throw new Error('Release tag must match VERSION exactly');
  const ref = `refs/tags/${tag}`;
  if (source.type(ref) !== 'tag') throw new Error('Release requires an annotated tag');
  const commit = source.commit(ref);
  if (commit !== source.head()) throw new Error('Checkout differs from tagged commit');
  if (!source.isAncestor(commit, mainRef)) throw new Error('Tagged commit is not merged into main');
  if (source.dirty()) throw new Error('Release source checkout is dirty');
  if (info) {
    if (info.version !== version || info.sourceCommit !== commit || info.sourceDirty !== false) {
      throw new Error('Runtime package version or source differs from release');
    }
    if (info.sourceDateEpoch !== source.commitTime(commit)) {
      throw new Error('Runtime package source date differs from release');
    }
    for (const key of ['xcode', 'swift', 'clang'] as const) {
      if (typeof info.toolchain?.[key] !== 'string' || !info.toolchain[key].trim()) {
        throw new Error(`Runtime package is missing toolchain ${key}`);
      }
    }
    for (const key of ['version', 'build'] as const) {
      if (typeof info.sdk?.[key] !== 'string' || !info.sdk[key].trim()) {
        throw new Error(`Runtime package is missing SDK ${key}`);
      }
    }
    if ([...(info.architectures ?? [])].sort().join() !== 'arm64,x86_64') {
      throw new Error('Release requires arm64 and x86_64 simulator slices');
    }
  }
  return { version, tag, sourceCommit: commit, mainRef, packageVerified: info !== undefined };
}

/** The release notes, which link the changelog at the tag and the run that built and tested it. */
export function notes(tag: string, sourceCommit: string, run: string): string {
  return (
    `Changes: [CHANGELOG.md](https://github.com/relayphone/ios-voip-sdk/blob/${tag}/CHANGELOG.md)\n\n` +
    'The CI-built runtime passed the runtime tests and a smoke test of this package before ' +
    `packaging. Source: \`${sourceCommit}\`. [Run and evidence](${run}).\n\n` +
    'The `ios-27.0` profile names the device measurements it reproduces; `build-info.json` ' +
    'records the compiler and simulator SDK. See docs/runtime-releases.md for attestation ' +
    'verification.\n'
  );
}

if (isMain(import.meta.url)) {
  await main(() => {
    const [command, tag] = process.argv.slice(2);
    const packagePath = option(process.argv, 'package');
    const info = packagePath ? validate(resolve(packagePath)) : undefined;
    if (command === 'check' && tag) {
      const result = check(tag, gitSource(), option(process.argv, 'main-ref'), info);
      console.log(JSON.stringify(result, null, 2));
      return;
    }
    const release = option(process.argv, 'release');
    const notesFile = option(process.argv, 'notes');
    if (command === 'record' && tag && info && release && notesFile) {
      const result = check(tag, gitSource(), option(process.argv, 'main-ref'), info);
      const workflowRun = `${process.env.GITHUB_SERVER_URL ?? 'https://github.com'}/` +
        `${process.env.GITHUB_REPOSITORY ?? ''}/actions/runs/${process.env.GITHUB_RUN_ID ?? ''}`;
      writeFileSync(
        join(resolve(release), 'qualification.json'),
        `${JSON.stringify({ release: result, manifest: info, workflowRun }, null, 2)}\n`,
      );
      writeFileSync(resolve(notesFile), notes(result.tag, result.sourceCommit, workflowRun));
      return;
    }
    throw new Error('Usage: node tools/release.ts check <tag> [--main-ref <ref>] [--package <dir>] | ' +
      'record <tag> --package <dir> --release <dir> --notes <file>');
  });
}
