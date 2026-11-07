import VoIPCore

/// A transport whose audio objects belong to the main actor.
@MainActor
protocol MainActorTransport: Sendable {
  func prepare(_ call: Call, attempt: UInt64) async throws
  func setAudioActive(_ active: Bool)
}

/// The same adapter shown in CallMedia's documentation.
@VoIPActor
final class MainActorMedia: CallMedia {
  struct AudioCommand: Sendable {
    let attempt: UInt64
    let active: Bool
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
        audioActive = command.active
        transport.setAudioActive(audioActive)
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

  /// Drain the stream when the owner is finished with the adapter.
  func finish() async {
    commands.finish()
    await task.value
  }
}
