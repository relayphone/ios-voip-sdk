import type { ModelV1 } from './model-v1.ts';
import { validTypeFixtures } from './fixtures.types.ts';
import { wireID } from './schema.ts';

const callID = wireID('call-a');
const attemptID = wireID('media-a');
const call = validTypeFixtures.incoming.value;
const descriptor = { state: 'dialing', title: 'Calling…', body: 'Alice', lineLabel: 'Personal',
  bodyTap: { kind: 'registered', targetID: wireID('details') },
  extraActions: [{ id: wireID('openInbox'), title: 'Inbox' }] } as const;
const notice = { callID, surface: 'ongoingCallStyle', generation: 1 } as const;
const media = { callID, owner: 'native', attemptID, stage: 'prejoined', transport: 'connected',
  activation: 'inactive', capture: 'closed', output: 'closed', firstPackets: { sent: 'unknown', received: 'unknown' } } as const;
const route = { callID, intent: { kind: 'endpoint', endpointID: wireID('receiver') },
  observed: { kind: 'active', endpoint: { id: wireID('speaker'), kind: 'speaker' } } } as const;
const invitation = { callID: call.id, eventID: wireID('invite-a'), line: call.line, party: call.parties[0] };
const push = { invitation, issuedAt: '2026-11-18T00:00:00.000Z', expiresAt: '2026-11-18T00:00:45.000Z',
  credentialRef: wireID('credential-reference-a') } as const;
const registration = { kind: 'registered', installationID: wireID('installation-a'), channel: 'fcm', generation: 2,
  tokenID: wireID('token-b'), upload: { kind: 'acknowledged' } } as const;
const health = { registration, readiness: { kind: 'ready' }, connectivity: { kind: 'online' },
  delivery: { kind: 'observed', evidence: { kind: 'probeReceipt', probeID: wireID('probe-a'),
    at: '2026-11-18T00:00:02.000Z', generation: 2 } } } as const;
const timing = { stage: 'promotion', clockID: wireID('clock-a'), elapsedMicros: 250000, sequence: 8,
  correlation: { callID, actionID: wireID('answer-a'), attemptID } } as const;

export const validV1 = {
  presentation: { version: 1, kind: 'presentationDescriptor', value: descriptor },
  posted: { version: 1, kind: 'notificationObservation', value: { ...notice, kind: 'posted', descriptor, systemButtons: ['hangUp'] } },
  refusedPost: { version: 1, kind: 'notificationObservation', value: { ...notice, kind: 'refused', reason: 'systemRefused' } },
  shed: { version: 1, kind: 'notificationObservation', value: { ...notice, kind: 'shed' } },
  removed: { version: 1, kind: 'notificationObservation', value: { ...notice, kind: 'removed' } },
  prejoined: { version: 1, kind: 'mediaState', value: media },
  released: { version: 1, kind: 'mediaState', value: { ...media, stage: 'released', transport: 'disconnected' } },
  audioRoute: { version: 1, kind: 'audioRoute', value: route },
  pushEnvelope: { version: 1, kind: 'pushEnvelope', value: push },
  pushRegistration: { version: 1, kind: 'pushRegistration', value: registration },
  pushHealth: { version: 1, kind: 'pushHealth', value: health },
  pushHealthUnknown: { version: 1, kind: 'pushHealth', value: { registration, readiness: { kind: 'unknown' },
    connectivity: { kind: 'unknown' }, delivery: { kind: 'unknown', reason: 'noEvidence' } } },
  available: { version: 1, kind: 'capability', value: { callID, feature: 'hold', availability: { kind: 'available' } } },
  unavailable: { version: 1, kind: 'capability', value: { callID, feature: 'tones',
    availability: { kind: 'unavailable', reason: 'requiresMediaProvider' } } },
  timing: { version: 1, kind: 'timing', value: { ...timing, boundary: 'finished', outcome: 'succeeded' } },
} as const satisfies Readonly<Record<string, ModelV1>>;

// @ts-expect-error A registered tap needs its native target ID.
const tap: ModelV1 = { version: 1, kind: 'presentationDescriptor', value: { ...descriptor, bodyTap: { kind: 'registered' } } };
// @ts-expect-error A refused post needs a typed reason.
const refusal: ModelV1 = { version: 1, kind: 'notificationObservation', value: { ...notice, kind: 'refused' } };
// @ts-expect-error A prejoin needs an attempt identity.
const attempt: ModelV1 = { version: 1, kind: 'mediaState', value: { callID, owner: 'native', stage: 'prejoining', transport: 'connecting', activation: 'inactive', capture: 'closed', output: 'closed', firstPackets: media.firstPackets } };
// @ts-expect-error Intent cannot stand in for observed route evidence.
const endpoint: ModelV1 = { version: 1, kind: 'audioRoute', value: { callID, intent: route.intent, observed: { kind: 'active' } } };
// @ts-expect-error Every push requires an expiry.
const expiry: ModelV1 = { version: 1, kind: 'pushEnvelope', value: { invitation, issuedAt: push.issuedAt } };
// @ts-expect-error Invalidation cannot carry an upload acknowledgement.
const invalidation: ModelV1 = { version: 1, kind: 'pushRegistration', value: { kind: 'invalidated', installationID: registration.installationID, channel: 'fcm', generation: 3, upload: { kind: 'acknowledged' } } };
// @ts-expect-error Observed delivery requires evidence.
const evidence: ModelV1 = { version: 1, kind: 'pushHealth', value: { ...health, delivery: { kind: 'observed' } } };
// @ts-expect-error An unavailable capability needs a reason.
const blocker: ModelV1 = { version: 1, kind: 'capability', value: { feature: 'tones', availability: { kind: 'unavailable' } } };
// @ts-expect-error A start boundary cannot report success.
const outcome: ModelV1 = { version: 1, kind: 'timing', value: { ...timing, boundary: 'started', outcome: 'succeeded' } };
export const invalidV1 = { tap, refusal, attempt, endpoint, expiry, invalidation, evidence, blocker, outcome };
