import type { Model } from './model.ts';
import { wireID } from './schema.ts';
const line = { accountID: wireID('account-a'), id: wireID('personal'), label: 'Personal' } as const;
const party = { id: wireID('alice'), handle: { kind: 'opaque', value: 'sip:alice@example.test' }, displayName: 'Alice' } as const;
const media = { owner: 'native', preparation: 'unprovided', audio: 'inactive', transport: 'disconnected' } as const;
const call = { id: wireID('call-α'), line, direction: 'incoming', parties: [party], lifecycle: { kind: 'ringing' }, held: false, muted: false, video: false, media } as const;
const budgets = { answer: { total: 4500, claim: 2500, reconciliation: 500, settlementReserve: 500 }, placement: 10000,
  incomingRing: 45000, outgoingNoAnswer: 45000, mediaPreparation: 5000, audioActivation: 10000, audioRecovery: 5000, connection: 30000, reconnection: 15000 } as const;
/** Runtime tests compare these literal type witnesses with every on-disk fixture. */
export const validTypeFixtures = {
  incoming: { version: 0, kind: 'call', value: call },
  connected: { version: 0, kind: 'call', value: { ...call, lifecycle: { kind: 'connected', connectedAt: '2026-11-17T00:00:00.000Z' }, media: { owner: 'native', preparation: 'prepared', audio: 'active', transport: 'connected' } } },
  deferred: { version: 0, kind: 'call', value: { ...call, id: wireID('outgoing-a'), direction: 'outgoing', remoteID: wireID('remote-a'), lifecycle: { kind: 'dialing' } } },
  failed: { version: 0, kind: 'endReason', value: { kind: 'failed', error: { kind: 'claimTimedOut', actionID: wireID('answer-a') } } },
  answer: { version: 0, kind: 'action', value: { kind: 'answer', callID: wireID('call-α') } },
  opaque: { version: 0, kind: 'action', value: { kind: 'start', callID: wireID('short-code'), line, party: { ...party, handle: { kind: 'opaque', value: '123' } } } },
  budgets: { version: 0, kind: 'budgets', value: budgets },
  refused: { version: 0, kind: 'error', value: { kind: 'refused', reason: { kind: 'answeredElsewhere' } } },
  elsewhere: { version: 0, kind: 'endReason', value: { kind: 'answeredElsewhere' } },
  notAllowed: { version: 0, kind: 'endReason', value: { kind: 'failed', error: { kind: 'refused', reason: { kind: 'notAllowed' } } } },
} as const satisfies Readonly<Record<string, Model>>;
// @ts-expect-error Only version 0 is accepted.
const version: Model = { version: 1, kind: 'action', value: { kind: 'answer', callID: wireID('call-α') } };
// @ts-expect-error Hold is a gate, not a lifecycle.
const state: Model = { version: 0, kind: 'call', value: { ...call, lifecycle: { kind: 'held' } } };
// @ts-expect-error A call requires at least one party.
const parties: Model = { version: 0, kind: 'call', value: { ...call, parties: [] } };
// @ts-expect-error Answer has no video payload.
const action: Model = { version: 0, kind: 'action', value: { kind: 'answer', callID: wireID('call-a'), enabled: true } };
// @ts-expect-error A failed end requires a typed cause.
const failed: Model = { version: 0, kind: 'endReason', value: { kind: 'failed' } };
// @ts-expect-error Durations are numbers, not numeric strings.
const budget: Model = { version: 0, kind: 'budgets', value: { ...budgets, answer: { ...budgets.answer, claim: '2500' } } };
// @ts-expect-error Unknown reason codes do not enter the model.
const reason: Model = { version: 0, kind: 'endReason', value: { kind: 'CALL_FAILED' } };
// @ts-expect-error Refusal is a discriminated record.
const refused: Model = { version: 0, kind: 'error', value: { kind: 'refused', reason: 'notAllowed' } };
// @ts-expect-error DTMF requires at least one digit.
const tones: Model = { version: 0, kind: 'action', value: { kind: 'tones', callID: wireID('call-a'), digits: [] } };
// @ts-expect-error An unchecked whitespace-padded string is not a validated wire identifier.
const paddedID: Model = { version: 0, kind: 'action', value: { kind: 'answer', callID: 'call-a ' } };
// @ts-expect-error Leading whitespace cannot enter a validated wire identifier.
const leadingID: Model = { version: 0, kind: 'action', value: { kind: 'answer', callID: ' call-a' } };
// @ts-expect-error Control characters cannot enter a validated wire identifier.
const controlID: Model = { version: 0, kind: 'action', value: { kind: 'answer', callID: 'call\u0000a' } };
// @ts-expect-error Elsewhere ownership has one canonical end reason, not a failed-refusal encoding.
const answeredRefusal: Model = { version: 0, kind: 'endReason', value: { kind: 'failed', error: { kind: 'refused', reason: { kind: 'answeredElsewhere' } } } };
// @ts-expect-error Declined-elsewhere ownership also has one canonical end reason.
const declinedRefusal: Model = { version: 0, kind: 'endReason', value: { kind: 'failed', error: { kind: 'refused', reason: { kind: 'declinedElsewhere' } } } };
export const invalidTypeFixtures = { version, state, parties, action, failed, budget, reason, refused, tones, paddedID, leadingID, controlID, answeredRefusal, declinedRefusal };
