import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  @Suite("Confirmed video") @MainActor
  struct VideoTests {
    @Test(arguments: VideoChangeSource.allCases)
    func appAndServerChangesFollowSystemReports(source: VideoChangeSource) async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      try await h.connect()
      let before = await h.records.count
      try await h.client.setVideo(callID, enabled: true, source: source)
      #expect(h.client.calls.first?.hasVideo == true)
      #expect(try await h.next() == .videoChanged(callID, true, source))
      #expect(await h.audio.configuredCalls.last?.hasVideo == true)
      guard case .update(let reported)? = await h.records.last else {
        Issue.record("Expected a system report")
        return
      }
      #expect(reported.hasVideo)
      try await h.client.setVideo(callID, enabled: true, source: source)
      #expect(await h.records.count == before + 1)
      try await h.expectNoEvents()
      try await h.client.setVideo(callID, enabled: false, source: source)
      #expect(h.client.calls.first?.hasVideo == false)
      #expect(try await h.next() == .videoChanged(callID, false, source))
      #expect(await h.audio.configuredCalls.last?.hasVideo == false)
    }

    @Test func refusedConfirmationDoesNotCommitTheRequest() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      try await h.connect()
      let framework = h.framework
      await onVoIPActor { framework.confirmedVideo = false }
      await #expect(throws: ActionError.refused(nil)) {
        try await h.client.setVideo(callID, enabled: true)
      }
      #expect(h.client.calls.first?.hasVideo == false)
      #expect(await h.audio.configuredCalls.count == 1)
      try await h.expectNoEvents()
    }

    @Test func unknownEndedAndUnsupportedRejectEvenSameValue() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      await #expect(throws: ActionError.unknownCall) {
        try await h.client.setVideo(callID, enabled: false)
      }
      try await h.connect()
      let framework = h.framework
      await onVoIPActor { framework.supportsVideoChanges = false }
      await #expect(throws: ActionError.unsupported) {
        try await h.client.setVideo(callID, enabled: true)
      }
      await h.client.receive(.endedRemotely, for: callID, eventID: e3)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      await #expect(throws: ActionError.notAllowed(.ended(.endedRemotely))) {
        try await h.client.setVideo(callID, enabled: false)
      }
    }

    @Test func reportsAreNotOptimisticAndConcurrentChangesStayOrdered() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      try await h.connect()
      let gate = VideoGate()
      let framework = h.framework
      await onVoIPActor { framework.videoReport = { await gate.report($0) } }
      var starts = gate.started.makeAsyncIterator()
      let upgrade = Task { try await h.client.setVideo(callID, enabled: true) }
      _ = await starts.next()
      #expect(h.client.calls.first?.hasVideo == false)
      let downgrade = Task { try await h.client.setVideo(callID, enabled: false, source: .server) }
      await onVoIPActor {
        framework.videoReport = nil
        gate.finish(true)
      }
      try await upgrade.value
      try await downgrade.value
      #expect(try await h.next() == .videoChanged(callID, true, .app))
      #expect(try await h.next() == .videoChanged(callID, false, .server))
      #expect(h.client.calls.first?.hasVideo == false)
    }

    @Test func endingWhileReportIsPendingCannotResurrectVideo() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      try await h.connect()
      let gate = VideoGate()
      let framework = h.framework
      await onVoIPActor { framework.videoReport = { await gate.report($0) } }
      var starts = gate.started.makeAsyncIterator()
      let upgrade = Task { try await h.client.setVideo(callID, enabled: true) }
      _ = await starts.next()
      await h.client.receive(.endedRemotely, for: callID, eventID: e3)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      await gate.finish(true)
      await #expect(throws: ActionError.notAllowed(.ended(.endedRemotely))) {
        try await upgrade.value
      }
      try await h.expectNoEvents()
    }

    @Test func backgroundVideoDoesNotReconfigureTheForegroundSession() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      try await h.connect()
      try await h.ring(IncomingCall(id: otherCallID, parties: [alice]), eventID: e2)
      let before = await h.audio.configuredCalls.count
      try await h.client.setVideo(otherCallID, enabled: true, source: .server)
      #expect(try await h.next() == .videoChanged(otherCallID, true, .server))
      #expect(await h.audio.configuredCalls.count == before)
      try await h.answer(otherCallID)
      await h.client.receive(.connected, for: otherCallID, eventID: e3)
      await h.framework.perform(.hold(otherCallID, onHold: true))
      #expect(try await h.next() == .performed(.hold(otherCallID, onHold: true), .connected))
      let heldCount = await h.audio.configuredCalls.count
      try await h.client.setVideo(otherCallID, enabled: false)
      #expect(try await h.next() == .videoChanged(otherCallID, false, .app))
      #expect(await h.audio.configuredCalls.count == heldCount)
    }

    @Test func sameModeOwnerHandoffRefreshesTheResumedCallsConfiguration() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      try await h.connect()
      await h.framework.perform(.hold(callID, onHold: true))
      #expect(try await h.next() == .performed(.hold(callID, onHold: true), .connected))
      try await h.connect(otherCallID)
      try await h.client.setVideo(otherCallID, enabled: true)
      #expect(try await h.next() == .videoChanged(otherCallID, true, .app))
      try await h.client.setVideo(callID, enabled: true, source: .server)
      #expect(try await h.next() == .videoChanged(callID, true, .server))
      let before = await h.audio.configuredCalls.count
      await h.client.receive(.endedRemotely, for: otherCallID, eventID: e3)
      #expect(try await h.next() == .ended(otherCallID, .endedRemotely))
      await h.framework.perform(.hold(callID, onHold: false))
      #expect(try await h.next() == .performed(.hold(callID, onHold: false), .connected))
      #expect(await h.audio.configuredCalls.count == before + 1)
      #expect(await h.audio.configuredCalls.last?.id == callID)
      #expect(await h.audio.configuredCalls.last?.hasVideo == true)
    }

    @Test func previewsCannotReportToAMissingSystemConversation() async throws {
      let h = try Harness(configuration: VoIPConfiguration(supportsVideo: true))
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      await #expect(throws: ActionError.unsupported) {
        try await h.client.setVideo(callID, enabled: true)
      }
    }

    @Test func providerConfigurationCanDisableVideo() async throws {
      var configuration = VoIPConfiguration()
      configuration.supportsVideo = false
      let h = try Harness(configuration: configuration)
      try await h.connect()
      await #expect(throws: ActionError.unsupported) {
        try await h.client.setVideo(callID, enabled: true, source: .server)
      }
    }
  }
}

@VoIPActor private final class VideoGate {
  nonisolated let started: AsyncStream<Void>
  private let ready: AsyncStream<Void>.Continuation
  private var pending: CheckedContinuation<Bool, Never>?
  nonisolated init() {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    started = stream
    ready = continuation
  }
  func report(_ enabled: Bool) async -> Bool {
    await withCheckedContinuation {
      pending = $0
      ready.yield(())
    }
  }
  func finish(_ confirmed: Bool) {
    pending?.resume(returning: confirmed)
    pending = nil
  }
}
