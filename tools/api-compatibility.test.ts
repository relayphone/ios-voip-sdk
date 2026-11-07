import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assess, hasBreakingHeading, releaseTag, summary } from './api-compatibility.ts';

const documented = '# Changelog\n\n## Unreleased\n\n### Breaking\n\n- Explain the migration.\n';
const breakage = '/checkout/CallEvent.swift:25: error: API breakage: enum case joinFailed(_:) has been removed';

test('the release tag comes from VERSION', () => {
  assert.equal(releaseTag('0.2.1\n'), 'v0.2.1');
  for (const invalid of ['', 'v0.2.1', '0.2', '0.2.1\n--help']) {
    assert.throws(() => releaseTag(invalid), /VERSION/);
  }
});

test('only a Breaking heading within Unreleased documents the change', () => {
  assert.equal(hasBreakingHeading(documented), true);
  assert.equal(hasBreakingHeading('## Unreleased\r\n### Breaking ###\r\n'), true);
  for (const changelog of [
    '## Unreleased\n### Changed\nBreaking changes are possible.\n',
    '## Unreleased\n## 0.2.1\n### Breaking\n',
    '## Unreleased\n```md\n### Breaking\n```\n',
    '## Unreleased\n~~~~md\n### Breaking\n~~~~\n',
    '### Breaking\n## Unreleased\n',
    '## Unreleased\n    ### Breaking\n',
  ]) {
    assert.equal(hasBreakingHeading(changelog), false, changelog);
  }
});

test('compatible APIs pass without migration notes', () => {
  assert.equal(assess(0, 'No breaking changes detected', '', '0.2.1').kind, 'compatible');
});

test('an undocumented break fails and a pre-1.0 documented break passes', () => {
  assert.equal(assess(1, breakage, '', '0.2.1').kind, 'undocumented');
  const result = assess(1, breakage, documented, '0.2.1');
  assert.equal(result.kind, 'documented');
  assert.deepEqual(result.breaks, ['API breakage: enum case joinFailed(_:) has been removed']);
  assert.match(summary('v0.2.1', result), /joinFailed/);
  assert.match(summary('v0.2.1', result), /Unreleased/);
  assert.equal(assess(0, breakage, '', '0.2.1').kind, 'undocumented');
});

test('documentation cannot excuse tool failures or stable-release breaks', () => {
  for (const [status, output] of [
    [1, 'error: could not load module VoIPLiveActivity'],
    [1, `${breakage}\nerror: could not load module VoIPLiveActivity`],
    [null, breakage],
    [2, breakage],
  ] as const) {
    assert.equal(assess(status, output, documented, '0.2.1').kind, 'toolFailure');
  }
  assert.equal(assess(1, breakage, documented, '1.0.0').kind, 'undocumented');
});

test('summaries quote diagnostics as code even when identifiers contain backticks', () => {
  const result = assess(1, `${breakage} \`\`\``, '', '0.2.1');
  assert.match(summary('v0.2.1', result), /````text/);
});

test('SwiftPM warning and final summary diagnostics are deduplicated', () => {
  const diagnostic = 'API breakage: enumelement CallEvent.joinFailed has declared type change';
  const output = `/checkout/CallEvent.swift:25:8: warning: ${diagnostic} [#api-digester-breaking-change]\n` +
    `1 breaking change detected in VoIPCore:\n  💔 ${diagnostic}\n`;
  assert.deepEqual(assess(1, output, documented, '0.2.1').breaks, [diagnostic]);
});
