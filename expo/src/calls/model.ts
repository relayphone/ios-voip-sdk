import { hasControlCharacters, id, union, type Decoded, type ID } from './decode.ts';
import { wireV0, type AnswerBudget, type CallError as WireCallError, type WireCall } from './wire-v0.ts';
import { wireV1, type Capability, type Feature, type MediaObservation } from './wire-v1.ts';

export type { ID, Milliseconds } from './decode.ts';
export { digit as dtmfDigit, milliseconds, phone as e164 } from './decode.ts';
export { actionID, callID, eventID, lineID, remoteCallID } from './wire-v0.ts';
export type { Action, AnswerBudget, CallingLine, EndReason, Handle, Lifecycle, LifecycleKind, Party } from './wire-v0.ts';
export type { Feature, PushHealth } from './wire-v1.ts';

export type CallID = ID<'call'>;
export type RemoteCallID = ID<'remoteCall'>;
export type EventID = ID<'event'>;
export type ActionID = ID<'action'>;
export type LineID = ID<'line'>;
export type DTMFDigit = ReturnType<typeof import('./decode.ts').digit>;
export type Result<Value, Error> = { readonly ok: true; readonly value: Value }
  | { readonly ok: false; readonly error: Error };
export type CallError = Exclude<WireCallError, { readonly kind: 'unsupported' }>
  | { readonly kind: 'unsupported'; readonly feature: Feature };

export const accountID = id<'account'>();
export const partyID = id<'party'>();
export const attemptID = id<'attempt'>();
export const nativeAuthorityID = id<'nativeAuthority'>();
export const credentialRef = id<'credential'>();
export type HTTPSURL = ID<'httpsURL'>;
export function httpsURL(input: string): HTTPSURL {
  const url = new URL(input);
  if (input.trim() !== input || hasControlCharacters(input) || !/^https:\/\//iu.test(input) ||
      url.protocol !== 'https:' || url.username || url.password) {
    throw new TypeError('Expected an HTTPS endpoint without embedded credentials');
  }
  // SAFETY: The original string passed URL parsing and the HTTPS, credential and character checks.
  return input as HTTPSURL;
}

type AnswerPolicy = { readonly kind: 'immediate' }
  | { readonly kind: 'nativeAuthority'; readonly authority: ID<'nativeAuthority'>; readonly budget: AnswerBudget }
  | { readonly kind: 'http'; readonly endpoint: HTTPSURL; readonly credential: ID<'credential'>; readonly budget: AnswerBudget };
export type CallingPolicy = Readonly<{
  answer: AnswerPolicy;
  outgoingMedia: { readonly kind: 'duringPlacement' } | { readonly kind: 'whenProvided' };
  connectionAuthority: 'application' | 'nativeMedia';
}>;

type Gate = 'unknown' | 'closed' | 'open';
export type VideoState = Readonly<{
  confirmed: 'audio' | 'video';
  capture: Gate;
  pending: { readonly kind: 'unknown' | 'none' } | { readonly kind: 'requested'; readonly enabled: boolean };
}>;
type LegacyMedia = Readonly<{
  stage: WireCall['media']['preparation']; owner: WireCall['media']['owner'];
  activation: WireCall['media']['audio']; transport: WireCall['media']['transport'];
  attemptID?: never; capture: 'unknown'; output: 'unknown';
  firstPackets: Readonly<{ sent: 'unknown'; received: 'unknown' }>;
}>;
export type MediaState = MediaObservation | LegacyMedia;
export type CallCapabilities = readonly Capability[];
type CallView<Wire extends WireCall> = Wire extends WireCall ? Omit<Wire, 'video' | 'media'> & Readonly<{
  video: VideoState; media: MediaState; capabilities: CallCapabilities;
}> : never;
export type Call = CallView<WireCall>;

const unknownPackets = Object.freeze({ sent: 'unknown', received: 'unknown' } as const);
const unknownVideoChange = Object.freeze({ kind: 'unknown' } as const);
const emptyCapabilities: CallCapabilities = Object.freeze([]);

export function projectCall(wire: WireCall, previous?: Call): Call {
  const { owner, preparation, audio, transport } = wire.media;
  const confirmed = wire.video ? 'video' : 'audio';
  const observedMedia = previous && 'callID' in previous.media ? previous.media : undefined;
  return Object.freeze({
    ...wire,
    video: Object.freeze({ confirmed, capture: 'unknown', pending: unknownVideoChange }),
    media: observedMedia ?? Object.freeze({
      owner, stage: preparation, activation: audio, transport, capture: 'unknown', output: 'unknown',
      firstPackets: unknownPackets,
    }),
    capabilities: previous?.capabilities ?? emptyCapabilities,
  });
}

export const decodeWireRecord = union(wireV0, wireV1);
export type WireRecord = Decoded<typeof decodeWireRecord>;
