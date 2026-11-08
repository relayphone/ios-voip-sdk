# Media that lives on the main actor

`prepare` is async, so it can await a main-actor transport. In contrast, `activate()`,
`deactivate()` and `release(_:)` run synchronously on `VoIPActor`. Don't start a separate
`Task { @MainActor in … }` in each callback: those unstructured tasks can reorder activation,
deactivation and release. Yield commands into one `AsyncStream` instead, and let a single main-actor
consumer apply them in order. Track whether audio is active only in that consumer.

The SDK calls `release(_:)` exactly once for each successful preparation when the call ends or
returns to a preview, including a join that fails after preparation. A held call stays prepared.
Preparations that throw or are cancelled get no release callback; they must clean up their own
partial work. Release is synchronous on `VoIPActor`, before the call's terminal event. When audio
is still active it precedes the final `deactivate()`; when the system already deactivated audio,
that callback has already run. Release never forces the session to deactivate. Keep the session's
call configuration while any prepared call remains, and restore its earlier configuration only
once all prepared calls are released and audio is inactive, checking both callbacks.

Forward release through the same ordered stream as activation and deactivation. A delayed release
for an older attempt must not tear down a new join of the same call.

Give each preparation attempt a token and carry it through preparation and every command.
A new attempt supersedes the old one, even when an old preparation ignores cancellation.
Check the token after suspension before publishing prepared objects, and discard commands
for an older attempt. A call ID alone isn't enough: the same call can retry joining.

This adapter uses only the SDK's `CallMedia` and `Call` types plus Swift concurrency. Its
`MainActorTransport` seam represents the main-actor audio objects. Implementations must check
the attempt token before committing objects after an asynchronous preparation. The consumer
checks it again before accepting completion, and before applying audio commands. A replacement
starts inactive through the same stream; preparation never changes `audioActive` directly.
This example models one replaceable transport. Media serving several calls concurrently needs
separate preparation attempts per call and session-wide audio commands for all prepared calls.

```swift
/// A transport whose audio objects belong to the main actor.
@MainActor
protocol MainActorTransport: Sendable {
  func prepare(_ call: Call, attempt: UInt64) async throws
  func release(_ call: Call, attempt: UInt64)
  func setAudioActive(_ active: Bool)
}

@VoIPActor
final class MainActorMedia: CallMedia {
  struct AudioCommand: Sendable {
    let attempt: UInt64
    enum Kind: Sendable {
      case audio(Bool)
      case release(Call)
    }
    let kind: Kind

    init(attempt: UInt64, active: Bool) {
      self.attempt = attempt
      kind = .audio(active)
    }
    init(attempt: UInt64, releasing call: Call) {
      self.attempt = attempt
      kind = .release(call)
    }
  }

  @MainActor
  final class Consumer {
    let transport: any MainActorTransport
    let commands: AsyncStream<AudioCommand>.Continuation
    private var attempt: UInt64 = 0
    private(set) var audioActive = false

    init(
      transport: any MainActorTransport,
      commands: AsyncStream<AudioCommand>.Continuation
    ) {
      self.transport = transport
      self.commands = commands
    }

    func prepare(_ call: Call, attempt: UInt64) async throws {
      guard attempt > self.attempt else { throw CancellationError() }
      self.attempt = attempt
      // A replacement transport starts inactive. Only the consumer changes audio state.
      commands.yield(AudioCommand(attempt: attempt, active: false))
      try await transport.prepare(call, attempt: attempt)
      try Task.checkCancellation()
      guard attempt == self.attempt else { throw CancellationError() }
    }

    func consume(_ stream: AsyncStream<AudioCommand>) async {
      for await command in stream {
        guard command.attempt == attempt else { continue }
        switch command.kind {
        case .audio(let active):
          audioActive = active
          transport.setAudioActive(active)
        case .release(let call): transport.release(call, attempt: command.attempt)
        }
      }
    }
  }

  private var attempt: UInt64 = 0
  private let commands: AsyncStream<AudioCommand>.Continuation
  private let consumer: Consumer
  private let task: Task<Void, Never>

  init(transport: any MainActorTransport) async {
    let (stream, commands) = AsyncStream<AudioCommand>.makeStream()
    self.commands = commands
    let consumer = await Consumer(transport: transport, commands: commands)
    self.consumer = consumer
    task = Task { @MainActor in await consumer.consume(stream) }
  }

  deinit {
    commands.finish()
    task.cancel()
  }

  func prepare(_ call: Call) async throws {
    attempt += 1
    try await consumer.prepare(call, attempt: attempt)
  }

  func activate() {
    commands.yield(AudioCommand(attempt: attempt, active: true))
  }

  func deactivate() {
    commands.yield(AudioCommand(attempt: attempt, active: false))
  }

  func release(_ call: Call) {
    commands.yield(AudioCommand(attempt: attempt, releasing: call))
  }

  /// Drain the stream when the owner is finished with the adapter.
  func finish() async {
    commands.finish()
    await task.value
  }
}
```

The one task above owns the consumer's lifetime; it isn't recreated for each audio callback.
Keep the adapter alive while the client uses it. After stopping the client, call `finish()`
to drain queued commands. Releasing the adapter also finishes the stream and cancels its task.
The stream uses its default unbounded buffer so that activation, deactivation and release are never
dropped. The source of truth for the compiled example is
`Tests/VoIPCoreTests/MainActorMedia.swift`; its ordering and stale-attempt tests are in
`Tests/VoIPCoreTests/MainActorMediaTests.swift`.
