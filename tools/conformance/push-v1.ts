import type { Invitation, WireID } from './model.ts';

export type PushChannel = 'apnsVoip' | 'fcm';
export type PushEnvelope = Readonly<{
  invitation: Invitation;
  issuedAt: string;
  expiresAt: string;
  credentialRef?: WireID;
}>;

type RegistrationScope = Readonly<{ installationID: WireID; channel: PushChannel }>;
type UploadResult = { readonly kind: 'acknowledged' | 'stale' }
  | { readonly kind: 'failed'; readonly reason: 'offline' | 'serviceRejected' | 'unknown' };
type UploadState = { readonly kind: 'pending' | 'acknowledged' }
  | Extract<UploadResult, { readonly kind: 'failed' }>;
export type PushRegistration = RegistrationScope & { readonly generation: number } & (
  | { readonly kind: 'registering' | 'invalidated' }
  | { readonly kind: 'registered'; readonly tokenID: WireID; readonly upload: UploadState }
  | { readonly kind: 'failed'; readonly reason: 'tokenUnavailable' | 'permissionDenied' | 'unknown' }
);

type ProbeEvidence = Readonly<{ probeID: WireID; at: string; generation: number }>;
type ReceiptEvidence = { readonly kind: 'deviceReceipt'; readonly eventID: WireID; readonly at: string; readonly generation: number }
  | (ProbeEvidence & { readonly kind: 'probeReceipt' });
export type PushHealth = Readonly<{
  registration: PushRegistration;
  readiness: { readonly kind: 'ready' | 'unknown' }
    | { readonly kind: 'blocked'; readonly reason: 'notificationsDisabled' | 'systemUnavailable' };
  connectivity: { readonly kind: 'online' | 'offline' | 'unknown' };
  delivery: { readonly kind: 'unknown'; readonly reason: 'noEvidence' | 'missingProbe' | 'staleEvidence' | 'generationUnknown' }
    | { readonly kind: 'observed'; readonly evidence: ReceiptEvidence }
    | { readonly kind: 'degraded'; readonly evidence: ProbeEvidence & { readonly kind: 'probeTimedOut' } };
}>;

export type PushInput = RegistrationScope & (
  | { readonly kind: 'pushTokenChanged'; readonly tokenID: WireID }
  | { readonly kind: 'pushUploadCompleted'; readonly generation: number; readonly tokenID: WireID; readonly result: UploadResult }
);

function parseTimestamp(value: string) {
  const time = Date.parse(value);
  if (!Number.isFinite(time) || new Date(time).toISOString() !== value) {
    throw new Error('Invalid push timestamp');
  }
  return time;
}

/** Checks temporal constraints after structural decoding. A supplied receipt time also checks intake eligibility. */
export function validatePushEnvelope(value: PushEnvelope, receivedAt?: string) {
  const issued = parseTimestamp(value.issuedAt);
  const expiry = parseTimestamp(value.expiresAt);
  if (issued >= expiry) throw new Error('Invalid push expiry interval');
  if (receivedAt !== undefined) {
    const received = parseTimestamp(receivedAt);
    if (received < issued || received >= expiry) throw new Error('Push received outside its validity interval');
  }
}

export function validatePushHealth(value: PushHealth) {
  if (value.delivery.kind === 'unknown') return;
  const evidence = value.delivery.evidence;
  parseTimestamp(evidence.at);
  if (value.registration.kind !== 'registered' || evidence.generation !== value.registration.generation) {
    throw new Error('Push evidence must match the current registered generation');
  }
}
