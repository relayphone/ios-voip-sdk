# Handler rejection details — October 22, 2026

Acceptance target: preserve the JavaScript handler's rejection name and message at the native continuation boundary, with typed narrowing for the native command error codes. This is the rejection-details subset of [steering A8](2026-10-22-claude-steering.md).

**Measured (host).** Source `5446e3c56e309b1fe7caac2736664f80ca731981` preserves reviewed change `c1e7dcb94fe5cf6fc5977d5b4938c313ff36bf62` on main `ef5a1f6f14c5a151b8bc9d41cc0451fc64c9d305`. The source delta is five files. `settleAction` carries the reason into an immutable native error; a failed handler continuation retains its exact name and message. Contents are not logged. Successful, stale and duplicate settlement behavior stays guarded by the existing owner, generation and delivery checks.

**Measured (host).** The production Swift relay passes nine groups, including exact rejection detail preservation and one continuation completion. The TypeScript runtime passes eleven tests, including narrowing only the four codes currently emitted by native conversation commands. Library and example TypeScript checks pass. [The receipt](../verification/2026-10-22-handler-rejection-details/receipt.json) binds the commands, logs, tool versions and unchanged source hashes.

**Proposed; native acceptance pending.** The host relay uses owner doubles and does not compile or run the Expo module itself. No app, simulator, device, PushKit or LCK measurement is claimed here. Conversation event context, local-end mapping, connected-state semantics and duplicate detection through LCK wrapping remain separate A8 targets.
