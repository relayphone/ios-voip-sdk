import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildInspectorUITests, runInspectorUITest } from './inspector-journey.ts';

test('builds the UI runner separately and reuses its products for test execution', () => {
  const calls: string[][] = [];
  const execute = (_command: string, args: readonly string[]) => {
    calls.push([...args]);
    return '';
  };
  buildInspectorUITests('/fixture/work', execute);
  runInspectorUITest('/fixture/work', '/fixture/result.xcresult', execute);
  assert.deepEqual(calls.map(args => args[0]), ['build-for-testing', 'test-without-building']);
  for (const args of calls) {
    assert.equal(args[args.indexOf('-derivedDataPath') + 1], '/fixture/work/ui-build');
    assert.equal(args[args.indexOf('-destination') + 1], 'platform=macOS');
  }
  assert.equal(calls[0]!.includes('-resultBundlePath'), false);
});

test('the Mac UI invocation uses the default single run without repetition controls', () => {
  let invocations = 0;
  const output = runInspectorUITest('/fixture/work', '/fixture/result.xcresult', (command, args, options) => {
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

test('the Mac UI invocation propagates a failed test without another execution', () => {
  let invocations = 0;
  const failure = new Error('UI assertion failed');
  assert.throws(() => runInspectorUITest('/fixture/work', '/fixture/result.xcresult', () => {
    invocations++;
    throw failure;
  }), error => error === failure);
  assert.equal(invocations, 1);
});
