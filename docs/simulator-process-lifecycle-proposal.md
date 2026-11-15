# Proposal: cold launches and locked-answer journeys

Status: proposed. This document requests a design decision before implementation.
It describes simulator-only test infrastructure; it changes no application behavior.

## Existing behavior and the missing observations

`cksim push --launch` already verifies that the app has no running launch service,
atomically stages a bounded, expiring envelope, and launches the installed app.
The app must activate the runtime itself. The runtime claims the envelope once;
PushKit interposition waits for a registry with a delegate and VoIP desired types
before delivering it on the registry's queue. This exercises a real new process,
but is an explicit simulator launch, not an APNs launch or a measurement of iOS
launch eligibility. It currently accepts one delivery and rejects delivery faults.

Running-app pushes already support delay, drop and duplicate/spacing controls,
per-delivery reporting obligations, and correlation IDs. Status and the journal
retain system/SDK lifecycle times and actual first-packet observations. They do
not establish application-handler readiness, lock state, execution assertions,
or process suspension. An answered system call is not evidence of connected media.

The SDK already takes a short UIKit background assertion around push processing:
completion plus a two-second settle period, capped at ten seconds from arrival
(see [the background-time decision](adr/0011-background-time-after-pushes.md)).
Those are SDK bounds, not an iOS grant duration or coverage through media connect.
App-owned claim/connect work may need an assertion of its own.

## Evidence and limits

The supplied iPhone 13 observations motivate two regression scenarios: a cold
launch with late JavaScript attachment displayed an answered call without media
until the configured 27-second Join timeout; a locked answer displayed
“Audio connecting…” and failed after the app ended its background task after an
HTTP claim. Holding that task through media connection fixed the latter run.
The OS version and exact grant/suspension times for these two observations are
not established by the supplied record. Do not label them measured iOS 27.0
profile constants. The separately recorded iPhone 13 / iOS 27.0 and 27.1 push
reporting measurements remain the existing reporting rules.

Apple documents that [PushKit wakes or launches the app and gives it time to
respond](https://developer.apple.com/documentation/pushkit), including notifying
the user and connecting to the call service. It does not specify a universal
post-answer connection allowance. Apple's [PushKit response guidance](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)
also distinguishes a system answer from an established connection. Its action
examples use CallKit; they are not evidence of a LiveCommunicationKit grant time.

The current SDK has distinct placement, media-preparation, audio-activation and
connection deadlines. Defaults include two seconds for media preparation and
30 seconds for connection. The historical “27-second Join” must therefore be
an explicit fixture configuration with its deadline anchor recorded, not a new
runtime timeout or a claim about the SDK default.

## Process control and cold-launch faults

Proposed CLI controls:

- `cksim process kill --cause abrupt`: kill the verified target process without
  cleanup, for a cold-recovery test. This models loss of memory, not real jetsam
  selection or a user force-quit delivery policy.
- `cksim process kill --cause user-requested`: use simulator termination and
  record the test's intent. It still does not reproduce SpringBoard's persistent
  user force-quit state. `push --launch` remains an explicit override to launch.
- `cksim push --launch` accepts the existing `--delay-ms`, `--drop`,
  `--duplicate` and `--spacing-ms`, with the same bounds and count semantics as
  running-app pushes. A duplicate count means additional deliveries.

No process-wide signal is sent using an unverified stale PID. The host checks
simulator, bundle, run ID and live service PID immediately before an operation;
identity changes fail the command. A kill receipt records the old process exit
and a subsequent launch must have a new process/run identity. A failed kill
prevents staging. A stopped app is a valid input to launch without a preceding kill.

Use a typed version-two `PushLaunchEnvelope` containing `PushDeliveryFaults`, a
request ID and stable delivery IDs; retain decoding of version one. Reuse
`PushDeliverySchedule` and `PreparedPushPayload`, not a second fault scheduler.
Validate and bridge the entire payload before scheduling; no partial deliveries
on invalid input. Keep existing exclusive claim, owner/mode checks, size limits,
expiration checks, and receipt hashes. A corrupted or stale envelope fails closed.

The fault delay starts at the host's accepted request, before launch. The host
waits until that monotonic due time, then stages and launches. Thus a delayed push
does not wake the process early. `--drop` records a terminal dropped delivery and
never stages, launches, calls a delegate, or creates a reporting obligation.
Duplicates use offsets from the first delivery's actual delegate entry, ensuring
startup latency cannot collapse them into a burst. Registry readiness is not app
handler readiness. Every delivered duplicate gets its own existing reporting
obligation; a report against an existing UUID still cannot satisfy a new obligation.

After launch, runtime-owned scheduling cancels on process exit. Undelivered
duplicates are recorded as cancelled by the host, not silently replayed into a
later unrelated launch. A new push request is required for a further cold launch.
Launch failure, missing registry, envelope expiration, process death and handler
absence are distinct outcomes. Keep the envelope's existing 30-second freshness
window separate from registry/handler observation timeouts and SDK deadlines.

## Launch and readiness timings

Record these boundaries using the journal's existing monotonic uptime basis:

| Boundary | Owner and meaning |
| --- | --- |
| `process.launchRequested` | Host, immediately before the simulator launch request |
| `process.entered` | Earliest Debug simulator entry marker; app execution began |
| `runtime.ready` | Runtime hooks/mailbox available |
| `push.registryReady` | First registry with a live delegate and VoIP types, on its delivery queue |
| `app.handlerReady` | Native acknowledgement of the application's attached handler generation |
| `push.delivered` | Actual delegate entry for this delivery |
| `process.exited` | Host-confirmed exit, with requested cause or unknown cause |

Report launch-request-to-registration and launch-request-to-handler-ready, plus
process-entry-relative versions. Label the former as including simulator launch
service latency. The entry marker cannot claim to include pre-entry dyld time.
Use process identity and handler generation, not a timestamp from the preceding
run. A missing boundary stays missing with a timeout reason; zero is not a default.

Extend the existing typed journal representation and `cksim events` reader with
host process segments correlated to the runtime segment by run ID. Use one writer
per segment and merge by monotonic time with producer sequence as a stable tie
break; never concurrently append host rows into a runtime's sequence. `cksim
status --json` adds a process-lifecycle projection with optional timings and
explicit provenance. This remains one event view in the CLI and Inspector.
Persist host intent before kill; flush acknowledged runtime boundaries before a
host suspension. Host segments allow drop and prelaunch failure to be visible
when no runtime exists. Receipts and generated journey results remain CI artifacts.

Proposed boundaries: `CKSimProtocol/ProcessLifecycle.swift` owns Codable/Sendable
identities, milestones and outcomes; `CKSimTool/ProcessLifecycle.swift` owns target
verification, launch/kill/watch and host segments; existing `PushLaunch.swift`
stages the envelope. `Engine/RuntimeProcessLifecycle.swift` accepts runtime
observations. Existing PushKit hooks publish registry readiness; no SDK or app
handler is inferred from registry registration. Expo's native attachment
acknowledgement publishes handler readiness through a Debug simulator SPI only.
A native test handler uses the same explicit readiness marker after installation.

## Late application handler journey

Add a bundled journey configuration in the example's test-only entry point with
typed `handlerAttachDelayMS`, `connectDeadlineMS`, and scenario identity. The
journey driver writes it before launch. An injectable-clock test coordinator
waits before invoking the ordinary handler subscription API and records the
native acknowledgement. Product app code has no runtime detection, environment
branch, or delay flag; no change to production handler defaults or deadlines.
Use the JavaScript-media path, not registered native media, for this scenario.

The fixture configures connection timeout to 27 seconds and attaches the handler
after that deadline. Report the native push promptly, answer through the ordinary
system control, allow the normal no-op preparation/audio activation path, and
withhold the application's media connection. Assert `answer/performed` followed
by connecting, no `connected`, no positive packet observations, and eventual
connection-deadline failure with the configured anchor. Absence of packet events
alone proves no telemetry, so a fake media transport also asserts zero media
start/packet activity. Real media coverage uses its existing receiver evidence.

This reproduces the answered-without-media symptom in the system-state model;
CI does not claim a pixel-identical green indicator or lock-screen timer. Current
incoming answers do not use the outgoing/preview-Join handler-placement gate.
Do not change that behavior to manufacture a Join timeout. Call the fixture's
27-second result a connection timeout after answer, with its exact SDK failure
reason. A separate preview-Join test covers placement timeout and return to
preview, which is a different outcome from an incoming call disappearing.
A handler attached before the configured connection deadline must connect;
a late attachment after failure cannot resurrect the call or reuse an expired action.

## Locked-answer execution model

Model three independent axes: lock (`locked`/`unlocked`), application activity
(`foreground`/`background`), and execution (`running`/`suspended`/`exited`).
Locking alone is not a suspend command. Protected-data access is a fourth,
separate concern: [UIKit's protected-data documentation](https://developer.apple.com/documentation/uikit/uiapplication/isprotecteddataavailable)
explains that protected files may be unavailable while locked. This proposal
does not emulate file/keychain protection or assert a universal unlock history.

| Potential execution reason while locked | Documented basis and modeling decision |
| --- | --- |
| Incoming PushKit delivery | Temporary wake to report/connect; duration unspecified. Profile input marks the end of this model grant. Push completion is an observed boundary, not proof all execution immediately ends. |
| UIKit background task | A bounded, best-effort assertion requested before critical work; can fail or expire. Track identifiers independently and balance each end. |
| Active call audio | Appropriate audio category plus background-audio capability supports ongoing audio with screen locked. Require observed audio activation and actual media activity in the fixture; a ringing/answered UI or entitlement alone is not a grant. |
| Other system work | BGTaskScheduler, background URLSession, notifications and system action processing have their own semantics. Treat unobserved execution reasons as unknown; do not assert exhaustive iOS scheduling fidelity. |

[UIKit's background sequence](https://developer.apple.com/documentation/uikit/about-the-background-execution-sequence)
allows event-driven background launch followed by suspension. A finite assertion
requests additional runtime, [may fail and is granted asynchronously](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)),
and must be ended or expired. [Remaining background time](https://developer.apple.com/documentation/uikit/uiapplication/backgroundtimeremaining)
is not a stable entitlement. Do not assign iOS an invented five-, ten-, or
30-second lock-screen grant. Apple's foreground-transition discussion of five
seconds is not a new PushKit or locked-answer deadline.

[Audio category documentation](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionCategoriesandModes/AudioSessionCategoriesandModes.html)
describes play-and-record under lock with the audio background mode. LCK's
[audio-activation callback](https://developer.apple.com/documentation/livecommunicationkit/conversationmanagerdelegate/conversationmanager(_:didactivate:))
and [joined state](https://developer.apple.com/documentation/livecommunicationkit/conversation/state-swift.enum/joined)
are useful observations; neither documents a general-purpose preconnect execution
lease. An HTTP response or ended claim task does not itself grant continued CPU.

Propose an opt-in deterministic `LockedAnswerScenario` in test configuration,
with explicit PushKit wake end, assertion expiry and media-ready boundaries.
`Engine/RuntimeExecutionPolicy.swift` is a pure typed reducer with injected
`Clock`/`Duration`. It outputs running/suspend-eligible decisions with all active
grant IDs and provenance. `VoIPTesting/BackgroundExecutionScenario.swift` provides
fakes and failure controls. Every unmeasured duration is marked unverified in the
profile; normal journeys gain no automatic locked scheduling rule.

In the first implementation, the fixture's background-execution adapter calls
real UIKit begin/end and publishes typed observations through the Debug SPI.
The existing SDK push assertion adapter publishes the same observations. A test
can expire or deny its own fake adapter assertion; it cannot claim to expire an
unknown real system assertion. No successful HTTP result is substituted for an
assertion end. The early-end and hold-through-connect variants run the same
claim/media code, differing only in the test-injected assertion lifetime.

When a background scenario has no modeled grant, the host journals the decision,
verifies process identity and sends SIGSTOP to the entire app. SIGCONT on an
explicit host wake resumes it. This pauses Swift, JS and the runtime together;
pausing only JS or selected callbacks would conceal native work. The host stays
running, enforces its own cleanup deadline, records stop/resume/exit, and always
resumes before cleanup/termination. While stopped, mailbox commands cannot be
acknowledged. The host must not wait for an in-process timeout to resume it.

A stopped SDK cannot execute a deadline callback. Assert the elapsed deadline
only after resume, then require the real SDK to fail before accepting late media;
record both the due time and callback time. Do not emit a fictional in-process
SDK expiry while stopped. Any system-owned action timeout observed by the host
is a distinct event. Exact suspension lag, protected data, jetsam and LCK service
assertions remain device-only qualification; this is a deterministic starvation
model, not an emulator of the iOS execution scheduler.

### Background-task interposition decision

Do not use global UIKit method interposition to decide execution in this first
implementation. Observing begin/end calls can aid diagnostics, but it cannot see
all system assertions or prove a background task was granted. Replacing task IDs,
expiration handlers, `backgroundTimeRemaining`, or real UIKit completion semantics
would make the runtime's scheduler circular and change application behavior.
Even transparent forwarding needs both begin overloads, safe reentrancy,
threading, expiration/end races, invalid IDs, nested tasks, and exactly-once
handler delivery. It also risks interaction with other swizzlers.

Explicit test adapters plus real process stop/resume give a bounded model that
can be tested. Arbitrary third-party UIKit assertions are unsupported/unknown in
this mode; the command must refuse a conformance claim when grant coverage is
unknown. A later observational interposer requires a separate design decision
and tests; it must not silently turn all UIKit calls into synthetic grants.

## Validation and implementation slices after approval

1. Cold-launch faults and milestones: protocol/envelope decoder and launch
   scheduler tests, malformed/stale envelope controls, process identity tests;
   simulator kill-launch journey verifying new PID/run, both readiness timings,
   drop without launch, delay without early launch, and independent duplicate
   reporting obligations. Missing registration and handler readiness must fail.
2. Late-handler fixture: host tests with injected clocks, then bundled-example
   cold-launch controls before/after the configured 27-second connection deadline,
   and a distinct preview-Join placement-expiry test. No product deadline changes.
3. Opt-in locked execution model: reducer tests for overlapping assertions,
   expiration/denial, release ordering, audio grant handoff, unknown coverage,
   repeated lock/unlock, and stale process identity. External host tests prove
   heartbeat stops under SIGSTOP, resumes under SIGCONT, and cleanup survives a
   driver failure. Paired early-end/held-through-connect journeys must differ in
   actual media/packet outcomes; an intentionally unprotected variant must fail.

Each slice stays a separate reviewable PR under the normal size limit. Native
integration is covered by existing simulator CI; host tests use Swift Testing and
Node's test runner through real code/fakes, never source-text assertions. Device
revalidation of locked execution would require an explicitly assigned device.
No simulator or device experiment is needed to review this proposal.

## Decision requested

Approve the three slices and the distinctions above: explicit cold-launch override
rather than claimed force-quit eligibility; configured connection expiry rather
than a fabricated universal Join deadline; test adapters and external suspension
rather than global background-task interposition. Implementation begins only
after this proposal is accepted.
