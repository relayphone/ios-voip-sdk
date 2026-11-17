import Testing

@testable import MediaJourneyProtocol

@MainActor struct VideoPolicyTests {
  final class Transport: MediaVideoTransport {
    enum Failure: Error { case publication }
    var epochs: [UInt32] = []
    var running = false
    var muted = false
    var stops = 0
    var failStart = false
    var pauseStart = false
    var resumeStart: CheckedContinuation<Void, Never>?
    func start(epoch: UInt32, muted: Bool) async throws {
      running = true
      epochs.append(epoch)
      if pauseStart { await withCheckedContinuation { resumeStart = $0 } }
      if failStart { throw Failure.publication }
      self.muted = muted
    }
    func mute() async throws { muted = true }
    func stop() async throws {
      running = false
      stops += 1
    }
  }
  @Test func initialAudioSameValueAndVideoDowngrade() async throws {
    let media = Transport()
    let video = MediaVideoPolicy(transport: media)
    try await video.apply(hasVideo: false, held: false)
    #expect(!media.running && media.epochs.isEmpty && media.stops == 0)
    try await video.apply(hasVideo: true, held: false)
    try await video.apply(hasVideo: true, held: false)
    #expect(media.epochs == [1])
    #expect(media.running)
    try await video.apply(hasVideo: false, held: false)
    #expect(!media.running)
    #expect(media.stops == 1)
    try await video.apply(hasVideo: true, held: false)
    #expect(media.epochs == [1, 2])
  }
  @Test func holdGatesPublicationWithoutStoppingAndResumeUsesANewEpoch() async throws {
    let media = Transport()
    let video = MediaVideoPolicy(transport: media)
    try await video.apply(hasVideo: false, held: true)
    #expect(!media.running)
    try await video.apply(hasVideo: true, held: false)
    try await video.apply(hasVideo: true, held: true)
    #expect(media.running && media.muted)
    #expect(media.stops == 0)
    try await video.apply(hasVideo: true, held: true)
    #expect(media.stops == 0)
    try await video.apply(hasVideo: true, held: false)
    #expect(media.running && !media.muted)
    #expect(media.epochs == [1, 2])
    #expect(media.stops == 1)
  }
  @Test func endIsTerminalAndCleanupSurvivesAPartiallyCreatedSource() async throws {
    let media = Transport()
    media.failStart = true
    let policy = MediaVideoPolicy(transport: media)
    await #expect(throws: Transport.Failure.self) {
      try await policy.apply(hasVideo: true, held: false)
    }
    #expect(media.running)
    await #expect(throws: Transport.Failure.self) {
      try await policy.apply(hasVideo: true, held: false)
    }
    #expect(media.epochs == [1])
    try await policy.apply(hasVideo: false, held: false, ended: true)
    #expect(!media.running)
    #expect(policy.state == .ended)
    await #expect(throws: MediaVideoPolicy.Failure.ended) {
      try await policy.apply(hasVideo: true, held: false)
    }
  }
  @Test func upgradeWhileHeldStartsOnlyTheUpstreamSource() async throws {
    let media = Transport()
    let video = MediaVideoPolicy(transport: media)
    try await video.apply(hasVideo: true, held: true)
    #expect(media.running && media.muted)
    #expect(video.state == .held)
    #expect(media.epochs == [1])
    try await video.apply(hasVideo: true, held: false)
    #expect(media.epochs == [1, 2])
    #expect(media.running && !media.muted)
  }
  @Test func concurrentTerminalJoinsAnEarlierTransition() async throws {
    let media = Transport()
    media.pauseStart = true
    let video = MediaVideoPolicy(transport: media)
    let start = Task { try await video.apply(hasVideo: true, held: false) }
    let deadline = ContinuousClock.now + .seconds(2)
    while media.resumeStart == nil, ContinuousClock.now < deadline { await Task.yield() }
    let resume = try #require(media.resumeStart)
    let end = Task { try await video.apply(hasVideo: false, held: false, ended: true) }
    await Task.yield()
    #expect(media.stops == 0)
    resume.resume()
    try await start.value
    try await end.value
    #expect(!media.running)
    #expect(media.stops == 1)
    #expect(video.state == .ended)
  }
}
