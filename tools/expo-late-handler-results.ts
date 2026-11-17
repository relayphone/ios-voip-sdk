import assert from 'node:assert/strict';
import type { LateHandlerConfiguration, LateHandlerResults } from '../expo/example/client/journeys/late-handler.ts';

interface Row {
  event: string; callID?: string; callUUID?: string; kind?: string; fulfilled?: boolean; state?: string;
  reason?: string; boundarySource?: string; generation?: number; uptimeNanoseconds: number;
  runID: string; pid: number;
}
/** Checks native evidence independently of the app's completion label and fake transport counters. */
export function assertLateHandlerResults(result: LateHandlerResults, config: LateHandlerConfiguration, journal: string): void {
  assert.equal(result.schemaVersion, 1);
  assert.deepEqual(result.configuration, config, 'Stale fixture results');
  assert.equal(result.stage, 'complete', result.failure);
  assert.equal(result.failure, undefined);
  assert.ok(Number.isFinite(result.observedAtMS) && Number.isFinite(result.attachedAtMS));
  assert.ok(result.attachedAtMS! - result.observedAtMS! >= config.handlerAttachDelayMS);
  assert.equal(result.handlerInvocations, 0, 'An expired preview action reached the handler');
  assert.equal(result.packetsSent, 0); assert.equal(result.packetsReceived, 0);
  assert.equal(result.starts, config.scenario === 'before-deadline' ? 1 : 0);
  assert.deepEqual(result.snapshots, config.scenario === 'preview-placement'
    ? ['previewing', 'previewing'] : config.scenario === 'before-deadline' ? ['connecting', 'connected'] : ['connecting']);
  const rows = journal.split('\n').filter(line => line.trim()).map(line => JSON.parse(line) as Row);
  const handler = rows.filter(row => row.event === 'app.handlerReady');
  assert.equal(handler.length, 1, 'Exactly one native handler acknowledgement');
  assert.equal(handler[0]!.generation, 1);
  assert.equal(handler[0]!.boundarySource, 'native-handler-acknowledgement');
  const ready = handler[0]!;
  if (config.scenario !== 'preview-placement') assert.equal(ready.runID, config.runID, 'Wrong cold-launch run');
  assert.ok(rows.some(row => row.event === 'push.registryReady'
    && row.runID === ready.runID && row.pid === ready.pid && row.uptimeNanoseconds < ready.uptimeNanoseconds));
  assert.ok(!rows.some(row => row.event === 'diagnostic.pushReportingViolation'));
  const calls = rows.filter(row => row.callID === `${config.runID}-call`);
  assert.ok(calls.length > 0);
  assert.ok(calls.every(row => row.runID === ready.runID && row.pid === ready.pid), 'Mixed runtime identity');
  const connected = calls.filter(row => row.event === 'sdk.connected');
  if (config.scenario === 'preview-placement') {
    assert.equal(result.joinError, 'deadline_exceeded');
    const returned = calls.findLast(row => row.state === 'previewing');
    assert.ok(returned && returned.uptimeNanoseconds < ready.uptimeNanoseconds);
    assert.ok(rows.some(row => row.event === 'action.settled' && row.kind === 'start'
      && row.fulfilled === false && row.callUUID === returned.callUUID), 'Preview Join action did not fail');
    assert.equal(calls.at(-1)!.state, 'previewing');
    assert.equal(connected.length, 0);
  } else {
    assert.equal(result.joinError, undefined);
    const accept = calls.find(row => row.event === 'sdk.accept');
    assert.ok(accept?.callUUID);
    assert.ok(rows.some(row => row.event === 'action.settled' && row.kind === 'answer' && row.fulfilled === true && row.callUUID === accept.callUUID));
    const connecting = calls.find(row => row.event === 'sdk.state' && row.state === 'connecting');
    assert.ok(connecting, 'Missing SDK connecting boundary');
    if (config.scenario === 'before-deadline') {
      assert.equal(connected.length, 1);
      assert.ok(connected[0]!.uptimeNanoseconds >= ready.uptimeNanoseconds);
      assert.ok(connected[0]!.uptimeNanoseconds - connecting.uptimeNanoseconds < config.connectDeadlineMS * 1e6);
      assert.ok(!calls.some(row => row.event === 'sdk.ended'));
    } else {
      const ended = calls.find(row => row.event === 'sdk.ended');
      assert.equal(ended?.reason, 'failed.connectTimedOut');
      assert.ok(ended!.uptimeNanoseconds - connecting.uptimeNanoseconds >= config.connectDeadlineMS * 1e6);
      assert.ok(ready.uptimeNanoseconds > ended!.uptimeNanoseconds, 'Handler attached before failure');
      assert.equal(connected.length, 0);
    }
  }
  assert.ok(!calls.some(row => /firstPacket/i.test(row.event)), 'Unexpected positive packet observation');
}
