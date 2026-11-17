import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import type { Call, Configuration, EndResult, ErrorExpectation, Expectation, Guard, Input, Journey, Metric, State, Transitions, Trigger, WireID } from './model.ts';
import { decodeJourney, decodeModel, decodeTransitions } from './schema.ts';

export type Observation = Readonly<{ calls: readonly Call[]; participating: readonly WireID[];
  counts: readonly Readonly<{ callID: WireID; metric: Metric; value: number }>[];
  systemEnds: readonly Readonly<{ callID: WireID; cause: 'local' | 'remote' | 'missed' | 'rejected' }>[];
  endResults?: readonly Readonly<{ callID: WireID; result: EndResult }>[];
  errors: readonly (Readonly<{ callID: WireID }> & ErrorExpectation)[] }>;
/** Drivers perform real controls and await native completion; they never receive expected results. */
export interface JourneyDriver {
  reset(configuration: Configuration): Promise<void>;
  apply(input: Input): Promise<void>;
  observe(): Promise<Observation>;
  close(): Promise<void>;
}
/** Selects a declared rule; computing guards and executing effects remain native engine work. */
export function selectTransition(table: Transitions, state: State | 'absent', input: Trigger, satisfied: ReadonlySet<Guard>) {
  return table.rules.find(rule => rule.from.includes(state) && rule.input === input && satisfied.has(rule.guard));
}
export function check(expected: Expectation, observed: Observation): void {
  switch (expected.kind) {
    case 'call': {
      const call = observed.calls.find(call => call.id === expected.callID);
      assert.ok(call, `Missing call ${expected.callID}`);
      decodeModel({ version: 0, kind: 'call', value: call });
      assert.equal(call.lifecycle.kind, expected.lifecycle.kind);
      if ('reason' in expected.lifecycle) {
        assert.ok('reason' in call.lifecycle);
        const reason = expected.lifecycle.reason;
        if (reason.kind === 'failed') {
          assert.equal(call.lifecycle.reason.kind, 'failed');
          assert.ok('error' in call.lifecycle.reason);
          assert.equal(call.lifecycle.reason.error.kind, reason.error);
        } else assert.deepEqual(call.lifecycle.reason, reason);
      }
      if (expected.lineID !== undefined) assert.equal(call.line.id, expected.lineID);
      for (const key of ['remoteID', 'held', 'muted'] as const) if (key in expected) assert.equal(call[key], expected[key]);
      break;
    }
    case 'count': {
      const matching = observed.counts.filter(row => row.callID === expected.callID && row.metric === expected.metric);
      assert.equal(matching.length, 1, 'Counter must be observed exactly once, including zero');
      assert.equal(matching[0]?.value, expected.value);
      break;
    }
    case 'participating': assert.deepEqual([...observed.participating].sort(), [...expected.callIDs].sort()); break;
    case 'systemEnd': assert.ok(observed.systemEnds.some(row => row.callID === expected.callID && row.cause === expected.cause), 'Missing system end observation'); break;
    case 'endResult': {
      const latest = observed.endResults?.findLast(row => row.callID === expected.callID);
      assert.ok(latest, `Missing End result for ${expected.callID}`);
      decodeModel({ version: 0, kind: 'endResult', value: latest.result });
      assert.deepEqual(latest.result, expected.result);
      break;
    }
    case 'error': assert.ok(observed.errors.some(row => row.callID === expected.callID && row.error === expected.error
      && (expected.error !== 'refused' || expected.reason === undefined || row.error === 'refused' && row.reason?.kind === expected.reason.kind)), 'Missing typed error'); break;
  }
}
/** Executes an already decoded journey. Assertions never mutate the driver or infer missing evidence. */
export async function runJourney(journey: Journey, driver: JourneyDriver): Promise<void> {
  let failure: { error: unknown } | undefined;
  try {
    await driver.reset(journey.configuration);
    for (const step of journey.steps) {
      if (step.kind === 'input') await driver.apply(step.input);
      else check(step.expectation, await driver.observe());
    }
  } catch (error) { failure = { error }; }
  try { await driver.close(); }
  catch (error) {
    if (failure) throw new AggregateError([failure.error, error], 'Journey and cleanup failed');
    throw error;
  }
  if (failure) throw failure.error;
}
export function loadCatalog(root = new URL('../../spec/', import.meta.url)): readonly Journey[] {
  decodeTransitions(JSON.parse(readFileSync(new URL('transitions.json', root), 'utf8')));
  const directory = new URL('journeys/', root);
  const journeys = readdirSync(directory).filter(name => name.endsWith('.json')).sort()
    .map(name => decodeJourney(JSON.parse(readFileSync(new URL(name, directory), 'utf8'))));
  if (!journeys.length || new Set(journeys.map(journey => journey.id)).size !== journeys.length) throw new Error('Empty or duplicate journey catalog');
  return journeys;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const journeys = loadCatalog();
  console.log(`Validated ${journeys.length} version-0 journeys. Execution requires a JourneyDriver; no platform conformance was run.`);
}
