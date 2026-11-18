import {
  id, integer, literal, milliseconds, nonempty, object, optional, phone, digit, refine, text, timestamp, union,
  type Decoded,
} from './decode.ts';

export const callID = id<'call'>();
export const remoteCallID = id<'remoteCall'>();
export const actionID = id<'action'>();
export const eventID = id<'event'>();
export const lineID = id<'line'>();
const flag = literal(true, false);
const handle = union(
  object({ kind: literal('phone'), e164: phone }),
  object({ kind: literal('email'), address: text(1, 256, /^[^\s@]+@[^\s@]+$/u) }),
  object({ kind: literal('opaque'), value: text(1, 256, /\S/u) }),
);
const line = object({ accountID: id<'account'>(), id: lineID, label: text() });
const party = object({ id: id<'party'>(), handle, displayName: text() });
export const invitation = object({ callID, eventID, line, party });

export const lifecycleKind = literal('reporting', 'ringing', 'placing', 'dialing', 'connecting',
  'previewing', 'connected', 'reconnecting', 'ending', 'ended');
const refusalReason = object({ kind: literal('answeredElsewhere', 'declinedElsewhere', 'notAllowed') });
const timedStage = literal('placement', 'claim', 'reconciliation', 'mediaPreparation', 'audioActivation',
  'connection', 'reconnection', 'systemAction', 'noAnswer');
const systemFailure = { kind: literal('admission', 'action', 'removal', 'reset', 'audio'),
  code: optional(integer(-2147483648, 2147483647)) };
const budgetFields = {
  placement: milliseconds, incomingRing: milliseconds, outgoingNoAnswer: milliseconds,
  mediaPreparation: milliseconds, audioActivation: milliseconds, audioRecovery: milliseconds,
  connection: milliseconds, reconnection: milliseconds,
};
const nonRefusalError = union(
  object({ kind: literal('unknownCall'), callID }),
  object({ kind: literal('invalidTransition'), state: lifecycleKind }),
  object({ kind: literal('unsupported'), feature: literal('hold', 'video', 'tones', 'preview', 'merge') }),
  object({ kind: literal('permissionRequired'), permission: literal('microphone', 'camera') }),
  object({ kind: literal('authorityUnavailable'), cause: literal('credentialsUnavailable', 'network', 'invalidResponse') }),
  object({ kind: literal('claimTimedOut'), actionID }),
  object({ kind: literal('placementFailed'), cause: literal('cancelled', 'handlerFailed') }),
  object({ kind: literal('deadlineExceeded'), stage: timedStage }),
  object({ kind: literal('mediaFailed'), stage: literal('prepare', 'activate', 'release'), cause: literal('transport', 'permission', 'timeout') }),
  object({ kind: literal('remoteIdentityConflict'), remoteID: remoteCallID }),
  object({ kind: literal('invalidConfiguration'), field: literal('answer', 'placement', 'incomingRing',
    'outgoingNoAnswer', 'mediaPreparation', 'audioActivation', 'audioRecovery', 'connection', 'reconnection', 'retention') }),
  object({ kind: literal('systemFailed'), cause: union(
    object({ platform: literal('ios'), ...systemFailure }),
    object({ platform: literal('android'), ...systemFailure }),
  ) }),
  object({ kind: literal('bridgeUnavailable') }),
);
const error = union(nonRefusalError, object({ kind: literal('refused'), reason: refusalReason }));
const failedEnd = object({ kind: literal('failed'), error: union(nonRefusalError,
  object({ kind: literal('refused'), reason: object({ kind: literal('notAllowed') }) })) });
const localEnd = object({ kind: literal('localDeclined', 'localEnded') });
const filtered = object({ kind: literal('filtered'), cause: literal('doNotDisturb', 'blockList', 'unknown') });
const endReason = union(localEnd, filtered, failedEnd,
  object({ kind: literal('remoteEnded', 'unanswered', 'answeredElsewhere', 'declinedElsewhere') }));
const previewReason = union(filtered, object({ kind: literal('answeredElsewhere', 'policy') }));
const commonLifecycle = union(
  object({ kind: literal('placing', 'connecting') }),
  object({ kind: literal('connected', 'reconnecting'), connectedAt: timestamp }),
  object({ kind: literal('ending'), reason: endReason }),
  object({ kind: literal('ended'), reason: endReason, endedAt: timestamp }),
);
const incomingLifecycle = union(commonLifecycle, object({ kind: literal('reporting', 'ringing') }),
  object({ kind: literal('previewing'), reason: previewReason }));
const outgoingLifecycle = union(commonLifecycle, object({ kind: literal('dialing') }));
const callFields = {
  id: callID, remoteID: optional(remoteCallID), line, parties: nonempty(party),
  held: flag, muted: flag, video: flag,
  media: object({
    owner: literal('native', 'application'), preparation: literal('unprovided', 'preparing', 'prepared', 'released'),
    audio: literal('inactive', 'active'), transport: literal('disconnected', 'connecting', 'connected', 'reconnecting'),
  }),
};
export const wireCall = union(
  object({ direction: literal('incoming'), lifecycle: incomingLifecycle, ...callFields }),
  object({ direction: literal('outgoing'), lifecycle: outgoingLifecycle, ...callFields }),
);
const actions = {
  simple: { kind: literal('answer', 'join', 'end') },
  hold: { kind: literal('hold'), held: flag },
  mute: { kind: literal('mute'), muted: flag },
  video: { kind: literal('video'), enabled: flag },
  tones: { kind: literal('tones'), digits: nonempty(digit) },
};
const action = union(
  object({ callID, kind: literal('start'), line, party }),
  object({ callID, ...actions.simple }), object({ callID, ...actions.hold }),
  object({ callID, ...actions.mute }), object({ callID, ...actions.video }),
  object({ callID, ...actions.tones }),
);
const endResult = union(
  object({ kind: literal('ended'), receipt: object({ callID, actionID, reason: localEnd }) }),
  object({ kind: literal('alreadyEnded'), reason: endReason }),
);
const answerBudget = refine(object({
  total: milliseconds, claim: milliseconds, reconciliation: milliseconds, settlementReserve: milliseconds,
}), value => value.claim + value.reconciliation + value.settlementReserve < value.total, 'an answer budget with time to spare');
const budgets = object({ answer: answerBudget, ...budgetFields,
  retention: optional(object({ lifetime: milliseconds, terminalRecords: integer(1, 2147483647) })) });

export const wireV0 = union(
  object({ version: literal(0), kind: literal('call'), value: wireCall }),
  object({ version: literal(0), kind: literal('action'), value: action }),
  object({ version: literal(0), kind: literal('endReason'), value: endReason }),
  object({ version: literal(0), kind: literal('error'), value: error }),
  object({ version: literal(0), kind: literal('budgets'), value: budgets }),
  object({ version: literal(0), kind: literal('endResult'), value: endResult }),
);

export type WireV0 = Decoded<typeof wireV0>;
export type WireCall = Decoded<typeof wireCall>;
export type Lifecycle = Decoded<typeof incomingLifecycle> | Decoded<typeof outgoingLifecycle>;
export type LifecycleKind = Lifecycle['kind'];
export type EndReason = Decoded<typeof endReason>;
export type CallError = Decoded<typeof error>;
export type CallingLine = Decoded<typeof line>;
export type Party = Decoded<typeof party>;
export type Handle = Decoded<typeof handle>;
export type AnswerBudget = Decoded<typeof answerBudget>;
type WithoutCallID<Value> = Value extends { readonly callID: CallID } ? Omit<Value, 'callID'> : never;
type CallID = Decoded<typeof callID>;
export type Action = WithoutCallID<Exclude<Decoded<typeof action>, { readonly kind: 'start' }>>;
