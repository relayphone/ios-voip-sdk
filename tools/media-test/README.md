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
