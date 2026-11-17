import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { buildInspectorUITests, runInspectorUITest } from './inspector-journey.ts';

test('builds the UI runner separately and reuses its products for test execution', async () => {
  const calls: string[][] = [];
  const execute = (_command: string, args: readonly string[]) => {
    calls.push([...args]);
    return '';
  };
  buildInspectorUITests('/fixture/work', execute);
  await runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async (command, args) => execute(command, args));
  assert.deepEqual(calls.map(args => args[0]), ['build-for-testing', 'test-without-building']);
  for (const args of calls) {
    assert.equal(args[args.indexOf('-derivedDataPath') + 1], '/fixture/work/ui-build');
    assert.equal(args[args.indexOf('-destination') + 1], 'platform=macOS');
  }
  assert.equal(calls[0]!.includes('-resultBundlePath'), false);
});

test('the Mac UI invocation uses the default single run without repetition controls', async () => {
  let invocations = 0;
  const output = await runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async (command, args, options) => {
    invocations++;
    assert.equal(command, 'xcodebuild');
    assert.equal(args[0], 'test-without-building');
    assert.equal(args[args.indexOf('-destination') + 1], 'platform=macOS');
    assert.equal(args.includes('-retry-tests-on-failure'), false);
    assert.equal(args.includes('-run-tests-until-failure'), false);
    assert.equal(args.includes('-test-iterations'), false);
    assert.equal(args.includes('-test-repetition-relaunch-enabled'), false);
    assert.equal(args[args.indexOf('-resultBundlePath') + 1], '/fixture/result.xcresult');
    assert.equal(options?.timeout, 600);
    return 'test output';
  });
  assert.equal(output, 'test output');
  assert.equal(invocations, 1);
});

test('the Mac UI invocation propagates a failed test without another execution', async () => {
  let invocations = 0;
  const failure = new Error('UI assertion failed');
  await assert.rejects(runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async () => {
    invocations++;
    throw failure;
  }), error => error === failure);
  assert.equal(invocations, 1);
});

test('the UI runner receives the actual invocation journal for report timestamps', async () => {
  await runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async (_command, _args, options) => {
    assert.equal(options.environment?.TEST_RUNNER_CKSIM_INSPECTOR_JOURNAL_FILE, '/fixture/events.jsonl');
    return '';
  }, '/fixture/events.jsonl');
});

test('successful checkbox observations reach the step summary without unrelated UI output', async context => {
  const folder = mkdtempSync(join(tmpdir(), 'inspector-summary-'));
  const previous = process.env.GITHUB_STEP_SUMMARY;
  process.env.GITHUB_STEP_SUMMARY = join(folder, 'summary.md');
  const printed: string[] = [];
  context.mock.method(console, 'log', (message: string) => { printed.push(message); });
  try {
    const details = [
      'type(of: filter.value): Optional<Any>', 'unwrapped type: String',
      'value: Optional("1")', 'isEnabled: true',
    ];
    for (const newline of ['\n', '\r\n']) {
      const output = ['unrelated test output', 'Filter after click:', ...details, 'test passed'].join(newline);
      assert.equal(await runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async () => output), output);
    }
    const expected = `Inspector checkbox after click:\n\n\`\`\`text\n${details.join('; ')}\n\`\`\``;
    assert.deepEqual(printed, [expected, expected]);
    assert.equal(readFileSync(process.env.GITHUB_STEP_SUMMARY, 'utf8'), `${expected}\n${expected}\n`);
  } finally {
    if (previous === undefined) delete process.env.GITHUB_STEP_SUMMARY;
    else process.env.GITHUB_STEP_SUMMARY = previous;
    rmSync(folder, { recursive: true, force: true });
  }
});

test('incomplete or timeout-only observations do not fabricate a successful checkbox summary', async context => {
  const printed: string[] = [];
  context.mock.method(console, 'log', (message: string) => { printed.push(message); });
  const details = ['type(of: filter.value): Optional<Any>', 'unwrapped type: NSNumber', 'value: Optional(1)', 'isEnabled: true'];
  for (const omitted of [0, 1, 2, 3]) {
    const output = ['Filter after click:', ...details.filter((_, index) => index !== omitted)].join('\n');
    await runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async () => output);
  }
  await runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {}, async () => ['Filter confirmation timeout:', ...details].join('\n'));
  assert.deepEqual(printed, []);
});
