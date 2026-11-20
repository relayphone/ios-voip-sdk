import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { isRecord } from '../json-fields.ts';
import type { CallError, WireID } from './model.ts';
import { decodeHTTPAuthority, type HTTPAuthorityRequest } from './http-authority.ts';
import { features } from './model-v1.ts';
import type { CapabilityCatalog, ExpectationV1, InputV1, JourneyV1, ModelV1, NotificationSurface, PresentationDescriptor, SystemButton } from './model-v1.ts';
import { validatePushEnvelope, validatePushHealth } from './push-v1.ts';
import type { JourneyDriver, Observation } from './runner.ts';
import { check, loadCatalog, runSteps } from './runner.ts';
import { decodeModel, validateBudgets, validateV1 } from './schema.ts';

const systemButtons: Partial<Record<NotificationSurface, readonly SystemButton[]>> = {
  incomingCallStyle: ['answer', 'decline'], ongoingCallStyle: ['hangUp'], serviceFallback: ['hangUp'],
};

function checkDescriptor(descriptor: PresentationDescriptor) {
  const ids = descriptor.extraActions.map(action => action.id);
  if (new Set(ids).size !== ids.length || ids.some(id => ['answer', 'decline', 'hangUp'].includes(id))) {
    throw new Error('Extra actions must be distinct and cannot replace system buttons');
  }
}

export function decodeModelV1(value: unknown) {
  validateV1(value);
  // SAFETY: The version-1 model schema checks the discriminant and every variant before cloning.
  const model = structuredClone(value) as ModelV1;
  switch (model.kind) {
    case 'presentationDescriptor': checkDescriptor(model.value); break;
    case 'notificationObservation': {
      const observation = model.value;
      if (observation.kind !== 'posted') break;
      checkDescriptor(observation.descriptor);
      const required = systemButtons[observation.surface];
      const observed = new Set(observation.systemButtons);
      if (observed.size !== observation.systemButtons.length ||
          required && (observed.size !== required.length || required.some(button => !observed.has(button)))) {
        throw new Error('Posted notification lacks its required system controls or repeats a button');
      }
      break;
    }
    case 'mediaState': {
      const { stage, owner, activation, capture, output, transport, firstPackets } = model.value;
      if ((capture === 'open' || output === 'open') && (stage !== 'prepared' || activation !== 'active')) {
        throw new Error('Open media gates require both preparation and observed activation');
      }
      if (stage === 'prejoining' || stage === 'prejoined' || stage === 'promoting') {
        if (owner !== 'native' || firstPackets.sent !== 'unknown' || firstPackets.received !== 'unknown') {
          throw new Error('Prejoin requires native ownership and has no participating packet evidence');
        }
      }
      if (stage === 'released' && (transport !== 'disconnected' || activation === 'active')) {
        throw new Error('Released media cannot remain connected or active');
      }
      break;
    }
    case 'pushEnvelope': validatePushEnvelope(model.value); break;
    case 'pushHealth': validatePushHealth(model.value); break;
    case 'timing': {
      const { stage, correlation } = model.value;
      if (['claim', 'reconciliation', 'placement', 'promotion'].includes(stage) && (!correlation.callID || !correlation.actionID)) {
        throw new Error('Action timing requires call and action identifiers');
      }
      if (['mediaPreparation', 'prejoin', 'promotion', 'firstSentPacket', 'firstReceivedPacket'].includes(stage) &&
          (!correlation.callID || !correlation.attemptID)) {
        throw new Error('Media timing requires call and attempt identifiers');
      }
      break;
    }
  }
  return model;
}

/** Dispatches on the explicit document version. The version 0 and 1 readers keep their own rules. */
export function decodeVersionedModel(value: unknown) {
  if (isRecord(value) && 'version' in value && value.version === 1) return decodeModelV1(value);
  return decodeModel(value);
}

export function decodeCapabilityCatalog(value: unknown) {
  validateV1(value, 'capabilities');
  // SAFETY: The capabilities definition checks every feature and platform condition.
  const catalog = structuredClone(value) as CapabilityCatalog;
  const keys = catalog.features.map(row => row.feature).sort();
  assert.deepEqual(keys, [...features].sort(), 'Every feature needs exactly one platform condition entry');
  for (const { feature, ios, android } of catalog.features) {
    if (ios.length !== 1) throw new Error(`Overlapping iOS conditions for ${feature}`);
    for (const [i, condition] of android.entries()) {
      const min = condition.minApi ?? 26;
      const max = condition.maxApi ?? Infinity;
      if (min < 26 || max < min) throw new Error(`Invalid Android API range for ${feature}`);
      for (const other of android.slice(0, i)) {
        const sharedBackend = !condition.backend || !other.backend || condition.backend === other.backend;
        if (sharedBackend && (other.minApi ?? 26) <= max && min <= (other.maxApi ?? Infinity)) {
          throw new Error(`Overlapping Android conditions for ${feature}`);
        }
      }
    }
  }
  return catalog;
}

export function decodeJourneyV1(value: unknown) {
  validateV1(value, 'journey');
  // SAFETY: The version-1 journey definition checks the configuration and each step.
  const journey = structuredClone(value) as JourneyV1;
  validateBudgets(journey.configuration.budgets);
  if (!journey.steps.some(step => step.kind === 'expect')) throw new Error('Journey has no assertions');
  for (const step of journey.steps) {
    if (step.kind === 'input' && step.input.kind === 'presentation') checkDescriptor(step.input.descriptor);
    if (step.kind === 'input' && step.input.kind === 'httpReply') decodeHTTPAuthority(step.input.response);
    if (step.kind === 'expect' && step.expectation.kind === 'record') decodeModelV1(step.expectation.record);
    if (step.kind === 'expect' && step.expectation.kind === 'httpRequests') {
      const { callID, requests } = step.expectation;
      for (const request of requests) {
        decodeHTTPAuthority(request);
        if (request.body.callID !== callID) throw new Error('HTTP request must match the expected call');
      }
    }
  }
  return journey;
}

type ObservationV1 = Observation & Readonly<{
  records: readonly ModelV1[];
  actionErrors: readonly Readonly<{ callID: WireID; error: CallError }>[];
  cleanup: readonly Readonly<{ callID: WireID; outcome: 'removed' | 'failed' }>[];
  httpRequests?: readonly HTTPAuthorityRequest[];
}>;
export type JourneyDriverV1 = JourneyDriver<InputV1, ObservationV1>;

function recordKey(record: ModelV1) {
  switch (record.kind) {
    case 'presentationDescriptor': return [record.kind, record.value.state];
    case 'notificationObservation': return [
      record.kind, record.value.callID, record.value.surface,
      record.value.kind === 'refused' ? 'postRefusal' : 'visibility',
    ];
    case 'mediaState': case 'audioRoute': return [record.kind, record.value.callID];
    case 'pushEnvelope': return [record.kind, record.value.invitation.eventID];
    case 'pushRegistration': return [record.kind, record.value.installationID, record.value.channel];
    case 'pushHealth': return [record.kind, record.value.registration.installationID, record.value.registration.channel];
    case 'capability': return [record.kind, record.value.feature, record.value.callID ?? ''];
    case 'timing': return [record.kind, record.value.clockID, record.value.sequence];
  }
}

export function checkV1(expected: ExpectationV1, observed: ObservationV1) {
  switch (expected.kind) {
    case 'httpRequests': {
      assert.ok(observed.httpRequests, 'Missing HTTP Answer request evidence');
      const requests = observed.httpRequests.map(request => {
        const message = decodeHTTPAuthority(request);
        assert.ok(message.kind === 'request', 'Expected an HTTP request');
        return message;
      }).filter(request => request.body.callID === expected.callID);
      assert.deepEqual(requests, expected.requests);
      break;
    }
    case 'record': {
      const key = JSON.stringify(recordKey(expected.record));
      const matches = observed.records.filter(record => JSON.stringify(recordKey(record)) === key);
      assert.equal(matches.length, 1, `Expected one current observation for ${key}`);
      assert.deepEqual(decodeModelV1(matches[0]), expected.record);
      break;
    }
    case 'actionError': {
      const latest = observed.actionErrors.findLast(row => row.callID === expected.callID);
      assert.ok(latest, 'Missing action error');
      assert.deepEqual(latest.error, expected.error);
      break;
    }
    case 'cleanup': {
      const latest = observed.cleanup.findLast(row => row.callID === expected.callID);
      assert.equal(latest?.outcome, expected.outcome, 'Missing cleanup completion matched to its owner');
      break;
    }
    case 'callAbsent': assert.ok(!observed.calls.some(call => call.id === expected.callID), 'Call still retained'); break;
    default: check(expected, observed);
  }
}

export function runJourneyV1(journey: JourneyV1, driver: JourneyDriverV1) {
  return runSteps(journey, driver, checkV1);
}

export function loadCatalogV1(root = new URL('../../spec/', import.meta.url)) {
  decodeCapabilityCatalog(JSON.parse(readFileSync(new URL('capabilities.json', root), 'utf8')));
  const directory = new URL('v1/journeys/', root);
  const journeys = readdirSync(directory).filter(name => name.endsWith('.json')).sort()
    .map(name => decodeJourneyV1(JSON.parse(readFileSync(new URL(name, directory), 'utf8'))));
  if (!journeys.length || new Set(journeys.map(journey => journey.id)).size !== journeys.length) throw new Error('Empty or duplicate v1 journey catalog');
  return journeys;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const v0 = loadCatalog();
  const v1 = loadCatalogV1();
  console.log(`Validated ${v0.length} version-0 and ${v1.length} version-1 journeys. Execution requires native drivers.`);
}
