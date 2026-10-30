import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  /// Deadlines, timed on the test clock.
  @Suite("Deadlines")
  @MainActor
  struct DeadlineTests {
    enum Case: String, CaseIterable, Sendable, CustomTestStringConvertible {
      case ring
      case placementOfStart
      case placementOfJoin
      case mediaPreparation
      case audioActivation
      case connect
      case reconnect

      var testDescription: String { rawValue }
    }

    @Test(arguments: Case.allCases)
    func deadlinePasses(_ deadline: Case) async throws {
      let h = try Harness()
      let deadlines = Deadlines()
      switch deadline {
      case .ring:
        try await h.ring()
        h.clock.advance(by: deadlines.ring)
        #expect(try await h.next() == .ended(callID, .unanswered))
        #expect(await h.reported() == [.report(callID), .ended(callID, .unanswered)])

      case .placementOfStart:
        try await h.client.request(.start(outgoing))
        #expect(try await h.next() == .startRequested(callID))
        let start = try await h.lastActionID()
        h.clock.advance(by: deadlines.placement)
        #expect(try await h.next() == .ended(callID, .failed(.notPlaced)))
        #expect(
          await h.records.suffix(2) == [
            .fail(start), .reportEnded(callID, .failed(.notPlaced)),
          ])

      case .placementOfJoin:
        _ = await h.client.report(incoming(callID, .preview))
        #expect(try await h.next() == .previewStarted(callID, .policy))
        try await h.client.request(.join(callID))
        #expect(try await h.next() == .joinRequested(callID))
        let join = try await h.lastActionID()
        h.clock.advance(by: deadlines.placement)
        #expect(try await h.next() == .previewStarted(callID, .policy))
        #expect(
          await h.records.suffix(2) == [
            .fail(join), .reportEnded(callID, .failed(.notPlaced)),
          ])

      case .mediaPreparation:
        try await h.ring()
        let media = h.media
        await onVoIPActor { media.preparation = .wait }
        let answer = await h.framework.perform(.answer(callID))
        h.clock.advance(by: deadlines.mediaPreparation)
        #expect(try await h.next() == .ended(callID, .failed(.media)))
        #expect(
          await h.records.suffix(2) == [
            .fail(answer), .reportEnded(callID, .failed(.media)),
          ])

      case .audioActivation:
        try await h.ring()
        try await h.answer()
        h.clock.advance(by: deadlines.audioActivation)
        #expect(try await h.next() == .ended(callID, .failed(.audioActivationTimedOut)))
        #expect(await h.records.last == .reportEnded(callID, .failed(.audioActivationTimedOut)))

      case .connect:
        try await h.ring()
        try await h.answer()
        await h.framework.send(.audioActivated)
        #expect(try await h.next() == .audioActivated)
        h.clock.advance(by: deadlines.connect)
        #expect(try await h.next() == .ended(callID, .failed(.connectTimedOut)))
        #expect(await h.records.last == .reportEnded(callID, .failed(.connectTimedOut)))

      case .reconnect:
        try await h.connect()
        await h.client.receive(.reconnecting, for: callID, eventID: e2)
        h.clock.advance(by: deadlines.reconnect)
        #expect(try await h.next() == .ended(callID, .failed(.reconnectTimedOut)))
        #expect(await h.records.last == .reportEnded(callID, .failed(.reconnectTimedOut)))
      }
    }

    @Test func disarmedDeadlinesNeverFire() async throws {
      let h = try Harness()
      try await h.connect()
      await h.until { $0.calls.map(\.status) == [.connected] }
      #expect(h.clock.pendingSleepCount == 0)
      h.clock.advance(by: .seconds(3600))
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.status == .connected)
    }

    @Test func rearmedDeadlineFiresOnlyAtItsNewTime() async throws {
      let h = try Harness()
      try await h.connect()
      await h.client.receive(.reconnecting, for: callID, eventID: e1)
      h.clock.advance(by: .seconds(10))
      await h.client.receive(.connected, for: callID, eventID: e2)
      h.clock.advance(by: .seconds(10))
      await h.client.receive(.reconnecting, for: callID, eventID: e3)

      // The first reconnect deadline would have passed now.
      h.clock.advance(by: .seconds(46))
      try await h.expectNoEvents()
      h.clock.advance(by: .seconds(19))
      #expect(try await h.next() == .ended(callID, .failed(.reconnectTimedOut)))
    }

    @Test func staleTimerIsIgnored() async throws {
      let h = try Harness()
      try await h.ring()
      let before = await h.records
      await h.client.engine.timerFired(.ring, for: callID, generation: 0)
      try await h.expectNoEvents()
      #expect(await h.records == before)

      h.clock.advance(by: Deadlines().ring)
      #expect(try await h.next() == .ended(callID, .unanswered))
    }
  }
}
