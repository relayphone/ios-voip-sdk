# Local media harness

A reusable host harness for software-audio journeys. It runs one local LiveKit 1.13.11 server
and one far-end participant using the pinned `@livekit/rtc-node` 1.2.2. Install dependencies with
`npm ci --prefix tools/media-test` and run with Node.js 24 or later. No application code is needed.

The host may be Apple Silicon macOS or Linux x64/arm64. macOS uses the existing digest-pinned
[Homebrew bottle](https://github.com/Homebrew/homebrew-core/blob/4583624f89284747817e229845754c7aee8227db/Formula/l/livekit.rb);
Linux uses digest-pinned [upstream release archives](https://github.com/livekit/livekit/releases/tag/v1.13.11).
Every start verifies the archive before extracting a fresh executable. Ports, room name, API key
and signing secret are generated for each run. The first participant join creates the room.

## TypeScript API

Import from this repository checkout; the same API serves iOS and Android journey runners:

```ts
import { startHarness } from './tools/media-test/harness.ts';
const host = await startHarness(privateTemporaryDirectory, fixtureId);
try {
  const appConnection = host.credentials('app'); // Pass directly to the app; never log it.
  await host.act({ type: 'publish', markerId: `${fixtureId}:toDevice` });
  await host.act({ type: 'capture' }); // Start a fresh bounded observation window.
  // Connect the app using appConnection and await the shared contract's phase gates.
  const { receiver, capture } = host.observation();
  await host.act({ type: 'hold' });
  await host.act({ type: 'reconnect' }); // Real server-driven peer media-session rebuild.
  await host.act({ type: 'leave' });
} finally {
  await host.stop(); // Idempotent; awaits real process exit even after peer failure.
}
```

`capture` resets received PCM, sample count, energy and receiver counter rows, and retires pending statistics from the previous capture generation. Captures include real receiver transport snapshots; duplicate timestamps from the same stream are ignored. `stop` also awaits the statistics poller. Observations retain at most three seconds
of mono 48 kHz PCM, plus independent track/reader/connection health. Empty PCM does not establish
silence: retain the shared contract's coverage and liveness checks. `publish` resets the unchanged
1020 ms tones-v2 emission to its beginning. `hold` replaces the far-end source with silent PCM;
it does not alter the app's publication or bypass its mute/hold gates. `leave` disconnects the
far-end participant. It does not claim to interrupt the app's server transport for reconnect tests.
`reconnect` uses the pinned SDK's full-reconnect protocol request to the real server, which
replaces the peer's media session and republishes its tracks. It is bounded to ten seconds;
`observation().reconnect` retains the attempt UUID, shared peer clock, request/event times and
publication SIDs, including partial evidence on failure. A failed or timed-out attempt retires
reconnect control until the harness is stopped; late SDK callbacks cannot qualify a later attempt.
These raw connection events are insufficient to pass recovery. Independently verify actual
publication removal/recreation and require a fresh marker through the shared contract in both
directions, including clean receiver counters and complete post-roll. Phase capture resets
preserve reconnect evidence; PCM from retired readers is excluded from the current capture,
while late PCM remains in the independent lifecycle observation.
Use a fresh marker identity and phase observation for recovery assertions in the consuming journey.

Do not call process-wide rtc-node `dispose()` until all harnesses and other rtc-node users in the
process have stopped. The CLI owns its own process and performs this final disposal itself.

`observation().lifecycle` also retains bounded, timestamped remote audio-publication and
participant events on a process-unique `peerMonotonic` clock. Its `afterDisconnect` capture
starts only after all observed audio publications and that participant have left. It retains
late PCM, even after a reconnect, independently of ordinary phase capture resets. This is raw
terminal evidence, not a passed flag: consumers check identities, deadline, continued peer
connection, subsequent reconnect events, dropped-event/PCM overflow counters and absence of
any emitted phase's marker over their observation interval. An empty capture does not assert silence.

## JSON CLI

The CLI requires hosted GitHub Actions because its credentials and controls can drive an iOS
simulator media fixture. The [running rules](../../docs/media-hook-feasibility.md#running-media-journeys)
describe the host audio guard and the future isolated lease requirement.

Run these commands from one long-lived journey runner or shell. `start` returns JSON status and
keeps the service alive until `stop`, runner death, a termination signal or its 180-second safety
limit. The service watches the invoking runner PID; independent CI steps are separate lifetimes.

```sh
node tools/media-test/cli.ts start /tmp/my-media-run
node tools/media-test/cli.ts status /tmp/my-media-run
node tools/media-test/cli.ts act /tmp/my-media-run '{"type":"publish","markerId":"run:toDevice"}'
node tools/media-test/cli.ts act /tmp/my-media-run '{"type":"capture"}'
node tools/media-test/cli.ts observation /tmp/my-media-run
node tools/media-test/cli.ts act /tmp/my-media-run '{"type":"hold"}'
node tools/media-test/cli.ts act /tmp/my-media-run '{"type":"reconnect"}'
node tools/media-test/cli.ts act /tmp/my-media-run '{"type":"leave"}'
node tools/media-test/cli.ts stop /tmp/my-media-run
```

`credentials` returns only a `credentialsFile` path. Read that private JSON file to configure the
app, then remove it; tokens and signing secrets are never printed. Directories are mode 0700 and
control/credential files mode 0600. Do not publish or upload the run directory. Errors also use
JSON and a nonzero exit status. `stop` recovers stale state after a crash and waits for the server
supervisor to exit; it never kills a process merely because a stale PID file exists.

A separate server supervisor stops the server when its IPC owner disconnects, including SIGKILL
of the runner's harness process. Peer/native cleanup has deadlines; server ownership survives a
stalled FFI shutdown. Tests use the real pinned server and real peers for markers, capture, silent
hold, room leave, occupied ports, archive corruption and both runner/daemon crash cleanup.

The example feasibility adapter uses this API while retaining its marker, post-roll, processing,
receiver-coverage, output/publication mute, missing-tap, activation and teardown gates.

The pre-mute receiver/publication checks select the first full one-second observer
window within the existing result deadline. A scheduling gap over 250 ms retires
that attempt as `unobserved`; it does not renew the budget. Receipts retain every
attempt's monotonic ticks, observed duration, gaps and scheduler lag in
`farEnd.receiverWindows`, grouped by control step. Missing connection, reader or
track fails immediately, including on the tick returning from a gap. Marker and
transport-counter failures still fail their existing gates without retry.

## Native journey control

`prepareNativeJourney(documentsDirectory, options)` prepares the reference example's file
mailbox before launch, removing prior journey control files. After launch, `connect(budget)`
acknowledges the native session UUID and monotonic clock. `request(action, budget)` serializes
typed phase, snapshot, mute, hold and terminal controls. Each budget carries an absolute host
monotonic deadline and an abort signal; queueing and polling never extend it.

The mailbox binds each reply to the command UUID, fixture, conversation, session, phase and
native clock. A new phase sends the shared tones-v2 marker's frequencies. Other commands
must preserve that phase's native anchor. A failure or cancellation after command publication
retires the mailbox because native state may already have changed. The caller still owns app,
peer and server cleanup. `close` acknowledges the native control loop's exit; it does not prove
media teardown.

Replies retain the original snapshot as untrusted `evidence`. This transport validates identity
and timing envelopes only. It does not certify PCM coverage, processing, SDK end state or native
release; those must pass the shared contract and terminal oracle separately. The existing
feasibility runner is unchanged; the complete shared-contract journey remains to be connected.

### Prebuilt native tests

`run-native-tests.ts` runs the standalone `.xctest` bundle described by a single-target
`.xctestrun` specification through the selected simulator's `xctest` host. Build the
small `SimulatorTestHost.swift` executable with the simulator SDK first. The wrapper
owns a simulator process group and reports its PID before replacing itself with xctest;
the TypeScript supervisor owns the host command group. Both are stopped on timeout,
interruption or output overflow. Confirmed cleanup means no live group members;
non-running zombies can await their system reaper.

A passed-test log line never replaces a successful native process exit. The launcher
also requires a nonempty Swift Testing result and confirmed cleanup. App-hosted/UI
targets and embedded test selections are rejected. The optional final CLI argument
selects a suite as `Module.Suite`. Fixture environment and built-product search paths
are taken from the specification, including when Products were relocated.

The existing native execution deadline remains unchanged. Each invocation retains a
bounded stdout/stderr logs and a small launcher receipt, without command arguments or environment
values. Stdout stays separate so decoder diagnostics cannot split structured native receipts. A timed-out observation remains failed. A caller must not reuse a simulator
when cleanup is unconfirmed; recover that owned simulator before starting another test.

The optional video peer uses the same authenticated Room and cleanup owner as the audio peer.
Use a UUID fixture ID, then `await harness.openVideo(hostClockID)` for one publication epoch.
Arm `observe(participant, epoch)` before the app publishes; its decoded observation binds the
actual participant and publication SID. `publish(epoch)` supplies reverse-direction camera
frames at the frozen 160×120/10 fps profile; `hold()` unpublishes while counters keep advancing.
`stop()` freezes the source ledger before awaiting pacing and publication work. A later epoch
uses a new phase instance after retaining the prior drain evidence. Failed or closed instances
cannot qualify a window. The caller retains original source ledgers and confirmed SDK anchors;
`assessVideo` checks participant/SID and both clock IDs, using full host/native bracket uncertainty.
The terminal event time is explicit and independent of the producer stop timestamp.

`VIDEO_PEER_INTEGRATION=1 node --test tools/media-test/video-peer.integration.test.ts` runs
real VP8 encode/decode in both directions through the fixture server with the audio peer active,
then verifies held source progress and joined stop. The native-media workflow runs this check
before booting its simulator. Swift and TS marker tests share a byte-identical pixel vector;
these contract tests precede the SDK-driven app journey adapter.
