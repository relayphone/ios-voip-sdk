import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  /// Configuring the audio session, interruptions and media services resets, timed on the test
  /// clock.
  @Suite("Audio session")
  @MainActor
  struct AudioSessionTests {
    let recovery = Deadlines().audioRecovery

    // MARK: Configuration

    @Test func configuresTheSessionBeforeTheAnswerCompletes() async throws {
      let h = try Harness()
      try await h.ring()
      let media = h.media
      await onVoIPActor { media.preparation = .wait }
      let answer = await h.framework.perform(.answer(callID))
      try await waitForPreparation(h)
      #expect(await h.audio.configuredCalls.map(\.id) == [callID])
      #expect(await !h.records.contains(.fulfill(answer)))

      await onVoIPActor { media.finishPreparing(callID, succeeded: true) }
      #expect(try await h.next() == .performed(.answer(callID), .connecting))
      #expect(await h.records.contains(.fulfill(answer)))
      #expect(await h.audio.configuredCalls.count == 1)
    }

    @Test func configuresTheSessionForAnOutgoingCallOnceItIsPlaced() async throws {
      let h = try Harness()
      let video = OutgoingCall(id: callID, parties: [alice], hasVideo: true)
      try await h.client.request(.start(video))
      #expect(try await h.next() == .startRequested(callID))
      #expect(await h.audio.configuredCalls.isEmpty)
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.start(video), .dialing))
      #expect(await h.audio.configuredCalls.map(\.hasVideo) == [true])
    }

    @Test func aRefusedConfigurationEndsTheCallBeforeItsMediaIsPrepared() async throws {
      let h = try Harness()
      let audio = h.audio
      await onVoIPActor { audio.failsConfiguration = true }
      try await h.ring()
      let answer = await h.framework.perform(.answer(callID))
      #expect(try await h.next() == .ended(callID, .failed(.audioSession)))
      #expect(
        await h.records.suffix(2) == [.fail(answer), .reportEnded(callID, .failed(.audioSession))])
      #expect(await h.media.records.isEmpty)
    }

    @Test func aRefusedConfigurationReturnsAJoinToItsPreview() async throws {
      let h = try Harness()
      let audio = h.audio
      await onVoIPActor { audio.failsConfiguration = true }
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .previewStarted(callID, .policy))
      #expect(await h.records.last == .reportEnded(callID, .failed(.audioSession)))
      #expect(await h.media.records.isEmpty)
    }

    // MARK: Interruptions

    @Test func anInterruptionStopsAudioUntilTheSystemActivatesItAgain() async throws {
      let h = try Harness()
      try await h.connect()
      await h.until { $0.isAudioActive }

      await h.audio.send(.interruptionBegan(.otherAudio))
      #expect(try await h.next() == .audioInterrupted(.otherAudio))
      #expect(await h.media.records.last == .deactivate)
      await h.until { !$0.isAudioActive }

      await h.audio.send(.interruptionEnded)
      h.clock.advance(by: recovery - .milliseconds(1))
      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      #expect(await h.media.records.suffix(2) == [.deactivate, .activate])

      h.clock.advance(by: .seconds(3600))
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.status == .connected)
    }

    @Test func aCallWhoseAudioDoesntRecoverEnds() async throws {
      let h = try Harness()
      try await h.connect()
      await h.audio.send(.interruptionBegan(.builtInMicMuted))
      #expect(try await h.next() == .audioInterrupted(.builtInMicMuted))
      await h.audio.send(.interruptionEnded)

      h.clock.advance(by: recovery)
      #expect(try await h.next() == .ended(callID, .failed(.audioRecoveryTimedOut)))
      #expect(await h.records.last == .reportEnded(callID, .failed(.audioRecoveryTimedOut)))
    }

    @Test func aLongInterruptionKeepsTheCall() async throws {
      let h = try Harness()
      try await h.connect()
      await h.audio.send(.interruptionBegan(.otherAudio))
      #expect(try await h.next() == .audioInterrupted(.otherAudio))
      h.clock.advance(by: .seconds(3600))
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.status == .connected)
    }

    @Test func anInterruptionOfInactiveAudioConcernsNoCall() async throws {
      let h = try Harness()
      try await h.ring()
      await h.audio.send(.interruptionBegan(.otherAudio))
      await h.audio.send(.interruptionEnded)
      h.clock.advance(by: recovery)
      try await h.expectNoEvents()
      #expect(await h.media.records.isEmpty)
    }

    @Test func aCallOnHoldDoesntWaitForAudio() async throws {
      let h = try Harness()
      try await h.connect()
      await h.audio.send(.interruptionBegan(.otherAudio))
      #expect(try await h.next() == .audioInterrupted(.otherAudio))
      await h.audio.send(.interruptionEnded)
      // The user holds the call to take another one.
      await h.framework.perform(.hold(callID, onHold: true))
      #expect(try await h.next() == .performed(.hold(callID, onHold: true), .connected))
      await h.framework.send(.audioDeactivated)
      #expect(try await h.next() == .audioDeactivated)
      #expect(await h.media.records.filter { $0 == .deactivate }.count == 1)

      h.clock.advance(by: .seconds(3600))
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.status == .connected)
    }

    // MARK: Media services reset

    @Test func aMediaServicesResetConfiguresTheSessionAgainAndRecovers() async throws {
      let h = try Harness()
      try await h.connect()
      await h.audio.send(.mediaServicesReset)
      #expect(try await h.next() == .mediaServicesReset)
      #expect(await h.media.records.last == .deactivate)
      #expect(await h.audio.configuredCalls.map(\.id) == [callID, callID])
      await h.until { !$0.isAudioActive }

      h.clock.advance(by: recovery - .milliseconds(1))
      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      h.clock.advance(by: .seconds(3600))
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.status == .connected)
    }

    @Test func aCallWhoseAudioDoesntReturnAfterAResetEnds() async throws {
      let h = try Harness()
      try await h.connect()
      await h.audio.send(.mediaServicesReset)
      #expect(try await h.next() == .mediaServicesReset)
      h.clock.advance(by: recovery)
      #expect(try await h.next() == .ended(callID, .failed(.audioRecoveryTimedOut)))
    }

    @Test func aResetConfiguresTheSessionForTheNewestCallNotOnHold() async throws {
      let h = try Harness()
      try await h.connect(callID)
      try await h.ring(IncomingCall(id: otherCallID, parties: [alice]), eventID: e2)
      try await h.answer(otherCallID)
      await h.framework.perform(.hold(otherCallID, onHold: true))
      #expect(try await h.next() == .performed(.hold(otherCallID, onHold: true), .connecting))

      await h.audio.send(.mediaServicesReset)
      #expect(try await h.next() == .mediaServicesReset)
      #expect(await h.audio.configuredCalls.last?.id == callID)
      // Only the call that isn't on hold waits for audio.
      h.clock.advance(by: recovery)
      #expect(try await h.next() == .ended(callID, .failed(.audioRecoveryTimedOut)))
      try await h.expectNoEvents()
    }

    @Test func aRefusedConfigurationAfterAResetEndsTheCalls() async throws {
      let h = try Harness()
      try await h.connect()
      let audio = h.audio
      await onVoIPActor { audio.failsConfiguration = true }
      await h.audio.send(.mediaServicesReset)
      #expect(
        try await h.next(2) == [.mediaServicesReset, .ended(callID, .failed(.audioSession))])
      #expect(await h.records.last == .reportEnded(callID, .failed(.audioSession)))
    }

    @Test func aResetWithoutCallsOnlyTellsTheApp() async throws {
      let h = try Harness()
      await h.audio.send(.mediaServicesReset)
      #expect(try await h.next() == .mediaServicesReset)
      #expect(await h.audio.configuredCalls.isEmpty)
      #expect(await h.media.records.isEmpty)
    }

    /// Waits until the media's preparation of the call is waiting.
    private func waitForPreparation(_ h: Harness) async throws {
      let media = h.media
      while await onVoIPActor({ media.waitingCalls.isEmpty }) { await Task.yield() }
    }
  }
}
