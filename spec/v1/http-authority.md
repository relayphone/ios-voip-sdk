# Built-in HTTP Answer authority

The built-in authority authorizes native Answer for an incoming call, including when JavaScript
is detached. Install its HTTPS endpoint and credential reference before push intake. Use the
[Answer lifecycle and budgets](../domain.md#actions-and-authority) for admission, preparation
and system settlement. The [HTTP schema](http-authority.schema.json) and
[fixtures](http-authority/fixtures/) define the request and response records.

## Requests

The configured base URL consists of an HTTPS origin and an optional deployment path prefix.
It has no user information, query or fragment. Prefix segments contain ASCII letters, digits,
`-`, `_`, `.` and `~`. Reject empty, `.` and `..` segments. A sole or trailing slash is
omitted when joining the prefix to these paths.

| Operation | Method and path suffix | JSON body |
| --- | --- | --- |
| Claim | `POST /v1/answer/claim` | `version`, `callID`, `accountID`, `lineID`, `actionID` |
| Reconcile | `POST /v1/answer/reconcile` | Same as Claim |
| Release | `POST /v1/answer/release` | Same fields plus `permitID` |

Send UTF-8 JSON with `Content-Type: application/json` and `Accept: application/json`.
`version` is the integer `1`. `callID` is the canonical ID. `accountID` and `lineID` are
the admitted call's account and line. `actionID` is the original native Answer receipt ID.
Reconciliation can have a different local attempt generation while preserving these fields.

Set the `Idempotency-Key` header to `v1.` followed by the unpadded base64url encoding of
the exact UTF-8 bytes of `actionID`. The ID must contain valid Unicode scalar values.
Do not trim, normalize or hash it. For `answer-α` the key is `v1.YW5zd2VyLc6x`.
The same action keeps this key across retries, reconciliation and release. A new system
Answer receipt uses a new action ID and key. Release sends the ID of the specific permit
being relinquished, including when completion arrives on a stale attempt.

Only the `body` of a fixture message is sent as JSON. The fixture envelope records the
operation, method, path, status and idempotency header as applicable. Non-200 response
fixtures record only the status and operation.

## Native authentication

Resolve the opaque credential reference in iOS Keychain or Android encrypted storage backed
by Keystore. Native onboarding provisions and rotates the bearer credential. Native sets
the `Authorization: Bearer` header only on the configured authority request. The server
authenticates the account and installation from that credential and verifies the body
against the authenticated scope. Rotation preserves the installation identity.

If secure storage cannot provide the credential, return `authorityUnavailable(credentialsUnavailable)`
without prompting or sending a request. An app can configure the reference without receiving the
secret. Keep bearer values, permit material and media credentials in native code only.
Exclude credentials, HTTP headers, raw bodies and provider errors from JS, logs and observations.
Use platform TLS trust and hostname validation. Reject all redirects, including same-origin
redirects, and disable automatic HTTP redirects and request retries.

## Responses

A protocol response uses HTTP 200 and UTF-8 `application/json`. It echoes the
`Idempotency-Key` header, `version: 1`, `callID` and `actionID`. Match all of them to the
request actually sent before applying the typed response. A success status without a valid,
correlated body provides no decision.

| Body `kind` | Operations | Meaning |
| --- | --- | --- |
| `allow` | Claim, Reconcile | The requester owns this Answer. `permit` contains the opaque `id` and a UTC millisecond `expiresAt` timestamp. |
| `refuse` | Claim, Reconcile | The typed `reason` is `answeredElsewhere`, `declinedElsewhere` or `notAllowed`. Use the domain refusal mapping. |
| `unknown` | Reconcile | The server cannot confirm the action's outcome. Settle as `claimTimedOut`. |
| `released` | Release | The matching grant is released or was already released or expired. |

Accept an allow only for the current pending Answer attempt and before permit expiry. An
allow may include `media` with `provider: "livekit"`, a secure WebSocket `url`,
`room`, `identity`, `token` and `expiresAt` in Unix seconds. The URL has no user
information, query or fragment. Pass unexpired, room- and device-scoped credentials only
to the native media provider. They cannot bypass preparation, Answer settlement or the
audio gates. The absence of `media` leaves native credential supply to the registered provider.

| Failure evidence | Native classification |
| --- | --- |
| Local claim deadline fires before a valid decision | Emit `claimTimedOut` and start the single bounded reconciliation. |
| Reconciliation is unknown, unavailable or expires | Fail the original Answer once as `claimTimedOut`. |
| Credential missing, inaccessible, or rejected with HTTP 401 or 403 | `authorityUnavailable(credentialsUnavailable)` |
| Transport failure, HTTP 408, 429, 502, 503 or 504 | `authorityUnavailable(network)` after any eligible retry |
| Redirect, TLS trust failure, unexpected final status, wrong version or correlation, or invalid body | `authorityUnavailable(invalidResponse)` |

For non-200 statuses, ignore the response body and echo. Apply the reconciliation rule
above if a failure occurs after claim timeout. A malformed response, authentication error
or unavailable transport is never a typed refusal. A Release failure records cleanup
failure independently of the call's terminal reason.

## Answer budget and stale permits

Anchor all Answer stages to the original native Answer receipt on a monotonic clock.
Let `answerDeadline` be the earlier of that receipt plus the configured total and the
effective native system deadline. Authorization and required preparation must leave the
configured settlement reserve before `answerDeadline`. Credential lookup, connections,
response parsing and any retry spend the current stage's remaining time.

- Claim expires at the earlier of the receipt time plus the configured claim allowance
  and the beginning of the settlement reserve. Only the initial Claim can retry. Allow at most one
  immediate retry after a transient connection or transport failure or HTTP 502, 503 or 504.
  Resend the same request and key only while the claim stage and action are still live.
- Reconcile runs once after claim timeout. Its deadline is the earlier of the original
  claim deadline plus the reconciliation allowance and the beginning of the settlement
  reserve. It sends one request with the original key. No available time means timeout settles
  immediately. Neither retries nor late completions move either deadline.
- A late Claim response cannot settle an Answer after the claim deadline. While that same
  action is reconciling, hold any late permit for possible release until reconciliation
  resolves. Both responses can identify the same grant. Keep an adopted permit in use.
  Release an unused permit when its action fails, ends or is replaced. Use the original
  request identity and deduplicate release by action and permit ID.

Release is independent teardown for an unused permit or a relinquished grant. It never
delays or reopens the system receipt. If it starts before the Answer deadline, bound it
by the remaining time and one second, whichever is shorter. Once the Answer deadline has
passed, permit one best-effort Release transmission with a one-second monotonic cleanup
deadline. This can also release a grant when the call ends. Release follows the same TLS
and credential rules, with no redirects or retries. A request that cannot be delivered
relies on server-side expiry and fencing.

## Server ownership

1. Authenticate the installation and check that the account, line and canonical call ID refer
   to that installation's valid invitation. Serialize the winner decision by authenticated
   account and canonical call, across devices and regions. The same call cannot have a
   second winner through a different line or idempotency key.
2. Commit the grant and its permit together with the idempotency record before replying.
   Scope that record to the authenticated installation and original Answer action. Compare
   the original action fields on repeats, and deduplicate Claim and Release separately.
   A mismatched reuse returns HTTP 409 without changing ownership. Identical
   Claim retries replay the existing decision while the grant is valid, without allocating
   another permit. A competing device receives the appropriate typed refusal.
3. Reconcile reads the state of the original action without creating an ownership claim.
   It returns the same live permit only to its owner, a known refusal, or `unknown`.
   Release verifies the permit, action and authenticated owner, changes only that matching
   grant, and acknowledges repeats idempotently. A stale or wrong-owner Release cannot
   affect a subsequent grant.
4. Bound every unused reservation by the permit expiry and reclaim it if cleanup cannot
   arrive. Before allowing any replacement, fence the old grant at the media service so
   the previous device cannot open or keep a publishing session. Keep a tombstone through
   the call's retry window and reject replays after the invitation expires. A Claim replay
   for a released or expired action returns a refusal without recreating ownership.

## Conformance

The four HTTP journeys are version 1 and pending on iOS and Android. The TypeScript tools
verify their document shapes, and the fixture suite verifies HTTP messages. Each native
driver must inject a virtual clock, a secure-store fake and the HTTP client boundary of
the built-in authority. Use UTC `2026-11-18T00:00:00.000Z` at monotonic zero and the base
URL `https://authority.example.test`. `useHTTPAuthority` installs the referenced fake
credential and fixes the Answer receipt ID for that call. `httpReply` completes the
identified exchange. `httpRequests` observes the actual ordered requests for the call
with the Authorization header omitted. Assert authentication and redaction separately,
and keep JavaScript detached.

| Journey | Required assertions on each platform |
| --- | --- |
| [Allow](journeys/http-answer-allow.json) | No HTTP work before native Answer. One correctly authenticated Claim, matching permit, no Reconcile, and one native settlement after authorization and preparation. |
| [Refused elsewhere](journeys/http-answer-refused-elsewhere.json) | Decode the typed refusal, publish the canonical `answeredElsewhere` end, settle once and keep media closed. |
| [Timeout and reconciliation](journeys/http-answer-timeout-reconcile.json) | Verify the claim boundary with virtual time. Observe `claimTimedOut` before one Reconcile with the same action key. The call remains ringing while the outcome is unknown. A correlated reconciliation permit can recover within the original budget. |
| [Late permit and release](journeys/http-answer-late-permit-release.json) | One failed settlement on unknown reconciliation. Deliver the stale permit after the Answer deadline. Observe one correctly correlated Release and no new settlement, call revival or media publication, even on duplicate permit delivery. |

Both native suites must also round-trip valid fixtures, reject invalid fixtures, and verify
unavailable storage, wrong echo, retry limits and no redirected credential transmission.
Advance the clock at deadline boundaries and deliver responses beyond them. Verify a duplicate
allow for a permit already adopted by reconciliation leaves that active grant intact. A
server integration test must race two authenticated installations for one call, repeat the
winning claim, and release both current and stale permit IDs to verify exclusive ownership.
