import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isMain, main, repository, run } from './command.ts';

/** The last release is the annotated v-prefixed tag matching VERSION. */
export function releaseTag(version: string): string {
  const value = version.trim();
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value)) {
    throw new Error('VERSION must contain a release version such as 0.2.1');
  }
  return `v${value}`;
}

/**
 * The release to compare with, and the changelog section that documents the changes.
 * A release PR raises VERSION before its tag exists: it is compared with the newest earlier
 * release, and its breaks are documented under the new release's own section.
 */
export function baseline(version: string, tags: readonly string[]): { tag: string; section: string } {
  const tag = releaseTag(version);
  if (tags.includes(tag)) return { tag, section: 'Unreleased' };
  const parts = (value: string) => value.slice(1).split('.').map(Number);
  const target = parts(tag);
  const earlier = (value: number[]) => {
    for (let index = 0; index < 3; index++) {
      if (value[index] !== target[index]) return value[index]! < target[index]!;
    }
    return false;
  };
  const previous = tags
    .filter(candidate => /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(candidate))
    .filter(candidate => earlier(parts(candidate)))
    .sort((a, b) => {
      const [x, y] = [parts(a), parts(b)];
      return y[0]! - x[0]! || y[1]! - x[1]! || y[2]! - x[2]!;
    })[0];
  if (!previous) throw new Error(`No release tag precedes ${tag}`);
  return { tag: previous, section: version.trim() };
}

/** Recognize the repository's ATX headings, excluding fenced code examples. */
export function hasBreakingHeading(changelog: string, section = 'Unreleased'): boolean {
  let unreleased = false;
  let fence: string | undefined;
  for (const line of changelog.split(/\r?\n/)) {
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (fence !== undefined) {
      if (marker?.startsWith(fence[0]!) && marker.length >= fence.length &&
          line.trim() === marker) fence = undefined;
      continue;
    }
    if (marker) { fence = marker; continue; }
    const heading = /^ {0,3}(#{1,6})[ \t]+(.+?)\s*$/.exec(line);
    if (!heading) continue;
    const level = heading[1]!.length;
    const title = heading[2]!.replace(/[ \t]+#+$/, '').trim();
    if (level <= 2) unreleased = level === 2 && (title === section || title.startsWith(`${section} (`));
    if (unreleased && level === 3 && title === 'Breaking') return true;
  }
  return false;
}

export interface Assessment {
  kind: 'compatible' | 'documented' | 'undocumented' | 'toolFailure';
  breaks: string[];
  output: string;
}

/** A documented break can excuse API diagnostics, never a failed build or tool invocation. */
export function assess(
  status: number | null, output: string, changelog: string, version: string, section = 'Unreleased',
): Assessment {
  const lines = output.split(/\r?\n/);
  const breaks = [...new Set(lines.filter(line => line.includes('API breakage:')).map(line =>
    line.slice(line.indexOf('API breakage:')).replace(/ \[#api-digester-breaking-change\]$/, '').trim(),
  ))];
  const toolError = lines.some(line => /\berror:/.test(line) && !line.includes('API breakage:'));
  let kind: Assessment['kind'];
  if (toolError || status === null || (status !== 0 && status !== 1) ||
      (status !== 0 && breaks.length === 0)) {
    kind = 'toolFailure';
  } else if (breaks.length === 0) {
    kind = 'compatible';
  } else {
    kind = version.trim().startsWith('0.') && hasBreakingHeading(changelog, section)
      ? 'documented' : 'undocumented';
  }
  return { kind, breaks, output };
}

/** List the actual diagnostics in the job summary, quoted to preserve Markdown identifiers. */
export function summary(tag: string, result: Assessment, section = 'Unreleased'): string {
  const outcome: Record<Assessment['kind'], string> = {
    compatible: 'No API breaks detected.',
    documented: `Pre-1.0 API breaks allowed by the ${section} Breaking heading.`,
    undocumented: `API breaks require a ${section} Breaking heading before 1.0; stable releases fail.`,
    toolFailure: 'API comparison failed. Documentation cannot excuse tool or build errors.',
  };
  let text = `## Public API compatibility against ${tag}\n\n${outcome[result.kind]}\n`;
  const diagnostics = result.kind === 'toolFailure' ? result.output : result.breaks.join('\n');
  if (diagnostics) {
    const longest = Math.max(2, ...[...diagnostics.matchAll(/`+/g)].map(match => match[0].length));
    const fence = '`'.repeat(longest + 1);
    text += `\n${fence}text\n${diagnostics.trim()}\n${fence}\n`;
  }
  return text;
}

if (isMain(import.meta.url)) {
  await main(() => {
    const version = readFileSync(join(repository, 'VERSION'), 'utf8');
    const tags = run('git', ['tag', '--list', 'v*', '--merged', 'HEAD'], { timeout: 30 })
      .split('\n').map(line => line.trim()).filter(Boolean);
    const { tag, section } = baseline(version, tags);
    const changelog = readFileSync(join(repository, 'CHANGELOG.md'), 'utf8');
    const sdk = run('xcrun', ['--sdk', 'iphoneos', '--show-sdk-path'], { timeout: 30 });
    const scratch = mkdtempSync(join(tmpdir(), 'voip-api-'));
    try {
      // SwiftPM compares every module belonging to a library product by default.
      const result = spawnSync('swift', [
        'package', '--scratch-path', scratch, '--triple', 'arm64-apple-ios26.0', '--sdk', sdk,
        'diagnose-api-breaking-changes', tag,
      ], { cwd: repository, encoding: 'utf8', timeout: 900_000, maxBuffer: 64 * 1024 * 1024 });
      const output = `${result.stdout ?? ''}${result.stderr ?? ''}` +
        (result.error ? `\nerror: ${result.error.message}` : '');
      console.log(output);
      const assessment = assess(result.status, output, changelog, version, section);
      const report = summary(tag, assessment, section);
      console.log(report);
      if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
      if (assessment.kind === 'undocumented' || assessment.kind === 'toolFailure') process.exitCode = 1;
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });
}
