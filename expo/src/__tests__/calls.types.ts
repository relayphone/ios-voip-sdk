import {
  callID, credentialRef, e164, httpsURL, milliseconds, remoteCallID,
  type Action, type Call, type CallError, type CallingPolicy, type EndReason, type Handle,
  type Lifecycle, type PushHealth, type Result,
} from '../calls/model.ts';
import { createCallsHooks } from '../calls/react.ts';
import type { CallsStore } from '../calls/store.ts';
// @ts-expect-error The new store is internal until the native client is wired.
import type { CallsStore as PublicCallsStore } from '../index.ts';

declare const store: CallsStore;
declare const call: Call;
declare const registration: Extract<PushHealth['registration'], { kind: 'registered' }>;
declare const delivery: Extract<PushHealth['delivery'], { kind: 'observed' }>;
const id = callID('call-a');
const phone = { kind: 'phone', e164: e164('+12025550101') } satisfies Handle;
const hold = { kind: 'hold', held: true } satisfies Action;
const success = { ok: true, value: id } satisfies Result<typeof id, CallError>;
const failure = { ok: false, error: { kind: 'unsupported', feature: 'prejoin' } } satisfies Result<typeof id, CallError>;
const policy = {
  answer: { kind: 'http', endpoint: httpsURL('https://example.test/answer'), credential: credentialRef('answer-key'),
    budget: { total: milliseconds(4500), claim: milliseconds(2500),
      reconciliation: milliseconds(500), settlementReserve: milliseconds(500) } },
  outgoingMedia: { kind: 'whenProvided' },
  connectionAuthority: 'application',
} satisfies CallingPolicy;
const connected = { kind: 'connected', connectedAt: '2026-07-21T00:00:00.000Z' } satisfies Lifecycle;
const ended = { kind: 'failed', error: { kind: 'refused', reason: { kind: 'notAllowed' } } } satisfies EndReason;
const observedHealth = { registration, delivery, connectivity: { kind: 'online' },
  readiness: { kind: 'ready' } } satisfies PushHealth;
void [phone, hold, success, failure, policy, connected, ended, observedHealth];

const { useCalls, useCall, usePushHealth } = createCallsHooks(store);
void (useCalls satisfies () => readonly Call[]);
void (useCall satisfies (call: typeof id) => Call | undefined);
void (usePushHealth satisfies () => PushHealth | undefined);
void store.observe({ after: store.snapshot().cursor });
if (call.direction === 'outgoing') {
  const state: Exclude<Lifecycle['kind'], 'reporting' | 'ringing' | 'previewing'> = call.lifecycle.kind;
  void state;
}

// @ts-expect-error Remote aliases do not select calls.
void useCall(remoteCallID('remote-a'));
// @ts-expect-error IDs must pass a validating constructor.
void useCall('call-a');
// @ts-expect-error Observation cursors are epoch and sequence pairs.
void store.observe({ after: 4 });
// @ts-expect-error Hold requires an explicit target state.
void ({ kind: 'hold' } satisfies Action);
// @ts-expect-error Unsupported features are a closed set.
void ({ kind: 'unsupported', feature: 'transfer' } satisfies CallError);
// @ts-expect-error A connected call requires its original connection timestamp.
void ({ kind: 'connected' } satisfies Lifecycle);
// @ts-expect-error Failed ends must include a typed cause.
void ({ kind: 'failed' } satisfies EndReason);
// @ts-expect-error Terminal refusal to answer elsewhere has its own reason.
void ({ kind: 'failed', error: { kind: 'refused', reason: { kind: 'answeredElsewhere' } } } satisfies EndReason);
// @ts-expect-error HTTP Answer needs a validated HTTPS URL.
void ({ ...policy, answer: { ...policy.answer, endpoint: 'https://example.test' } } satisfies CallingPolicy);
// @ts-expect-error Invalidation clears current delivery evidence.
void ({ ...observedHealth, registration: { ...registration, kind: 'invalidated' } } satisfies PushHealth);
// @ts-expect-error Native observations are immutable.
call.media.firstPackets.sent = 'observed';
