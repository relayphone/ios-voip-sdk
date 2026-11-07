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

/** Recognize the repository's ATX headings, excluding fenced code examples. */
export function hasBreakingHeading(changelog: string): boolean {
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
    if (level <= 2) unreleased = level === 2 && title === 'Unreleased';
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
  status: number | null, output: string, changelog: string, version: string,
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
    kind = version.trim().startsWith('0.') && hasBreakingHeading(changelog)
      ? 'documented' : 'undocumented';
  }
  return { kind, breaks, output };
}

/** List the actual diagnostics in the job summary, quoted to preserve Markdown identifiers. */
export function summary(tag: string, result: Assessment): string {
  const outcome: Record<Assessment['kind'], string> = {
    compatible: 'No API breaks detected.',
    documented: 'Pre-1.0 API breaks allowed by the Unreleased Breaking heading.',
    undocumented: 'API breaks require an Unreleased Breaking heading before 1.0; stable releases fail.',
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
    const tag = releaseTag(version);
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
      const assessment = assess(result.status, output, changelog, version);
      const report = summary(tag, assessment);
      console.log(report);
      if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
      if (assessment.kind === 'undocumented' || assessment.kind === 'toolFailure') process.exitCode = 1;
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });
}
