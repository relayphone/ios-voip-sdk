import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runInspectorUITest } from './inspector-journey.ts';

test('the Mac UI invocation uses the default single run without repetition controls', () => {
  let invocations = 0;
  const output = runInspectorUITest('/fixture/work', '/fixture/result.xcresult', (command, args, options) => {
    invocations++;
    assert.equal(command, 'xcodebuild');
    assert.equal(args[0], 'test');
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
