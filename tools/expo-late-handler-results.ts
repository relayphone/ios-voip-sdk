import assert from 'node:assert/strict';
import { isRecord, isString } from './json-fields.ts';
import type { LateHandlerConfiguration, LateHandlerResults } from '../expo/example/client/journeys/late-handler.ts';

/** Bounds native callback scheduling lateness; independent of the fixture's observation wait. */
export const LATE_TIMER_MARGIN_MS = 3000;

function readRow(line: string) {
  const value: unknown = JSON.parse(line);
  assert.ok(isRecord(value), 'Expected a native journal row');
  const fields = new Map<string, unknown>(Object.entries(value));
  const event = fields.get('event');
  assert.ok(isString(event), 'Missing native journal event');
  return {
    event, callID: fields.get('callID'), callUUID: fields.get('callUUID'), kind: fields.get('kind'),
    fulfilled: fields.get('fulfilled'), state: fields.get('state'), reason: fields.get('reason'),
    boundarySource: fields.get('boundarySource'), generation: fields.get('generation'),
    uptimeNanoseconds: fields.get('uptimeNanoseconds'), runID: fields.get('runID'), pid: fields.get('pid'),
  };
}

function uptime(row: ReturnType<typeof readRow>) {
  assert.ok(Number.isFinite(row.uptimeNanoseconds), `Missing uptime for ${row.event}`);
  return Number(row.uptimeNanoseconds);
}
/** Checks native evidence independently of the app's completion label and fake transport counters. */
export function assertLateHandlerResults(result: LateHandlerResults, config: LateHandlerConfiguration, journal: string) {
  assert.equal(result.schemaVersion, 1);
  assert.deepEqual(result.configuration, config, 'Stale fixture results');
  assert.equal(result.stage, 'complete', result.failure);
  assert.equal(result.failure, undefined);
  const { attachedAtMS, observedAtMS } = result;
  assert.ok(attachedAtMS !== undefined && Number.isFinite(attachedAtMS)
    && observedAtMS !== undefined && Number.isFinite(observedAtMS));
  assert.ok(attachedAtMS - observedAtMS >= config.handlerAttachDelayMS);
  assert.equal(result.handlerInvocations, 0, 'An expired preview action reached the handler');
  assert.equal(result.packetsSent, 0); assert.equal(result.packetsReceived, 0);
  assert.equal(result.starts, config.scenario === 'before-deadline' ? 1 : 0);
  assert.deepEqual(result.snapshots, config.scenario === 'preview-placement'
    ? ['previewing', 'previewing'] : config.scenario === 'before-deadline' ? ['connecting', 'connected'] : ['connecting']);
  const rows = journal.split('\n').filter(line => line.trim()).map(readRow);
  const handler = rows.filter(row => row.event === 'app.handlerReady');
  assert.equal(handler.length, 1, 'Exactly one native handler acknowledgement');
  const [ready] = handler;
  assert.ok(ready);
  assert.equal(ready.generation, 1);
  assert.equal(ready.boundarySource, 'native-handler-acknowledgement');
  assert.ok(isString(ready.runID) && ready.runID && Number.isSafeInteger(ready.pid) && Number(ready.pid) > 0);
  const readyTime = uptime(ready);
  if (config.scenario !== 'preview-placement') assert.equal(ready.runID, config.runID, 'Wrong cold-launch run');
  assert.ok(rows.some(row => row.event === 'push.registryReady'
    && row.runID === ready.runID && row.pid === ready.pid && uptime(row) < readyTime));
  assert.ok(!rows.some(row => row.event === 'diagnostic.pushReportingViolation'));
  const calls = rows.filter(row => row.callID === `${config.runID}-call`);
  assert.ok(calls.length > 0);
  assert.ok(calls.every(row => row.runID === ready.runID && row.pid === ready.pid), 'Mixed runtime identity');
  const connected = calls.filter(row => row.event === 'sdk.connected');
  if (config.scenario === 'preview-placement') {
    assert.equal(result.joinError, 'deadline_exceeded');
    const returned = calls.findLast(row => row.state === 'previewing');
    assert.ok(returned && uptime(returned) < readyTime);
    assert.ok(rows.some(row => row.event === 'action.settled' && row.kind === 'start'
      && row.fulfilled === false && row.callUUID === returned.callUUID), 'Preview Join action did not fail');
    assert.equal(calls.at(-1)?.state, 'previewing');
    assert.equal(connected.length, 0);
  } else {
    assert.equal(result.joinError, undefined);
    const accept = calls.find(row => row.event === 'sdk.accept');
    assert.ok(accept && isString(accept.callUUID) && accept.callUUID);
    assert.ok(rows.some(row => row.event === 'action.settled' && row.kind === 'answer' && row.fulfilled === true && row.callUUID === accept.callUUID));
    const connecting = calls.find(row => row.event === 'sdk.state' && row.state === 'connecting');
    assert.ok(connecting, 'Missing SDK connecting boundary');
    if (config.scenario === 'before-deadline') {
      assert.equal(connected.length, 1);
      const [connection] = connected;
      assert.ok(connection);
      const connectedAt = uptime(connection);
      assert.ok(connectedAt >= readyTime);
      assert.ok(connectedAt - uptime(connecting) < config.connectDeadlineMS * 1e6);
      assert.ok(!calls.some(row => row.event === 'sdk.ended'));
    } else {
      const ended = calls.find(row => row.event === 'sdk.ended');
      assert.ok(ended, 'Missing SDK end boundary');
      assert.equal(ended.reason, 'failed.connectTimedOut');
      const endedAt = uptime(ended);
      const connectingAt = uptime(connecting);
      const elapsedNS = endedAt - connectingAt;
      const timing = `lateness ${(elapsedNS / 1e6 - config.connectDeadlineMS).toFixed(3)} ms, limit ${LATE_TIMER_MARGIN_MS} ms; `
        + `handler acknowledgement ${((readyTime - endedAt) / 1e6).toFixed(3)} ms after timeout, `
        + `${((readyTime - connectingAt) / 1e6).toFixed(3)} ms after connecting`;
      assert.ok(elapsedNS >= config.connectDeadlineMS * 1e6, `Connection timeout fired before its deadline (${timing})`);
      assert.ok(elapsedNS <= (config.connectDeadlineMS + LATE_TIMER_MARGIN_MS) * 1e6,
        `Connection timeout callback exceeded its lateness margin (${timing})`);
      assert.ok(readyTime > endedAt, `Handler attached before failure (${timing})`);
      assert.equal(connected.length, 0);
    }
  }
  assert.ok(!calls.some(row => /firstPacket/i.test(row.event)), 'Unexpected positive packet observation');
}
