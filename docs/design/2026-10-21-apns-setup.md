# APNs setup and review response — October 21, 2026

## Credential decision completed

Hamza selected a team-wide APNs authentication key and authorized lookup,
creation if necessary, vault storage, GitHub configuration and private local
projections.

The referenced **GitEnv Apple Developer Signing** item contains signing and App
Store Connect credentials. **Zia Phone Sign in with Apple** contains the key
visible in Apple's portal as Sign in with Apple only. The Phone development
setup note documents APNs variable names but contains no token-auth key. The
checked Phone Environments likewise had no APNs key. A `.p8` file alone is not
evidence of APNs capability.

A new **Phone CallKit QA Sandbox** key now supports **APNs only, Team Scoped
(All topics), Sandbox**. It does not authorize production pushes. No existing
key was revoked, rotated or given another capability.

- Canonical key: **Phone APNs sandbox team key**, a document in **Phone App**,
  with key/team/environment/scope fields. Retrieval through the already approved
  Phone service account was byte-verified.
- Local configs: `.env/apns-sandbox.env` in the simulator clone, its runtime
  worktree, and the library clone. They reference one private `.p8` projection
  in the simulator clone. These directories are ignored and mode `0700`; files
  are mode `0600`. Temporary download/roundtrip/provisioning key copies were
  removed. No broad Phone bootstrap token was copied to either public repo.
- GitHub: simulator repository Environment **apns-sandbox-device-qa**. It has a
  required operator reviewer and exact branch rules for `main` and
  `feat/runtime-engine`. Its secret is available only to the approved
  credential-check job. Ordinary simulator/library PR CI receives no APNs key.
- [Hosted credential check](https://github.com/relayphone/ios-voip-sdk/actions/runs/39574173320)
  passed: private-key retrieval and local P-256 ES256 signing. This job sends
  no push, uploads no artifacts and makes no APNs-delivery claim.

## Real device smoke test

[Evidence](https://github.com/relayphone/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-21-apns-sandbox/README.md) contains one real
sandbox APNs acceptance receipt and the corresponding metadata callback from
the dedicated iPhone 13. The topic remains **dev.callkitsim.probe.voip**.

The installed historical probe's profile lacked `aps-environment`, so it could
not register a token. The new [`discovery/device`](../../discovery/device/README.md)
target built with **development** push entitlements, and automatic provisioning
updated the probe's development profile. No Phone application was replaced.
The installed probe now uses `discovery/probe/main.swift`; reinstall the historical
research target if its extra UI/provider-routing controls are needed. Give that
target the development push entitlement too before any APNs experiment.

One fresh push returned HTTP 200 and reached the un-injected probe via the
metadata method: **foreground, `mustReport=false`**. The probe's incoming report
then failed with Apple's **filtered-by-Do-Not-Disturb error (3)**. Focus was not
changed. The scenario finished with no calls or pending actions.

This closes credential lookup and genuine authentication/delivery. It does not
close the proposed active-call or cold-launch experiments. No retry was made.
Tokens, JWTs and private key bytes are absent from the committed evidence.

## Review disposition

The latest `docs/discovery-evidence` was merged into the runtime branch at
`24775f6`; APNs tooling/evidence is `18513de`. Two fresh bounded reviewers audited
the review's claims and the sender respectively; a third reviewed the corrected
sender and CI boundary. The lead implemented and integrated the changes.

Confirmed next implementation work:

1. **Repair the deterministic evidence gate first.** The independent audit
   reproduced false passes after deleting observer callbacks, inserting a reset
   or unexpected timeout, reversing time and setting version 99. Add strict-v2
   positive evidence and those negative mutations. Bind each receipt to trace
   hash, run ID, PID and simulator identity. A checksum detects accidental
   evidence mixing; it does not authenticate fabricated evidence.
2. **Optional malformed pushes:** adopt skip-on-optional as the default, keep
   required placeholders, always report valid invitations, retain `reportAll`
   opt-in. Prove optional/required/legacy independently, report-and-end before
   completion on the required path, and metadata-selector absence in the
   built legacy adapter. Do not derive obligation solely from app state.
3. **Provider routing:** replay all eight new phone scenarios before replacing
   the current provider selection. Newest-created routing, no fallback after
   invalidation, revival and mute echoes are the measured **iOS 27.0 profile**;
   they are not yet universal undocumented guarantees.
4. **Incoming publication:** use the explicitly requested separate
   `fix/ios-incoming-session-publication` branch off library `main`. Make the UUID
   synchronously resolvable from the moment reporting starts, and prevent late
   completion from resurrecting a terminated session or arming its timeout.
5. Preserve upstream authorship, then clean formatting/history and separate
   fork-only QA/evidence once the functional corrections settle. Tighten the
   XCTest passed/skipped gate and stabilize the fixture revision.

These library/runtime corrections are **not implemented by this credential
checkpoint**. Existing green discovery runs do not override the demonstrated
gate defects. The approximately 59.6 s prototype expiry is configured from the
phone measurement; it is not independent proof of conformance.

One pushback on the review: **S9's transaction-UUID objection conflicts with the new
device traces.** Every matched request in `single` (6/6), `ab` (12/12) and `inv`
cleanup (2/2) has a different provider-delivered transaction UUID while its
action UUID is preserved. Preserving the controller's transaction UUID would
currently move away from this evidence. The fixed 5 ms ordering timer remains a
real defect to replace.

## Remaining device decisions and measurements

The credential decision is resolved. Continue with the probe's own topic:

- During a genuine connected call, capture the real push's `mustReport` value.
- Terminate without user force-quit semantics, lock the dedicated device, send
  a real push, answer, and measure answer-to-`didActivate` latency.
- Exercise native event retention before JS attaches when that library slice
  exists; this probe alone cannot establish the JS replay contract.
- Decide how to handle the dedicated phone's Focus for incoming UI experiments;
  this smoke test observed a real filtered report and left settings intact.

The production runtime, separate call UI host, Swift package extraction, typed
bridge and independent bidirectional media proof remain subsequent milestones.
