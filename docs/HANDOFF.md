# Handoff: CallKit Simulator and the calling library

Start here. This is the entry point for implementation work across two repositories. The plans and evidence it builds on are in [`docs/research/`](research/).

## Roles

- **Codex** leads implementation in both repositories, through the draft PRs listed below.
- **Claude** handles discovery, reviews, and device or APNs probes when asked.
- **Hamza** approves anything public or upstream, merges PRs and grants credentials.

## Repositories

| Repository                                                                               | Role                                                                                                                                                                               |
| ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`ziahamza/callkit-simulator`](https://github.com/ziahamza/callkit-simulator) (this one) | Simulator runtime, emulated system UI, control plane, conformance profiles and the discovery evidence. Stays separate; the fork's CI consumes it through pinned release artifacts. |
| [`ziahamza/expo-callkit-telecom`](https://github.com/ziahamza/expo-callkit-telecom)      | Our fork of [`mfairley/expo-callkit-telecom`](https://github.com/mfairley/expo-callkit-telecom) (MIT): the calling library for Swift and React Native.                             |
| [`mfairley/expo-callkit-telecom`](https://github.com/mfairley/expo-callkit-telecom)      | Upstream. Our proposal is [#47](https://github.com/mfairley/expo-callkit-telecom/issues/47). Open upstream PRs only after Hamza approves each one.                                 |

## Branch model

**Fork:**

- `main` mirrors `upstream/main`. Never commit to it. Sync with `git fetch upstream && git checkout main && git merge --ff-only upstream/main && git push origin main`.
- Each upstreamable change is one branch off `main`, with a draft PR into our `main`. When it's ready and approved, open the upstream PR from the same branch.
- Stack a branch on another only when it truly depends on it; the PR's base is then the dependency's branch.
- `integration` merges every feature branch plus `upstream/main`. Our apps (including Phone) consume it. It's never sent upstream. Resolve cross-branch conflicts there, not inside feature branches.
- Every branch starts with an empty handoff commit carrying the scope. Drop or squash it before upstreaming.
- Commits follow Conventional Commits; upstream releases with release-please.

**Simulator:** `docs/discovery-evidence` (this PR) → `main`, then stacked branches `feat/runtime-engine` → `feat/media-conformance` → `feat/system-ui-control-plane`.

**Codex's local `codex/callkit-runtime` branch** (its `PLAN.md` and reviews) has not been pushed. Push it and rebase it onto `main` after this PR merges; it touches no files this PR adds.

## Draft PRs

Each draft PR's description is the full handoff for that workstream: goal, scope, acceptance and evidence.

**Simulator** (stacked):

| PR                                                         | Branch                                                                                                 | Depends on |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------- |
| [#1](https://github.com/ziahamza/callkit-simulator/pull/1) | `docs/discovery-evidence`: this evidence and handoff                                                   | —          |
| [#2](https://github.com/ziahamza/callkit-simulator/pull/2) | `feat/runtime-engine`: engine, conformance gate, minimal controls, release artifact                    | #1         |
| [#3](https://github.com/ziahamza/callkit-simulator/pull/3) | `feat/media-conformance`: two-way audio with independent evidence                                      | #2         |
| [#4](https://github.com/ziahamza/callkit-simulator/pull/4) | `feat/system-ui-control-plane`: emulated UI with genuine identifiers, control plane, framework helpers | #3         |

**Fork** (each off `main`, upstreamable):

| PR                                                            | Branch                                  | Upstream links | Depends on                                            |
| ------------------------------------------------------------- | --------------------------------------- | -------------- | ----------------------------------------------------- |
| [#1](https://github.com/ziahamza/expo-callkit-telecom/pull/1) | `fix/ios-voip-push-hardening`           | #29, #47       | simulator #2 for tests                                |
| [#2](https://github.com/ziahamza/expo-callkit-telecom/pull/2) | `fix/ios-audio-activation`              | #22, #32, #36  | simulator #2 (faults)                                 |
| [#3](https://github.com/ziahamza/expo-callkit-telecom/pull/3) | `fix/ios-events-before-js`              | #46            | simulator #2 (control surface)                        |
| [#4](https://github.com/ziahamza/expo-callkit-telecom/pull/4) | `ci/ios-simulator-e2e`                  | —              | simulator #2 release                                  |
| [#5](https://github.com/ziahamza/expo-callkit-telecom/pull/5) | `feat/ios-multi-call` (RFC)             | #38 (Android)  | device measurements; simulator #4 for shared UI tests |
| [#6](https://github.com/ziahamza/expo-callkit-telecom/pull/6) | `refactor/ios-swift-core-package` (RFC) | —              | —                                                     |
| [#7](https://github.com/ziahamza/expo-callkit-telecom/pull/7) | `feat/media-adapters` (RFC)             | #21, #44       | simulator #3                                          |
| [#8](https://github.com/ziahamza/expo-callkit-telecom/pull/8) | `integration` (never merged)            | —              | everything above                                      |

**Suggested order:**

1. Simulator #1 merged, then #2's release artifact.
2. In parallel: fork #1 and #3 (small, testable with the synthetic push lane).
3. Fork #4 (CI), so every later PR has a gate.
4. Fork #2.
5. The RFCs (fork #5, #6, #7), raised upstream early as discussions so maintainer feedback arrives while the code is written.

## Working agreements

- **One observable acceptance target per PR**, written in its description. Label each result **measured** (with the run that produced it) or **proposed**.
- **Upstreamable branches stay narrow:** upstream's Swift and Kotlin style, no unrelated refactors, public API backward compatible or the break flagged in the PR title.
- **Conformance follows the gate** in the [calling library plan](research/2026-10-20-calling-library-plan.md#conformance-gate): normalized, versioned traces; CI fails on missing or empty traces; two-way audio needs independent captures in both directions.
- **Device runs** use only the dedicated test iPhone 13; its identifier and the devices to avoid are in the private handoff notes. Probe App IDs `dev.callkitsim.probe` and `dev.callkitsim.probe.uitests.xctrunner` exist in the team account.
- **The test phone has a Focus** that filters VoIP reports (`FilteredByDoNotDisturb`). A second report from the same number within seconds breaks through. UI automation needs the phone awake and unlocked.
- **Genuine call UI automation:** tap SpringBoard elements by query (banner and lock-screen Accept), and InCallService elements by element query (call-waiting buttons). Coordinate taps from InCallService frames miss. See [`device-system-ui/`](research/callkit-simulator-probe/device-system-ui/).
- **APNs:** Hamza approved reusing Phone's existing VoIP push certificate for probes; where it lives is in the private handoff notes. Fetch it to a private temporary directory (`umask 077`), never print or commit tokens or keys, and delete them afterwards. [`apns-real/send.sh`](research/callkit-simulator-probe/apns-real/send.sh) shows the pattern.
- **Simulators:** create your own throwaway devices and delete them afterwards. Argent devtools may set `DYLD_INSERT_LIBRARIES` in a booted simulator's launchd; append to it, and restore it afterwards.
- **Disk:** the Mac has run out of space once. Delete throwaway simulators and DerivedData.
- **CI:** GitHub `macos-26` runners. Hosted runners have silent microphones (S8), so media tests inject audio.

## Key evidence

- [Simulator plan](research/2026-10-20-callkit-simulator-runtime-plan.md): evidence ledger S1–S8, D1–D12, P1–P7, R1–R8; architecture; fidelity contract.
- [Calling library plan](research/2026-10-20-calling-library-plan.md): upstream-first decision, rulebook, startup and audio sequence, failure semantics, media matrix, conformance gate.
- [Probe sources and traces](research/callkit-simulator-probe/README.md): including the runtime prototype `runtime-spike/CKSimRuntime.m`.
