import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  /// Connection after answer and placement of a preview Join have different deadlines and outcomes.
  @Suite("Configured answer connection deadline")
  @MainActor
  struct ConfiguredAnswerDeadlineTests {
    private let connectionDeadline = Duration.seconds(27)

    @Test func answeredCallWithoutApplicationConnectionExpiresFromAnswerCompletion() async throws {
      let h = try Harness(
        configuration: VoIPConfiguration(deadlines: Deadlines(connect: connectionDeadline)))
      try await h.ring()
      // A late system answer must get the full connection budget, independent of ring time.
      h.clock.advance(by: .seconds(21))
      let answer = try await h.answer()
      #expect(await h.records.contains(.fulfill(answer)))
      // Audio activation does not restart the connection timer armed on answer completion.
      h.clock.advance(by: .seconds(1))
      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      await h.until { $0.calls.first?.status == .connecting }

      h.clock.advance(by: connectionDeadline - .seconds(1) - .milliseconds(1))
      try await h.expectNoEvents()
      #expect(h.client.calls.first { $0.id == callID }?.status == .connecting)
      #expect(h.client.calls.first { $0.id == callID }?.connectedAt == nil)

      h.clock.advance(by: .milliseconds(1))
      #expect(try await h.next() == .ended(callID, .failed(.connectTimedOut)))
      await h.until { $0.calls.allSatisfy { $0.id != callID } }
      #expect(await h.records.last == .reportEnded(callID, .failed(.connectTimedOut)))

      // An application attaching after failure can read current state and send late progress;
      // neither a stale connected report nor a stale placement confirmation revives the call.
      h.subscribe()
      await h.client.receive(.connected, for: callID, eventID: e2)
      await h.client.confirmPlaced(callID)
      try await h.expectNoEvents()
      #expect(h.client.calls.allSatisfy { $0.id != callID })
      #expect(await h.records.filter { $0 == .fulfill(answer) }.count == 1)
      #expect(
        await h.records.filter { $0 == .reportEnded(callID, .failed(.connectTimedOut)) }.count == 1)
    }

    @Test func applicationConnectionBeforeExpiryDisarmsTheConfiguredDeadline() async throws {
      let h = try Harness(
        configuration: VoIPConfiguration(deadlines: Deadlines(connect: connectionDeadline)))
      try await h.ring()
      try await h.answer()
      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      h.clock.advance(by: connectionDeadline - .milliseconds(1))

      // A late subscriber reconciles the answered call from the ordinary current-call API.
      h.subscribe()
      await h.until { $0.calls.first?.status == .connecting }
      #expect(h.client.calls.first?.id == callID)
      await h.client.receive(.connected, for: callID, eventID: e2)
      await h.until { $0.calls.first?.status == .connected }
      #expect(h.client.calls.first?.connectedAt != nil)
      h.clock.advance(by: .seconds(1))
      try await h.expectNoEvents()
      #expect(h.client.calls.first { $0.id == callID }?.status == .connected)
      #expect(await !h.records.contains(.reportEnded(callID, .failed(.connectTimedOut))))
    }

    @Test func previewJoinWithoutPlacementReturnsToPreviewInsteadOfConnectionFailure() async throws
    {
      let h = try Harness(
        configuration: VoIPConfiguration(
          deadlines: Deadlines(placement: .seconds(5), connect: connectionDeadline)))
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      let join = try await h.lastActionID()
      h.clock.advance(by: .seconds(5))
      #expect(try await h.next() == .joinFailed(callID, .policy, .failed(.notPlaced)))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      await h.until { $0.calls.first?.status == .previewing(.policy) }
      #expect(await h.records.contains(.fail(join)))

      await h.client.confirmPlaced(callID)
      h.clock.advance(by: connectionDeadline)
      try await h.expectNoEvents()
      #expect(h.client.calls.first { $0.id == callID }?.status == .previewing(.policy))
      #expect(await !h.records.contains(.fulfill(join)))
      #expect(await !h.records.contains(.reportEnded(callID, .failed(.connectTimedOut))))
    }
  }
}
