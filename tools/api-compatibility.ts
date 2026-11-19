import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isMain, main, repository, run } from './command.ts';

interface ReleaseVersion {
  major: number;
  minor: number;
  patch: number;
}

function parseVersion(text: string) {
  const [, major, minor, patch] = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(text) ?? [];
  if (major === undefined || minor === undefined || patch === undefined) return;
  return { major: Number(major), minor: Number(minor), patch: Number(patch) } satisfies ReleaseVersion;
}

function requireVersion(version: string) {
  const text = version.trim();
  const parts = parseVersion(text);
  if (!parts) throw new Error('VERSION must contain a release version such as 0.2.1');
  return { text, parts };
}

function compareVersions(left: ReleaseVersion, right: ReleaseVersion) {
  return left.major - right.major || left.minor - right.minor || left.patch - right.patch;
}

/** The last release is the annotated v-prefixed tag matching VERSION. */
export function releaseTag(version: string) {
  return `v${requireVersion(version).text}`;
}

/**
 * The release to compare with, and the changelog section that documents the changes.
 * A release PR raises VERSION before its tag exists: it is compared with the newest earlier
 * release, and its breaks are documented under the new release's own section.
 */
export function baseline(version: string, tags: readonly string[]) {
  const target = requireVersion(version);
  const tag = `v${target.text}`;
  if (tags.includes(tag)) return { tag, section: 'Unreleased' };

  let previous: { tag: string; parts: ReleaseVersion } | undefined;
  for (const candidate of tags) {
    if (!candidate.startsWith('v')) continue;
    const parts = parseVersion(candidate.slice(1));
    if (!parts || compareVersions(parts, target.parts) >= 0) continue;
    if (!previous || compareVersions(parts, previous.parts) > 0) previous = { tag: candidate, parts };
  }
  if (!previous) throw new Error(`No release tag precedes ${tag}`);
  return { tag: previous.tag, section: target.text };
}

/** Recognize the repository's ATX headings, excluding fenced code examples. */
export function hasBreakingHeading(changelog: string, section = 'Unreleased') {
  let unreleased = false;
  let fence: string | undefined;
  for (const line of changelog.split(/\r?\n/)) {
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (fence !== undefined) {
      if (marker?.startsWith(fence.charAt(0)) && marker.length >= fence.length &&
          line.trim() === marker) fence = undefined;
      continue;
    }
    if (marker) { fence = marker; continue; }
    const [, hashes, text] = /^ {0,3}(#{1,6})[ \t]+(.+?)\s*$/.exec(line) ?? [];
    if (!hashes || text === undefined) continue;
    const level = hashes.length;
    const title = text.replace(/[ \t]+#+$/, '').trim();
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
) {
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
  return { kind, breaks, output } satisfies Assessment;
}

/** List the actual diagnostics in the job summary, quoted to preserve Markdown identifiers. */
export function summary(tag: string, result: Assessment, section = 'Unreleased') {
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
