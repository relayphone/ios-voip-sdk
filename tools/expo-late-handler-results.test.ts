import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { LateHandlerConfiguration, LateHandlerResults, LateHandlerScenario } from '../expo/example/client/journeys/late-handler.ts';
import { assertLateHandlerResults } from './expo-late-handler-results.ts';

function fixture(scenario: LateHandlerScenario = 'after-deadline') {
  const config: LateHandlerConfiguration = { schemaVersion: 1, runID: 'fixture', scenario,
    handlerAttachDelayMS: scenario === 'after-deadline' ? 28000 : scenario === 'before-deadline' ? 1000 : 11000,
    connectDeadlineMS: 27000 };
  const result: LateHandlerResults = { schemaVersion: 1, configuration: config, stage: 'complete',
    observedAtMS: 0, attachedAtMS: config.handlerAttachDelayMS, handlerInvocations: 0,
    starts: scenario === 'before-deadline' ? 1 : 0, packetsSent: 0, packetsReceived: 0,
    snapshots: scenario === 'preview-placement' ? ['previewing', 'previewing']
      : scenario === 'before-deadline' ? ['connecting', 'connected'] : ['connecting'],
    ...(scenario === 'preview-placement' ? { joinError: 'deadline_exceeded' } : {}),
  };
  const base = { runID: config.runID, pid: 42 };
  const call = { ...base, callID: 'fixture-call', callUUID: 'call-uuid' };
  const rows: { event: string; uptimeNanoseconds: number; runID: string; pid: number; callID?: string; callUUID?: string;
    kind?: string; fulfilled?: boolean; state?: string; reason?: string; generation?: number; boundarySource?: string }[] = [
    { ...base, event: 'push.registryReady', uptimeNanoseconds: 1 },
    { ...call, event: 'sdk.accept', uptimeNanoseconds: 2 },
    { ...call, event: 'sdk.state', state: 'connecting', uptimeNanoseconds: 3 },
    { ...base, callUUID: 'call-uuid', event: 'action.settled', kind: 'answer', fulfilled: true, uptimeNanoseconds: 3 },
    ...(scenario === 'after-deadline' ? [{ ...call, event: 'sdk.ended', reason: 'failed.connectTimedOut',
      uptimeNanoseconds: 27000000003 }] : []),
    ...(scenario === 'preview-placement' ? [
      { ...call, event: 'action.settled', kind: 'start', fulfilled: false, uptimeNanoseconds: 9000000003 },
      { ...call, event: 'sdk.state', state: 'previewing', uptimeNanoseconds: 9000000004 },
    ] : []),
    { ...base, event: 'app.handlerReady', generation: 1, boundarySource: 'native-handler-acknowledgement',
      uptimeNanoseconds: config.handlerAttachDelayMS * 1e6 + 4 },
    ...(scenario === 'before-deadline' ? [{ ...call, event: 'sdk.connected', state: 'connected', uptimeNanoseconds: 1000000005 }] : []),
  ];
  return { config, result, rows, journal: () => rows.map(row => JSON.stringify(row)).join('\n') };
}
for (const scenario of ['before-deadline', 'after-deadline', 'preview-placement'] as const) {
  test(`independent native and application proof: ${scenario}`, () => {
    const f = fixture(scenario); assertLateHandlerResults(f.result, f.config, f.journal());
  });
}
for (const mutation of ['missing acknowledgement', 'wrong generation', 'wrong runtime', 'wrong failure',
  'early failure', 'connected', 'positive packet', 'transport start', 'stale config', 'failed stage', 'early attachment']) {
  test(`rejects misleading completion: ${mutation}`, () => {
    const f = fixture();
    switch (mutation) {
      case 'missing acknowledgement': f.rows = f.rows.filter(row => row.event !== 'app.handlerReady'); break;
      case 'wrong generation': f.rows.find(row => row.event === 'app.handlerReady')!.generation = 2; break;
      case 'wrong runtime': f.rows.find(row => row.event === 'sdk.ended')!.runID = 'stale'; break;
      case 'wrong failure': f.rows.find(row => row.event === 'sdk.ended')!.reason = 'failed.notPlaced'; break;
      case 'early failure': f.rows.find(row => row.event === 'sdk.ended')!.uptimeNanoseconds = 26000000000; break;
      case 'connected': f.rows.push({ ...f.rows[1]!, event: 'sdk.connected' }); break;
      case 'positive packet': f.rows.push({ ...f.rows[1]!, event: 'sdk.firstPacketSent' }); break;
      case 'transport start': f.result.starts = 1; break;
      case 'stale config': f.result.configuration = { ...f.config, runID: 'stale' }; break;
      case 'failed stage': f.result.stage = 'failed'; break;
      case 'early attachment': f.result.attachedAtMS = 1000; break;
    }
    assert.throws(() => assertLateHandlerResults(f.result, f.config, f.rows.map(row => JSON.stringify(row)).join('\n')));
  });
}
