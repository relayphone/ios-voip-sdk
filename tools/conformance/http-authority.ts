import type { Refusal, WireID } from './model.ts';
import { validateHTTPAuthority } from './schema.ts';

type Operation = 'claim' | 'reconcile' | 'release';
type Identity = Readonly<{ version: 1; callID: WireID; actionID: WireID }>;
type RequestBody = Identity & Readonly<{ accountID: WireID; lineID: WireID }>;
export type HTTPAuthorityRequest = Readonly<{ kind: 'request'; method: 'POST'; path: string; idempotencyKey: string }> & (
  | { readonly operation: 'claim' | 'reconcile'; readonly body: RequestBody }
  | { readonly operation: 'release'; readonly body: RequestBody & { readonly permitID: WireID } }
);
type LiveKitCredentials = Readonly<{
  provider: 'livekit'; url: string; room: string; identity: string; token: string; expiresAt: number;
}>;
type Decision =
  | { readonly kind: 'allow'; readonly permit: Readonly<{ id: WireID; expiresAt: string }>; readonly media?: LiveKitCredentials }
  | { readonly kind: 'refuse'; readonly reason: Refusal };
type Success = Readonly<{ kind: 'response'; status: 200; idempotencyKey: string }>;
export type HTTPAuthorityResponse =
  | (Success & (
      | { readonly operation: 'claim'; readonly body: Identity & Decision }
      | { readonly operation: 'reconcile'; readonly body: Identity & (Decision | { readonly kind: 'unknown' }) }
      | { readonly operation: 'release'; readonly body: Identity & { readonly kind: 'released' } }
    ))
  | Readonly<{ kind: 'response'; operation: Operation; status: number }>;

export function decodeHTTPAuthority(value: unknown): HTTPAuthorityRequest | HTTPAuthorityResponse {
  validateHTTPAuthority(value);
  const message = structuredClone(value) as HTTPAuthorityRequest | HTTPAuthorityResponse;
  if (!('body' in message)) return message;
  const { actionID } = message.body;
  if (!actionID.isWellFormed() || message.idempotencyKey !== `v1.${Buffer.from(actionID, 'utf8').toString('base64url')}`) {
    throw new Error('Invalid HTTP Answer idempotency key');
  }
  if (message.kind === 'request') {
    if (message.path.split('/').some(segment => segment === '.' || segment === '..')) {
      throw new Error('Invalid HTTP Answer path prefix');
    }
  } else if (message.body.kind === 'allow') {
    const { permit, media } = message.body;
    const expiry = Date.parse(permit.expiresAt);
    if (!Number.isFinite(expiry) || new Date(expiry).toISOString() !== permit.expiresAt) {
      throw new Error('Invalid HTTP Answer permit timestamp');
    }
    if (media) {
      const endpoint = new URL(media.url);
      if (endpoint.protocol !== 'wss:' || endpoint.username || endpoint.password || /[?#]/u.test(media.url)) {
        throw new Error('Invalid secure media endpoint');
      }
    }
  }
  return message;
}
