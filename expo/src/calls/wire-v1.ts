import { array, id, integer, literal, object, optional, refine, text, timestamp, union } from './decode.ts';
import type { Decoded, Decoder } from './decode.ts';
import { invitation, lifecycleKind } from './wire-v0.ts';

const callID = id<'call'>();
const attemptID = id<'attempt'>();
const eventID = id<'event'>();
const generation = integer(1);
const title = text(1, 256);

const systemButton = literal('answer', 'decline', 'hangUp');
const reservedActions = new Set<string>(['answer', 'decline', 'hangUp']);
const presentationDescriptor = refine(object({
  state: union(lifecycleKind, literal('authorizing', 'held', 'missed')),
  title,
  body: text(0, 512),
  lineLabel: title,
  bodyTap: union(
    object({ kind: literal('openApp', 'openCall') }),
    object({ kind: literal('registered'), targetID: id<'tapTarget'>() }),
  ),
  extraActions: array(object({ id: id<'notificationAction'>(), title })),
}), ({ extraActions }) => {
  const ids = extraActions.map(action => action.id);
  return new Set(ids).size === ids.length && ids.every(id => !reservedActions.has(id));
}, 'Extra actions must be distinct and cannot replace system buttons');

const surface = literal('incomingCallStyle', 'ongoingCallStyle', 'serviceFallback', 'sdkNotification', 'preview');
const notificationFields = { callID, surface, generation };
const requiredButtons: Partial<Record<Decoded<typeof surface>, readonly Decoded<typeof systemButton>[]>> = {
  incomingCallStyle: ['answer', 'decline'],
  ongoingCallStyle: ['hangUp'],
  serviceFallback: ['hangUp'],
};
const notificationObservation = union(
  refine(object({
    ...notificationFields, kind: literal('posted'), descriptor: presentationDescriptor, systemButtons: array(systemButton),
  }), ({ surface, systemButtons }) => {
    const observed = new Set(systemButtons);
    const required = requiredButtons[surface];
    return observed.size === systemButtons.length &&
      (!required || observed.size === required.length && required.every(button => observed.has(button)));
  }, 'A posted notification must have distinct, surface-appropriate controls'),
  object({ ...notificationFields, kind: literal('refused'), reason: literal('permission', 'ineligible', 'systemRefused') }),
  object({ ...notificationFields, kind: literal('shed', 'removed') }),
);

const packetEvidence = literal('unknown', 'observed');
const gate = literal('closed', 'open');
const mediaFields = {
  callID, owner: literal('native', 'application'),
  transport: literal('unknown', 'disconnected', 'connecting', 'connected', 'reconnecting'),
  activation: literal('unknown', 'inactive', 'active'),
  capture: gate, output: gate, firstPackets: object({ sent: packetEvidence, received: packetEvidence }),
};
export const mediaState = refine(union(
  object({ ...mediaFields, stage: literal('unprovided') }),
  object({ ...mediaFields, stage: literal('prejoining', 'prejoined', 'promoting', 'preparing', 'prepared', 'releasing', 'released'), attemptID }),
), ({ stage, owner, transport, activation, capture, output, firstPackets }) => {
  if ((capture === 'open' || output === 'open') && (stage !== 'prepared' || activation !== 'active')) return false;
  if (stage === 'prejoining' || stage === 'prejoined' || stage === 'promoting') {
    return owner === 'native' && firstPackets.sent === 'unknown' && firstPackets.received === 'unknown';
  }
  return stage !== 'released' || transport === 'disconnected' && activation !== 'active';
}, 'Media evidence conflicts with the observed stage');

const endpointID = id<'audioEndpoint'>();
const audioRoute = object({
  callID,
  intent: union(object({ kind: literal('automatic') }), object({ kind: literal('endpoint'), endpointID })),
  observed: union(
    object({ kind: literal('unknown', 'unavailable') }),
    object({
      kind: literal('active'),
      endpoint: object({ id: endpointID, kind: literal('earpiece', 'speaker', 'wired', 'bluetooth', 'other') }),
    }),
  ),
});

const feature = literal(
  'hold', 'video', 'tones', 'preview', 'merge', 'prejoin', 'nativeAnswerAuthority', 'audioRoutes', 'push',
  'customPresentation', 'fullScreenIncoming', 'systemVideoUpgrade', 'systemVideoDowngrade', 'focusFiltering',
  'liveActivities', 'systemDialIntent',
);
export const capability = object({
  feature, callID: optional(callID),
  availability: union(
    object({ kind: literal('available') }),
    object({
      kind: literal('unavailable'),
      reason: literal('notImplemented', 'unsupportedPlatform', 'requiresSystemVersion', 'requiresTransactional',
        'requiresMediaProvider', 'requiresPermission', 'disabledByPolicy', 'unqualified', 'unknown'),
    }),
  ),
});

const pushEnvelope = refine(object({
  invitation, issuedAt: timestamp, expiresAt: timestamp, credentialRef: optional(id<'credential'>()),
}), ({ issuedAt, expiresAt }) => Date.parse(issuedAt) < Date.parse(expiresAt), 'Invalid push expiry interval');
const registrationFields = { installationID: id<'installation'>(), channel: literal('apnsVoip', 'fcm'), generation };
const registered = object({
  ...registrationFields, kind: literal('registered'), tokenID: id<'pushToken'>(),
  upload: union(
    object({ kind: literal('pending', 'acknowledged') }),
    object({ kind: literal('failed'), reason: literal('offline', 'serviceRejected', 'unknown') }),
  ),
});
const unregistered = union(
  object({ ...registrationFields, kind: literal('registering', 'invalidated') }),
  object({ ...registrationFields, kind: literal('failed'), reason: literal('tokenUnavailable', 'permissionDenied', 'unknown') }),
);
const pushRegistration = union(registered, unregistered);
const healthFields = {
  readiness: union(
    object({ kind: literal('ready', 'unknown') }),
    object({ kind: literal('blocked'), reason: literal('notificationsDisabled', 'systemUnavailable') }),
  ),
  connectivity: object({ kind: literal('online', 'offline', 'unknown') }),
};
const unknownDelivery = object({ kind: literal('unknown'), reason: literal('noEvidence', 'missingProbe', 'staleEvidence', 'generationUnknown') });
const receipt = { at: timestamp, generation };
const probe = { ...receipt, probeID: id<'probe'>() };
export const pushHealth = union(
  object({ ...healthFields, registration: unregistered, delivery: unknownDelivery }),
  refine(object({
    ...healthFields, registration: registered,
    delivery: union(
      unknownDelivery,
      object({
        kind: literal('observed'), evidence: union(
          object({ ...receipt, kind: literal('deviceReceipt'), eventID }),
          object({ ...probe, kind: literal('probeReceipt') }),
        ),
      }),
      object({ kind: literal('degraded'), evidence: object({ ...probe, kind: literal('probeTimedOut') }) }),
    ),
  }), ({ registration, delivery }) => delivery.kind === 'unknown' || delivery.evidence.generation === registration.generation,
  'Push evidence must match the current registered generation'),
);

const timingFields = {
  stage: literal('pushIntake', 'decode', 'admission', 'notification', 'uiResume', 'claim', 'reconciliation',
    'placement', 'mediaPreparation', 'prejoin', 'promotion', 'audioEligibility', 'activation', 'connection',
    'firstSentPacket', 'firstReceivedPacket', 'teardown', 'jsDelivery'),
  clockID: id<'clock'>(), elapsedMicros: integer(0), sequence: integer(0),
  correlation: object({
    eventID: optional(eventID), callID: optional(callID), actionID: optional(id<'action'>()), attemptID: optional(attemptID),
  }),
};
const actionTiming = new Set<string>(['claim', 'reconciliation', 'placement', 'promotion']);
const mediaTiming = new Set<string>(['mediaPreparation', 'prejoin', 'promotion', 'firstSentPacket', 'firstReceivedPacket']);
const timing = refine(union(
  object({ ...timingFields, boundary: literal('started'), outcome: literal('pending') }),
  object({ ...timingFields, boundary: literal('finished'), outcome: literal('succeeded', 'failed', 'refused', 'timedOut', 'cancelled', 'unknown') }),
  object({ ...timingFields, boundary: literal('observed'), outcome: literal('observed') }),
), ({ stage, correlation }) => {
  if (actionTiming.has(stage) && (!correlation.callID || !correlation.actionID)) return false;
  return !mediaTiming.has(stage) || Boolean(correlation.callID && correlation.attemptID);
}, 'Timing is missing required correlation');

function envelope<Kind extends string, Value>(kind: Kind, value: Decoder<Value>) {
  return object({ version: literal(1), kind: literal(kind), value });
}
export const wireV1 = union(
  envelope('presentationDescriptor', presentationDescriptor),
  envelope('notificationObservation', notificationObservation),
  envelope('mediaState', mediaState), envelope('audioRoute', audioRoute),
  envelope('pushEnvelope', pushEnvelope), envelope('pushRegistration', pushRegistration), envelope('pushHealth', pushHealth),
  envelope('capability', capability), envelope('timing', timing),
);

export type Feature = Decoded<typeof feature>;
export type Capability = Decoded<typeof capability>;
export type MediaObservation = Decoded<typeof mediaState>;
export type PushHealth = Decoded<typeof pushHealth>;
export type WireV1 = Decoded<typeof wireV1>;
