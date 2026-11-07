import Testing
@testable import VoIPCore

@MainActor
private final class MainActorTransportFake: MainActorTransport {
  var audio: [Bool] = []
  var attempts: [UInt64] = []
  var waiting: CheckedContinuation<Void, Never>?
  var suspendNextPreparation = false

  func prepare(_ call: Call, attempt: UInt64) async throws {
    attempts.append(attempt)
    if suspendNextPreparation {
      suspendNextPreparation = false
      await withCheckedContinuation { waiting = $0 }
    }
  }

  func setAudioActive(_ active: Bool) {
    audio.append(active)
  }
}

@Suite(.timeLimit(.minutes(1))) struct MainActorMediaTests {
  @Test @MainActor func audioCommandsKeepTheirOrder() async throws {
    let transport = MainActorTransportFake()
    let media = await MainActorMedia(transport: transport)
    try await media.prepare(try Start.preparingAnswer.state().call)
    await sendAudioCommands(media)
    await media.finish()
    #expect(transport.audio == [false, true, false, true, false])
  }

  @VoIPActor
  private func sendAudioCommands(_ media: MainActorMedia) {
    media.activate()
    media.deactivate()
    media.activate()
    media.deactivate()
  }

  @Test @MainActor func oldPreparationCannotCompleteANewerAttempt() async throws {
    let transport = MainActorTransportFake()
    transport.suspendNextPreparation = true
    let media = await MainActorMedia(transport: transport)
    let call = try Start.preparingAnswer.state().call
    let old = Task { try await media.prepare(call) }
    while transport.waiting == nil { await Task.yield() }
    try await media.prepare(call)
    transport.waiting?.resume()
    transport.waiting = nil
    await #expect(throws: CancellationError.self) { try await old.value }
    await media.activate()
    await media.deactivate()
    await media.finish()
    #expect(transport.audio.suffix(3) == [false, true, false])
    #expect(transport.attempts == [1, 2])
  }

  @Test @MainActor func consumerIgnoresCommandsFromAnOldAttempt() async throws {
    let transport = MainActorTransportFake()
    let (stream, commands) = AsyncStream<MainActorMedia.AudioCommand>.makeStream()
    let consumer = MainActorMedia.Consumer(transport: transport, commands: commands)
    let call = try Start.preparingAnswer.state().call
    try await consumer.prepare(call, attempt: 1)
    commands.yield(.init(attempt: 1, active: true))
    try await consumer.prepare(call, attempt: 2)
    commands.yield(.init(attempt: 1, active: false))
    commands.yield(.init(attempt: 2, active: true))
    commands.yield(.init(attempt: 1, active: false))
    commands.yield(.init(attempt: 2, active: false))
    commands.finish()
    await consumer.consume(stream)
    #expect(transport.audio == [false, true, false])
    #expect(!consumer.audioActive)
    await #expect(throws: CancellationError.self) {
      try await consumer.prepare(call, attempt: 1)
    }
  }
}
