import Testing
import VoIPTesting

@_spi(MediaTransport) @_spi(Simulator) @testable import VoIPCore

@VoIPActor
private struct SilentMedia: CallMedia {
  func prepare(_ call: Call) async throws {}
  func activate() {}
  func deactivate() {}
}

@VoIPActor
private final class PacketMedia: CallMedia {
  let events = AsyncStream<MediaTransportEvent>.makeStream()
  func transportEvents() -> AsyncStream<MediaTransportEvent> { events.stream }
  func prepare(_ call: Call) async throws {}
  func activate() {}
  func deactivate() {}
}

extension EngineTests {
  @Test @VoIPActor func defaultTransportIsSilent() async {
    var iterator = SilentMedia().transportEvents().makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  #if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
    @Test @VoIPActor func packetStreamReachesSimulatorWithoutChangingIdentityOrTime() async {
      let media = PacketMedia()
      let received = AsyncStream<MediaTransportEvent>.makeStream()
      SimulatorTransport.install { received.continuation.yield($0) }
      defer { SimulatorTransport.install(nil) }
      let engine = CallEngine(
        framework: FakeCallingFramework(), media: media, audio: nil, pushSource: nil,
        configuration: VoIPConfiguration(), clock: TestClock(), subscribers: Subscribers(),
        publish: { _ in })
      engine.attach()
      let event = MediaTransportEvent(
        callID: callID, kind: .firstPacketReceived, observedAt: .now)
      media.events.continuation.yield(event)
      var iterator = received.stream.makeAsyncIterator()
      #expect(await iterator.next() == event)
      media.events.continuation.finish()
    }
  #endif

  @Test @VoIPActor func releasingEngineCancelsTransportSubscription() async {
    let media = PacketMedia()
    let terminated = AsyncStream<Void>.makeStream()
    media.events.continuation.onTermination = { _ in
      terminated.continuation.yield(())
      terminated.continuation.finish()
    }
    var engine: CallEngine? = CallEngine(
      framework: FakeCallingFramework(), media: media, audio: nil, pushSource: nil,
      configuration: VoIPConfiguration(), clock: TestClock(), subscribers: Subscribers(),
      publish: { _ in })
    engine?.attach()
    engine = nil
    var iterator = terminated.stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
  }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct MediaPacketSamplerTests {
  @Test func packetKindsSupportValueComparisonAndConsumerFallback() {
    let received = MediaTransportEvent.Kind.firstPacketReceived
    let sent = MediaTransportEvent.Kind.firstPacketSent
    #expect(received != sent)
    #expect(Set([received, received, sent]).count == 2)
    // A consumer can understand one kind and leave every other kind to its fallback.
    func handles(_ kind: MediaTransportEvent.Kind) -> Bool {
      switch kind {
      case .firstPacketReceived: return true
      default: return false
      }
    }
    #expect(handles(received))
    #expect(!handles(sent))
  }

  @Test(arguments: [(Duration.zero, Duration.seconds(1)), (.seconds(1), .zero)])
  func invalidBoundsNeverSample(bounds: (Duration, Duration)) async {
    var count = 0
    await MediaPacketSampler.observe(
      callID: callID, clock: TestClock(), interval: bounds.0, timeout: bounds.1,
      sample: { _, _ in
        count += 1
        return (true, true)
      }, emit: { _ in })
    #expect(count == 0)
  }

  @Test func waitsForEngineReadinessBeforeReadingStatistics() async throws {
    let clock = TestClock()
    var ready = false
    var count = 0
    let task = Task {
      await MediaPacketSampler.observe(
        callID: callID, clock: clock, ready: { ready },
        sample: { _, _ in
          count += 1
          return (true, true)
        }, emit: { _ in })
    }
    try await clock.waitForSleepers()
    #expect(count == 0)
    clock.advance(by: .milliseconds(250))
    try await clock.waitForSleepers()
    #expect(count == 0)
    ready = true
    clock.advance(by: .milliseconds(250))
    await task.value
    #expect(count == 1)
  }

  @Test func wakingAfterDeadlineDoesNotSampleAgain() async throws {
    let clock = TestClock()
    var count = 0
    let task = Task {
      await MediaPacketSampler.observe(
        callID: callID, clock: clock,
        sample: { _, _ in
          count += 1
          return (false, false)
        }, emit: { _ in })
    }
    try await clock.waitForSleepers()
    clock.advance(by: .seconds(60))
    await task.value
    #expect(count == 1)
  }
  @Test func directionsStopIndependentlyAndFinishAfterBoth() async throws {
    let clock = TestClock()
    var requests: [(Bool, Bool)] = []
    var events: [MediaTransportEvent] = []
    let task = Task {
      await MediaPacketSampler.observe(
        callID: callID, clock: clock,
        sample: { received, sent in
          requests.append((received, sent))
          return (true, requests.count >= 2)
        }, emit: { events.append($0) })
    }
    try await clock.waitForSleepers()
    #expect(events.map(\.kind) == [.firstPacketReceived])
    clock.advance(by: .milliseconds(250))
    await task.value
    #expect(requests.count == 2)
    #expect(requests[0].0 && requests[0].1)
    #expect(!requests[1].0 && requests[1].1)
    #expect(events.map(\.kind) == [.firstPacketReceived, .firstPacketSent])
    #expect(events.allSatisfy { $0.callID == callID })
    #expect(events[0].observedAt <= events[1].observedAt)
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func unknownDirectionStaysAbsentAndDeadlineCapsSampling() async throws {
    let clock = TestClock()
    var count = 0
    var events: [MediaTransportEvent] = []
    let task = Task {
      await MediaPacketSampler.observe(
        callID: callID, clock: clock, interval: .seconds(2), timeout: .seconds(3),
        sample: { _, _ in
          count += 1
          return (false, true)
        }, emit: { events.append($0) })
    }
    try await clock.waitForSleepers()
    #expect(count == 1)
    clock.advance(by: .seconds(1))
    #expect(count == 1)
    clock.advance(by: .seconds(1))
    try await clock.waitForSleepers()
    #expect(count == 2)
    clock.advance(by: .seconds(1))
    await task.value
    #expect(count == 2)
    #expect(events.map(\.kind) == [.firstPacketSent])
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func cancellationStopsSamplingWithoutInventingPackets() async throws {
    let clock = TestClock()
    var count = 0
    var events: [MediaTransportEvent] = []
    let task = Task {
      await MediaPacketSampler.observe(
        callID: callID, clock: clock,
        sample: { _, _ in
          count += 1
          return (false, false)
        }, emit: { events.append($0) })
    }
    try await clock.waitForSleepers()
    task.cancel()
    await task.value
    clock.advance(by: .seconds(60))
    #expect(count == 1)
    #expect(events.isEmpty)
    #expect(clock.pendingSleepCount == 0)
  }
}
