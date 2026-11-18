import Testing
import VoIPCore
import VoIPTesting

extension EngineTests {
  @Suite("Deferred outgoing media")
  @MainActor
  struct DeferredOutgoingMedia {
    @Test(arguments: [false, true])
    func connectionRequiresMediaAndAnExplicitReport(reportFirst: Bool) async throws {
      let h = try await dial()
      h.clock.advance(by: .seconds(12))
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.status == .dialing)
      #expect(await h.audio.configuredCalls.isEmpty)

      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      #expect(await h.media.records.isEmpty)
      if reportFirst {
        await h.client.receive(.connected, for: callID, eventID: e1)
        await h.until { $0.calls.first?.status == .connecting }
        #expect(h.client.calls.first?.connectedAt == nil)
      }

      let media = h.media
      await onVoIPActor { media.preparation = .wait }
      try await h.client.provideMedia(callID)
      try await h.client.provideMedia(callID)
      while await media.waitingCalls.isEmpty { await Task.yield() }
      #expect(await media.waitingCalls == [callID])
      #expect(h.client.calls.first?.connectedAt == nil)
      await media.finishPreparing(callID, succeeded: true)
      while await !media.records.contains(.activate) { await Task.yield() }

      if !reportFirst {
        await h.client.receive(.connecting, for: callID, eventID: e2)
        try await h.expectNoEvents()
        #expect(h.client.calls.first?.status == .dialing)
        #expect(h.client.calls.first?.connectedAt == nil)
        #expect(await !h.records.contains(.reportOutgoing(callID, connected: true)))
        await h.client.receive(.connected, for: callID, eventID: e1)
      }
      await h.until { $0.calls.first?.status == .connected && $0.calls.first?.connectedAt != nil }
      let connectedAt = h.client.calls.first?.connectedAt
      h.clock.advance(by: .seconds(1))
      await h.client.receive(.connected, for: callID, eventID: e3)
      try await h.expectNoEvents()
      #expect(h.client.calls.first?.connectedAt == connectedAt)
      #expect(await h.records.count { $0 == .reportOutgoing(callID, connected: true) } == 1)
    }

    @Test(arguments: [false, true])
    func noAnswerDeadlineAppliesWhileWaitingForMedia(provideMedia: Bool) async throws {
      let h = try await dial(
        deadlines: Deadlines(mediaPreparation: .seconds(30), outgoingNoAnswer: .seconds(20)))
      let media = h.media
      await onVoIPActor { media.preparation = .wait }
      h.clock.advance(by: .seconds(15))
      try await h.expectNoEvents()
      if provideMedia {
        try await h.client.provideMedia(callID)
        while await media.waitingCalls.isEmpty { await Task.yield() }
      }
      h.clock.advance(by: .seconds(5))
      #expect(try await h.next() == .ended(callID, .unanswered))
      while await !media.waitingCalls.isEmpty { await Task.yield() }
      await #expect(throws: ActionError.notAllowed(.ended(.unanswered))) {
        try await h.client.provideMedia(callID)
      }
      #expect(await !media.records.contains(.activate))
    }

    @Test func duplicateConnectedReportDoesNotRearmConnectionDeadline() async throws {
      let h = try await dial(deadlines: Deadlines(connect: .seconds(4)))
      await h.client.receive(.connected, for: callID, eventID: e1)
      await h.until { $0.calls.first?.status == .connecting }
      h.clock.advance(by: .seconds(3))
      await h.client.receive(.connected, for: callID, eventID: e2)
      h.clock.advance(by: .seconds(1))
      #expect(try await h.next() == .ended(callID, .failed(.connectTimedOut)))
      #expect(await h.media.records.isEmpty)
    }

    @Test func preparationDeadlineStartsWhenMediaIsProvided() async throws {
      let h = try await dial(deadlines: Deadlines(mediaPreparation: .seconds(3)))
      h.clock.advance(by: .seconds(20))
      try await h.expectNoEvents()
      let media = h.media
      await onVoIPActor { media.preparation = .wait }
      try await h.client.provideMedia(callID)
      while await media.waitingCalls.isEmpty { await Task.yield() }
      h.clock.advance(by: .seconds(2))
      try await h.expectNoEvents()
      try await h.client.provideMedia(callID)
      h.clock.advance(by: .seconds(1))
      #expect(try await h.next() == .ended(callID, .failed(.media)))
      while await !media.waitingCalls.isEmpty { await Task.yield() }
    }

    private func dial(deadlines: Deadlines = Deadlines()) async throws -> Harness {
      let h = try Harness(
        configuration: VoIPConfiguration(deadlines: deadlines, outgoingMedia: .whenProvided))
      try await h.client.request(.start(outgoing))
      #expect(try await h.next() == .startRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.start(outgoing), .dialing))
      await h.until { $0.calls.first?.status == .dialing }
      #expect(await h.media.records.isEmpty)
      return h
    }
  }
}
