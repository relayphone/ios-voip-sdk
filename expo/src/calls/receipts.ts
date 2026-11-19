import { id, integer, literal, object, union, type Decoded } from './decode.ts';
import { actionReceipt, callID, endReason, error, previewReason } from './wire-v0.ts';
import { feature } from './wire-v1.ts';

export const cursor = object({ epoch: id<'epoch'>(), sequence: integer() });
export const performed = object({ kind: literal('performed'), cursor, receipt: actionReceipt });
export type Performed = Decoded<typeof performed>;

const bridgeError = union(error, object({ kind: literal('unsupported'), feature }));
const incomingDecision = union(
  object({ kind: literal('admitted', 'hidden', 'capacity'), callID }),
  object({ kind: literal('previewed'), callID, reason: previewReason }),
  object({ kind: literal('ended'), callID, reason: endReason }),
  object({ kind: literal('filtered'), callID, cause: literal('doNotDisturb', 'blockList', 'unknown') }),
  object({ kind: literal('refused'), callID, error: bridgeError }),
);
export const incomingOutcome = union(incomingDecision, object({ kind: literal('duplicate'), original: incomingDecision }));
export type IncomingOutcome = Decoded<typeof incomingOutcome>;
