import assert from 'node:assert/strict';
import { test } from 'node:test';
import { diagnoseNativeStartup } from './startup-diagnostics.ts';
import { assertNativePassed } from './result-receipt.ts';

const clockID = '67887586-D7A2-44B6-ABAF-FF25DFB67DFE';
const row = (event: string, atMs: number, payload: object = {}) => ({ event: { [event]: payload }, atMs });
const report = (observations: unknown[]) => JSON.parse(JSON.stringify({ passed: false, phase: 'duplex',
  startup: { clockID, observations } }));

test('legacy duplex replay retains uncertainty rather than inferring activation or prepare completion', () => {
  const replay = report([
    row('prepareEntered', 1758.867), row('roomConnectRequested', 1760.316),
    row('roomConnectCompleted', 3361.554), row('tapInstalled', 3422.117, { _0: 'decoded' }),
    row('captureOptionsApplied', 3452.822),
  ]);
  assert.equal(diagnoseNativeStartup(replay).boundary, 'preparationCompletionUnobserved');
  assert.throws(() => assertNativePassed(replay), /Native media check failed at duplex; startup=preparationCompletionUnobserved/);
});

test('a failed preparation retains phase timings and excludes raw connection error details', () => {
  const replay = report([
    row('prepareEntered', 10), row('roomConnectRequested', 11),
    row('roomConnectFailed', 2021, { errorType: 'private error detail' }),
  ]);
  assert.deepEqual(diagnoseNativeStartup(replay), { clockID, boundary: 'preparationCompletionUnobserved', preparation: [
    { stage: 'prepareEntered', atMs: 10 }, { stage: 'roomConnectRequested', atMs: 11 },
    { stage: 'roomConnectFailed', atMs: 2021 },
  ] });
});

test('serialized receipts distinguish delivery, queue consumption and actual engine outcome', () => {
  const observations = [row('prepareCompleted', 10)];
  assert.equal(diagnoseNativeStartup(report(observations)).boundary, 'activationNeverDelivered');
  observations.push(row('activationEntered', 20));
  assert.equal(diagnoseNativeStartup(report(observations)).boundary, 'activationEnqueueUnobserved');
  observations.push(row('activationEnqueued', 30, { _0: 'enqueued' }));
  assert.equal(diagnoseNativeStartup(report(observations)).boundary, 'activationNotConsumed');
  observations.push(row('activationHandlerEntered', 40));
  assert.equal(diagnoseNativeStartup(report(observations)).boundary, 'engineOutcomeUnobserved');
  for (const [engine, boundary] of [['unavailable', 'engineNotRunning'], ['running', 'engineRunning']] as const) {
    const replay = report([...observations, row('engineAvailabilityObserved', 50, { _0: engine })]);
    assert.equal(diagnoseNativeStartup(replay).boundary, boundary);
    // Even a running-engine diagnostic cannot turn a failed media check into a pass.
    assert.throws(() => assertNativePassed(replay), /Native media check failed at duplex/);
  }
});

test('enqueue result is measured and handler entry may race the post-yield receipt', () => {
  for (const [outcome, boundary] of [['dropped', 'activationDropped'], ['terminated', 'activationStreamTerminated']] as const) {
    assert.equal(diagnoseNativeStartup(report([row('prepareCompleted', 10), row('activationEntered', 20),
      row('activationEnqueued', 30, { _0: outcome })])).boundary, boundary);
  }
  assert.equal(diagnoseNativeStartup(report([row('prepareCompleted', 10), row('activationEntered', 20),
    row('activationHandlerEntered', 21), row('activationEnqueued', 22, { _0: 'enqueued' })])).boundary, 'engineOutcomeUnobserved');
});

test('latest SDK audio events remain same-clock observations and never imply a missing command', () => {
  const replay = report([row('prepareCompleted', 10)]);
  replay.startup.lastAudioActivatedAtMs = 100;
  replay.startup.lastAudioDeactivatedAtMs = 200;
  const diagnostic = diagnoseNativeStartup(replay);
  assert.deepEqual(diagnostic, { clockID, boundary: 'activationNeverDelivered',
    lastAudioActivatedAtMs: 100, lastAudioDeactivatedAtMs: 200 });
  for (const malformed of [null, {}, { startup: {} }, { startup: { ...replay.startup, clockID: 'foreign' } },
    { startup: { ...replay.startup, observations: [row('prepareCompleted', 20), row('activationEntered', 10)] } },
    { startup: { ...replay.startup, observations: [row('prepareCompleted', 10), row('prepareCompleted', 20)] } }])
    assert.equal(diagnoseNativeStartup(malformed).boundary, 'unavailable');
  assert.doesNotThrow(() => assertNativePassed({ passed: true, startup: 'invalid' }));
});
