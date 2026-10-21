# Claude's review of v0.1 (October 21, 2026, evening)

## Scope

This review covers:

- runtime [#2](https://github.com/ziahamza/callkit-simulator/pull/2) at `ba2fe66`, the same commit as tag `v0.1`, and the [v0.1 release](https://github.com/ziahamza/callkit-simulator/releases/tag/v0.1);
- fork [#1](https://github.com/ziahamza/expo-callkit-telecom/pull/1) `0adf6db`, [#9](https://github.com/ziahamza/expo-callkit-telecom/pull/9) `8a6795a`, [#4](https://github.com/ziahamza/expo-callkit-telecom/pull/4) `0faca8d` and [#3](https://github.com/ziahamza/expo-callkit-telecom/pull/3) `6de9de2`;
- Phone [#374](https://github.com/ziahamza/phone-app/pull/374), merged as `249f004b`.

Three independent reviewers read the code and evidence. They downloaded and inspected the release archive but did not run its binaries or rebuild it. Items marked **confirmed** were also checked directly by Claude.

## Verdict

**v0.1 is a sound base.**

- The D13, D14 and D4 conformance checks genuinely load the committed iPhone traces. They compare receivers, error codes, ordered performs, mute values, timeout inventory, the ~10.6 s `unknownCallProvider` timing, revival and late-delegate non-replay.
- Gate defects S1–S6 are fixed.
- The release archive matches `SHA256SUMS`. Its binaries are byte-identical to the tested CI `runtime-dist`.
- Library #9's interleavings are correct.
- Phone's injection is confined to the test host.

Three things need fixing before more is built on top:

1. a runtime threading difference from the device (R1);
2. silent behavior when Apple's private ABI changes (R2);
3. a regression in library #3 (E1).

**One process problem:** Phone #374 changed only test files but still produced a new store runtime and a TestFlight upload (P1).

## Runtime (simulator #2 and v0.1)

### Fix first

- **R1, confirmed bug: the incoming-report completion runs on a background queue.**
  - `Sources/Engine/RuntimeEngine.swift:450` uses `(owner.queue ?? owner.reportQueue)`. With a `nil` delegate queue, the completion runs on a private background queue.
  - On the iPhone, all 19 `report.incomingCompleted` events across the four 2026-10-20 traces arrived on the main thread.
  - On the phone, this completion is serialized with `perform(answer)` on main. In the simulator they race, which is exactly the class of race library #9 fixes. A completion that calls `DispatchQueue.main.sync` passes in the simulator and deadlocks on a phone.
  - The gate's main-thread lists leave this event out (`summarize.py:103-106`, `semantics_conformance.py:31`).
  - Fix: `?? .main`, and add the event to the main-thread checks.
- **R2, bug: a private-ABI change on a new iOS runtime fails silently or crashes the app.**
  - Only `invalidate` is rebound on the concrete class `CXXPCProvider` (`CKInterposition.m:61-65`). If a future concrete class overrides `reportNewIncomingCall…`, `setDelegate:queue:` or `reportCall…endedAt…`, calls fall through to genuine CallKit, which tears them down, and nothing diagnoses it.
  - The snapshot keys are set by KVC (`:23-26`). A renamed key throws `NSUnknownKeyException` on the engine queue and crashes the app.
  - A missing selector calls `abort()` in the dyld constructor (`:113`).
  - Fix: at install, verify every swapped implementation on each concrete class and set-and-read-back each snapshot key. On failure, refuse cleanly with a diagnostic.

### Next

- **R3, test gap: the runtime never calls `providerDidReset`.** On the device, the older provider gets `didReset` during invalidation cleanup (ab, ba, drop, inv), plus an extra `didBegin` in recreate. Claude will characterize these before they become a profile item. Until then, list reset and teardown as a known gap.
- **R4, bug: the loader is injected into the whole simulator.**
  - `cksim:94-102` appends `CKSimLoader.dylib` to the simulator launchd's `DYLD_INSERT_LIBRARIES`, so every later process loads it.
  - Deleting the package before uninstall (the README's `/tmp` example) can break later launches.
  - Uninstall refuses after XCTest edits the variable, but there is no repair path. Phone abandoned the README's XCTest flow for this reason.
  - Fix: make the test-host-only method Phone uses the documented default, and add `cksim repair`.
- **R5, false pass: build identity is only format-checked.** `summarize.py:347-349` checks that each digest is 64 hex characters, not that it matches the loaded image. The README's "identities are checked together" and "compares genuine with runtime" claims overstate this: each lane is checked against its own expectations.
- **R6, test gap: tampered fixtures skip the shipping-only branches.** The strict-v2 fixtures predate `runtime.identity 0.1.0`, so `shipping()` is false. The post-end unmute allowance, the mute-echo extras and `shipping_journal` are never tampered with. Semantics, generations and the CLI have no negative controls.
- **R7, test gap: some expectations are written into code.**
  - Deadline bands (`conformance.py:103`) and D5 compositions (`cli_conformance.py:110-112`) are hard-coded instead of read from `call-waiting.jsonl` and the traces' `timeoutIn` values.
  - The `inv` case is compared as an unordered set.
  - The generation checks are runtime policy with no device reference. For example, `:304` drops an action after reporting success.
- **R8, test gap: CI covers neither the profile's own OS nor LiveCommunicationKit.** CI runs the `ios-27.0` profile on an iOS 26.5 simulator only, and LiveCommunicationKit isn't covered.
- **R9, supply chain: the release tarball was packed on a developer Mac.**
  - The tar entries are owned by `hzia/staff`.
  - `v0.1` is a lightweight, unsigned tag on an unmerged draft head.
  - `build-info.json` doesn't record the toolchain.
  - Fix: package in CI with a GitHub artifact attestation, and use an annotated tag on a merged commit. Merge #1, then #2, first.
- **R10, overclaim: "compiled out of device builds".** Device builds are actually blocked by `#error` and the binaries' iOS Simulator platform tag. That is adequate, so describe it accurately.
- **Minor engine notes:**
  - Actions lost to a provider with no delegate time out later, so the late delegate receives `timedOutPerforming` for actions it never saw.
  - The ring timeout is inert while the selected provider is invalid, so that call rings forever.
  - A CLI `answer` on a waiting call yields two active calls, which a phone can't produce.

## Library (fork)

- **E1, confirmed bug (#3): new listeners replay stale events.**
  - `CallEventEmitter.swift:43` changes `defaultQueueLimit` from `0` to `128`, and `AppDelegateSubscriber.swift` drops the per-event limit of 1 on six event types.
  - Events that upstream dropped when no listener was attached are now queued and flushed to the next listener. For example, a call screen that subscribes to `onCallEnded` on mount receives the *previous* call's `CallEnded` and closes immediately.
  - Revert this.
- **E2, bug (#3): a quick detach-then-reattach leaves no consumer.**
  - `CallEventStream.ts:90` attaches without checking `closed`, and `remove()` detaches asynchronously.
  - Under StrictMode or Fast Refresh, the sequence becomes detach(c1) (a no-op), attach(c1), attach(c2). Native code rejects c2, c1 then detaches itself, and `ready` rejects.
- **E3, over-engineering (#3): don't upstream the event journal.**
  - The acked journal has epochs, revisions, consumer IDs, a snapshot rebuilt from events, one native round trip per acked event, and serial handlers. It is iOS-only and throws on Android.
  - **Smaller equivalent:** make state level-triggered.
    1. Put `pendingAnswer {requestId, deadline}` on the session.
    2. Return all sessions from `getActiveCallSession(s)`.
    3. JS subscribes to the existing events, then reconciles from that snapshot.
    4. Give only `CallAnswered` and `IncomingCallReported` small queue limits.
  - The existing native answer deadline already fails the action when JS never arrives. This is about 60 lines and works on both platforms.
  - Also: `CallEventJournal.swift:37` uses `try? JSONSerialization` around JS-supplied metadata. NaN or Infinity raises an `NSException`, which `try?` can't catch, so the app crashes.
- **E4, bug, low (#9): a reset can end a reservation made after it.** `providerDidReset` defers `removeAll()`, which calls `incomingReports.endAll()` again (`CallStore.swift:75`). That ends a push reserved after the reset. Fix: snapshot the report IDs synchronously in `providerDidReset` and remove only those.
- **E5, bug, low (#9): the incoming timer doesn't re-check ringing state when it fires** (`CallManager.swift:112-128`). An answer landing near 45 s can be ended as unanswered. Fix: end only while still ringing, under the report lock.
- **E6, contract (#9): `IncomingCallReported` can arrive after `CallAnswered`** (`CallManager.swift:369-374`). Either suppress it when the call isn't ringing, or document it. #4's test currently relies on the late event.
- **E7, simplify (#9): the reservation keeps a second copy of session state.**
  - That copy is merged into reads (`CallStore.swift:21-36, 93-127`). Keep the reservation only until the session is published.
  - Split the `FulfillRequestManager` registration-race fix into its own commit.
  - Run swift-format (lefthook). For example, `CallManager.swift:363` and `CallStore.swift:105` exceed 100 columns.
- **E8, test gap (#1): untested policy paths.**
  - No test checks that a **valid** invitation with `mustReport=false` still reports. That is the safety property: getting it wrong means dropped calls.
  - The `reportAll` path is untested.
  - There is no plugin unit test for the option.
- **E9, overclaim (#4): the description says #4 is stacked on #1.** It actually merges #9 as well. The legacy lane is macro-forced on the Xcode 26.6 SDK, and Xcode 26.3 only runs `-fsyntax-only` over one file. #3 has no CI.
- **E10, upstream hygiene (#1, #3): L5 is still open.**
  - The Prettier 2.8.8 reformatting remains.
  - The empty workstream commits remain (`e4abd67`, `0e8d3ca`), plus about 20 `fix(qa)` and `docs` commits.
  - Fork-only `docs/verification` and `example/qa` are mixed in.
  - The Objective-C names `CallKitVoIPPushDelegate` and `CallKitVoIPPushReceiver` and the macro `CALLKIT_TELECOM_LEGACY_PUSH_ONLY` are unprefixed.
  - #9 and #3 commit titles lack the conventional prefix that release-please needs.
- **Verified:**
  - **#9 interleavings:**
    - decline before the report callback;
    - answer before the callback;
    - arming the timer versus answer or end;
    - end while an answer is pending;
    - `CXEnd` plus `reportCallEnded` producing one `CallEnded`;
    - no reservation leaks.
  - **L2, L3 and L6 fixed:**
    - report, accepted, ended, then completion order, plus a journal count;
    - the `inspect-adapter` selector assertion;
    - exact pass, fail and skip counts, with a checksum-pinned release.
  - #4's publication tests fail on `main`, so they genuinely test the fix.
- **Upstream order:**
  1. **#9 first**, after E4–E7, as one `fix(ios): …` commit with simulator evidence in the PR description rather than the diff.
  2. **#1's delta** (the PushKit adapter plus policy) after upstream #29 lands on its own.
  3. **#4 stays fork-only.**
  4. **#3 goes upstream only as an RFC** for the snapshot design.

## Phone (#374)

- **P1, process risk, confirmed: a test-only PR produced a new store runtime.**
  - `apps/mobile/fingerprint.config.js` hashes all of phone-native, including `ios/Tests/**`.
  - After #374, the iOS runtime fingerprint became `b1810c19`. Tag `native-release/ios/b1810c19…` points at `249f004b`.
  - [TestFlight run 39655758172](https://github.com/ziahamza/phone-app/actions/runs/39655758172) archived and uploaded a build.
  - No test code reached the app.
  - Mitigating factor: a store build was already owed from #348.
  - Fix: ignore phone-native's `ios/Tests/**` in the fingerprint, with a fingerprint unit test. Otherwise every test edit strands installed builds from EAS Updates.
- **P2, the Xcode Cloud QA lane will fail.**
  - `ci_scripts/prepare_ui_tests.rb:94-177` adds the whole PhoneNative test target to `PhoneCloudUITests` without injecting the runtime.
  - Both new tests read a `session.json` that doesn't exist there.
  - Fix: exclude the class from that scheme. Don't use `XCTSkip`, because RunCloud requires zero skips.
- **P3, product bug, pre-existing: every cleanup push reports a blank call.**
  - Phone implements only the legacy PushKit callback, so `receivePushCleanup` always reports a blank `.generic " "` call. With `maximumCallGroups=1`, a "Missed call!" cleanup during a live call shows a blank call-waiting screen.
  - When the cleanup matches a ringing call, the placeholder is reported before the original ends.
  - Cleanup detection depends on exact English alert strings.
  - Fix: adopt `PKVoIPPushMetadata` (`mustReport=false` → skip) with the same adapter as library #1.
- **P4, test gap: the tests cover only two early-exit branches.**
  - Not covered:
    - the bound report → completion → Telnyx path;
    - cleanup of a *ringing* call, which is the product's actual purpose;
    - a late invite after cleanup;
    - a push during an active call;
    - a duplicate UUID.
  - The test host is the CocoaPods AppHost, not Phone.app. Launch-time registration, the background mode and entitlements are not exercised.
  - The runtime also stays loaded for the 82 existing tests.
- **P5, hygiene:**
  - The extracted dylibs and the raw session copy, which includes synthetic payloads, are tarred into the QA app's evidence.
  - A checksum mismatch fails with no message.
  - `CKSIM_PROFILE` is hard-coded instead of taken from the booted runtime.
- **Verified:**
  - Test code never reaches the app: the podspec is non-recursive, and the test spec is opt-in and simulator-only.
  - Injection appears only in the generated test-host `.xctestrun`, with an allowlist.
  - No global simulator environment is set.
  - The checksum is verified before extraction.
  - Credentials are stripped.
  - The gate requires each new case exactly once.

## Mac Catalyst

See `../research/callkit-simulator-probe/maccatalyst/README.md`:

- CallKit and LiveCommunicationKit are unavailable to native macOS apps; Mac Catalyst apps can use them.
- Genuine CallKit works in a Mac Catalyst app once LaunchServices has registered the app (copied to `~/Applications`, then `lsregister`).
- Outgoing starts need validated user intent.
- Compared with the iPhone:
  - **Same:** after the newest provider is invalidated, requests fail with `unknownCallProvider` with no fallback, and a report revives it. Ending a muted call produces a system unmute that times out.
  - **Different:** no system mute echo, and no audio activation callbacks.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
